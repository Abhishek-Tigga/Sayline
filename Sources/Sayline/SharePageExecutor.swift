import Foundation
import AppKit
import Contacts

/// The page captured for the hold in progress.
///
/// Separate from the executor because *when* it is filled is a design
/// decision (3) and *what it holds* is a privacy decision (2). One hold,
/// one URL, cleared at the start of the next — nothing survives the
/// gesture that justified it, matching the idle-holds-nothing rule.
enum SharePageState {
    private static let queue = DispatchQueue(label: "com.sayline.sharepage")
    private static var captured: URL?
    private static var failure: PageCapture.Failure?

    /// Called on the agent flag, never on a plain hold.
    static func captureCurrentPage() {
        switch PageCapture.currentPageURL() {
        case .success(let url):
            queue.sync { captured = url; failure = nil }
        case .failure(let why):
            queue.sync { captured = nil; failure = why }
        }
    }

    static func clear() {
        queue.sync { captured = nil; failure = nil }
    }

    static func take() -> Result<URL, PageCapture.Failure> {
        queue.sync {
            if let captured { return .success(captured) }
            return .failure(failure ?? .notABrowser(appName: "This app"))
        }
    }
}

/// Everything the share action does after the router has spoken.
///
/// The model's contribution ended at (recipient, note). From here it is
/// all local: the captured URL, Contacts, and a prefilled window the user
/// presses Enter in. Decision 4 — nothing on any path sends.
enum SharePageExecutor {

    /// Where the user's own number and their standing target live.
    private enum Stored {
        static let selfNumber = "sharePageSelfNumber"
        static let defaultTarget = "sharePageDefaultTarget"
    }

    static var selfNumber: String? {
        get { UserDefaults.standard.string(forKey: Stored.selfNumber) }
        set { UserDefaults.standard.set(newValue, forKey: Stored.selfNumber) }
    }

    /// "Ask" is the absence of a value, so the Settings control has a
    /// real three-way state and decision 7's standing rule stays visible.
    static var defaultTarget: ShareLink.Target? {
        get { UserDefaults.standard.string(forKey: Stored.defaultTarget)
                .flatMap(ShareLink.Target.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: Stored.defaultTarget) }
    }

    /// What one step of a share wants next.
    ///
    /// Decision 5's "ambiguity is asked, not guessed" only means anything
    /// if something actually asks. The executor returns the question and a
    /// continuation rather than presenting it, so the asking stays in
    /// `AgentTurn` with every other question in the app, and this file
    /// stays testable without a window.
    enum Step {
        case opened
        case failed(String)
        /// Ask, then call `resume` with what the user said. `resume` is
        /// pure in the same way `run` is — it returns another `Step`.
        case ask(question: String, detail: String?, choices: [String],
                 resume: (String?) -> Step)
    }

    static func run(recipient: ShareLink.Recipient, note: String?,
                    target: ShareLink.Target?, makeDefault: Bool) -> Step {
        // The URL first: without it nothing else matters, and its failure
        // messages are the most likely thing a user will meet.
        let url: URL
        switch SharePageState.take() {
        case .success(let captured): url = captured
        case .failure(let why):
            SaylineLog.log("[share] no page to share")
            return .failed(why.message)
        }

        let message = ShareLink.message(note: note, url: url)

        // Decision 7: an explicit spoken target always beats the stored
        // default, and "always" writes the default before it is used.
        if makeDefault, let target {
            defaultTarget = target
            SaylineLog.log("[share] default target set to \(target.rawValue)")
        }

        switch recipient {
        case .named(let spoken):
            // Decision 6: a name can only be reached on WhatsApp, so no
            // target question is asked and AirDrop is not offered.
            SaylineLog.log("[share] resolving contact for a named send")
            return sendToNamed(spoken: spoken, message: message)

        case .selfTarget, .unnamed:
            guard let chosen = target ?? defaultTarget else {
                return askTarget(url: url, message: message)
            }
            return deliverToSelf(target: chosen, url: url, message: message)
        }
    }

    // MARK: - Self and unnamed

    /// Decision 7's first-time question, and the one place "always" can be
    /// spoken as part of the answer.
    private static func askTarget(url: URL, message: String) -> Step {
        SaylineLog.log("[share] no target chosen and no default — asking")
        return .ask(question: "WhatsApp or AirDrop?",
                    detail: nil,
                    choices: ["WhatsApp", "AirDrop"]) { spoken in
            guard let said = spoken?.lowercased() else {
                // Silence chooses nothing. Decision 5's rule, applied to
                // the target question too: a timeout does nothing at all.
                return .failed("")
            }
            let target: ShareLink.Target
            if said.contains("airdrop") || said.contains("air drop") {
                target = .airdrop
            } else if said.contains("whatsapp") || said.contains("whats app") {
                target = .whatsapp
            } else {
                return .failed("Didn't catch that — WhatsApp or AirDrop?")
            }
            // "WhatsApp, always" sets the standing choice in the same
            // breath; without "always" the answer is for this send only.
            if said.contains("always") {
                defaultTarget = target
                SaylineLog.log("[share] default target set to \(target.rawValue) by voice")
            }
            return deliverToSelf(target: target, url: url, message: message)
        }
    }

    private static func deliverToSelf(target: ShareLink.Target,
                                      url: URL, message: String) -> Step {
        if target == .airdrop { return airDrop(url: url) }
        if let number = selfNumber, !number.isEmpty {
            return openWhatsApp(number: number, message: message, who: "yourself")
        }
        // Decision 10, amended 2026-08-14 on the user's correction: the
        // me-card was assumed unreliable and never consulted. Theirs is
        // filled in and they expect it used. Asked for only when the card
        // is missing, empty, or carries no country code.
        if let fromCard = meCardNumber() {
            SaylineLog.log("[share] using the number on your Contacts me-card")
            selfNumber = fromCard
            return openWhatsApp(number: fromCard, message: message, who: "yourself")
        }
        return askSelfNumber(message: message)
    }

    /// The user's own card, when it has a dialable number.
    private static func meCardNumber() -> String? {
        guard CNContactStore.authorizationStatus(for: .contacts) != .denied else { return nil }
        let keys = [CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        guard let me = try? CNContactStore().unifiedMeContactWithKeys(toFetch: keys) else {
            SaylineLog.log("[share] no me-card in Contacts")
            return nil
        }
        let mobiles = me.phoneNumbers.filter { ShareLink.isMobile($0.label ?? "") }
        let ordered = mobiles.isEmpty ? me.phoneNumbers : mobiles

        // Already international — use it as written.
        for entry in ordered {
            let digits = ShareLink.normalize(entry.value.stringValue)
            if ShareLink.hasCountryCode(digits) { return digits }
        }

        // Stored the way people actually store their own number: locally,
        // with no "+". Live on 2026-08-14 this hit the ask every time and
        // the user reasonably read it as the me-card being ignored. The
        // Mac's region completes it, and only for the user's own card —
        // see `withLocalCountryCode`.
        for entry in ordered {
            if let completed = ShareLink.withLocalCountryCode(entry.value.stringValue) {
                SaylineLog.log("[share] me-card number completed with this Mac's region code")
                return completed
            }
        }

        // Shape only, never the digits: enough to diagnose the next
        // failure without putting a phone number in a log meant to be
        // handed over.
        SaylineLog.log("[share] me-card has \(me.phoneNumbers.count) number(s), "
            + "none usable and the region gave no calling code")
        return nil
    }

    /// Decision 10 — asked once, stored locally, editable later.
    private static func askSelfNumber(message: String) -> Step {
        SaylineLog.log("[share] self send with no stored number — asking once")
        return .ask(question: "What's your WhatsApp number?",
                    detail: "Asked once, then remembered",
                    choices: []) { spoken in
            guard let spoken else { return .failed("") }
            let digits = ShareLink.normalize(spoken.filter { $0.isNumber || $0 == "+" })
            guard ShareLink.hasCountryCode(digits) else {
                return .failed("That needs a country code, like +91.")
            }
            selfNumber = digits
            SaylineLog.log("[share] stored the self number")
            return openWhatsApp(number: digits, message: message, who: "yourself")
        }
    }

    // MARK: - Named sends

    private static func sendToNamed(spoken: String, message: String) -> Step {
        guard CNContactStore.authorizationStatus(for: .contacts) != .denied else {
            return .failed("Sayline needs Contacts to find \(spoken). Allow it in System Settings > Privacy & Security > Contacts.")
        }

        let candidates: [ShareLink.Candidate]
        do {
            candidates = try readContacts()
        } catch {
            SaylineLog.log("[share] Contacts read failed: \(error.localizedDescription)")
            return .failed("Couldn't read Contacts. Allow Sayline in System Settings > Privacy & Security > Contacts.")
        }

        return resolve(spoken: spoken, candidates: candidates, message: message)
    }

    private static func resolve(spoken: String, candidates: [ShareLink.Candidate],
                                message: String) -> Step {
        // Diagnostic for the "the list was not comprehensive" report.
        // Names only, never numbers — the log file is meant to be handed
        // over. Counting both tells the missing-contact question apart
        // from the wrong-answer one without another round of guessing.
        let nameMatches = candidates.filter { ShareLink.matches(spoken: spoken, name: $0.name) }
        SaylineLog.log("[share] \(candidates.count) contacts with numbers, "
            + "\(nameMatches.count) matched what was heard")

        // A name resolved once is remembered, so the same question is not
        // asked every time. macOS exposes no call history to any app, so
        // this is the buildable half of "rank by who I actually message":
        // the user's own previous answer. Safe under decision 4 — the
        // chat opens prefilled and a wrong face is visible before Enter.
        if let remembered = rememberedName(for: spoken),
           let match = candidates.first(where: { $0.name == remembered }) {
            SaylineLog.log("[share] \(spoken) -> \(remembered) (remembered)")
            if case .resolved(let name, let number) =
                ShareLink.resolve(spoken: match.name, in: [match]) {
                return openWhatsApp(number: number, message: message, who: name)
            }
        }

        switch ShareLink.resolve(spoken: spoken, in: candidates) {
        case .resolved(let name, let number):
            SaylineLog.log("[share] resolved to \(name)")
            return openWhatsApp(number: number, message: message, who: name)

        case .ambiguous(let name, let options):
            // Decision 5: ask, never guess. A wrong recipient is the worst
            // outcome this feature can produce, and silence picks nobody.
            //
            // Every option is offered. This used to show `prefix(2)`,
            // which silently dropped a third or fourth match and said
            // nothing about it — the user reported a question whose list
            // did not contain the person they wanted, and a cap that
            // discards real answers is a bug however tidy it looks.
            //
            // Ordered by how often the user actually says each name,
            // using the glossary's own ranking rather than a second copy.
            let ranked = VocabularyBias.rankedByHistory(options,
                                                        historyText: dictationHistory())
            SaylineLog.log("[share] ambiguous recipient: \(ranked.count) options offered")
            return .ask(question: "Which \(name)?",
                        detail: ranked.joined(separator: ", "),
                        choices: ranked) { answer in
                guard let answer else {
                    SaylineLog.log("[share] disambiguation timed out — nothing sent")
                    return .failed("")
                }
                // Re-resolve against the narrowed answer rather than
                // indexing the option list: the user may say a surname,
                // and the same matching rule should decide both times.
                let narrowed = candidates.filter {
                    ShareLink.matches(spoken: answer, name: $0.name)
                        || $0.numbers.contains { $0.number == answer }
                }
                guard narrowed.count == 1 else {
                    // Logged, because the user experienced this as the app
                    // doing nothing: a flash message is the only trace and
                    // it is gone in three seconds.
                    SaylineLog.log("[share] answer matched \(narrowed.count) contacts "
                        + "— nothing sent")
                    return .failed("Still not sure which \(name) — nothing sent.")
                }
                remember(narrowed[0].name, for: name)
                return resolve(spoken: narrowed[0].name, candidates: narrowed,
                               message: message)
            }

        case .needsCountryCode(let name, let number):
            SaylineLog.log("[share] \(name) has no country code — asking once")
            return .ask(question: "What's \(name)'s country code?",
                        detail: "Asked once for \(name)",
                        choices: ["+91", "+1", "+44"]) { answer in
                guard let answer else { return .failed("") }
                let code = "+" + answer.filter { $0.isNumber }
                guard code.count >= 2 else { return .failed("That isn't a country code.") }
                let full = code + number
                rememberCountryCode(code, for: name)
                return openWhatsApp(number: full, message: message, who: name)
            }

        case .notFound(let heard):
            // Names what was heard, so a mishearing is obvious rather
            // than mysterious.
            //
            // A card that matches the name but carries no phone number is
            // filtered out before this point, and the user cannot tell
            // "filtered" from "absent" — so it is named specifically. The
            // wording also hints the account boundary: `CNContactStore`
            // only sees accounts enabled in Internet Accounts, so someone
            // who lives only in WhatsApp is invisible to us.
            if let numberless = numberlessMatch(for: heard) {
                SaylineLog.log("[share] matched a contact with no phone number")
                return .failed("\(numberless) has no phone number in Contacts.")
            }
            SaylineLog.log("[share] no contact matched what was heard")
            return .failed("No contact called \"\(heard)\" in your Mac's Contacts.")
        }
    }

    private static func readContacts() throws -> [ShareLink.Candidate] {
        var candidates: [ShareLink.Candidate] = []
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        try CNContactStore().enumerateContacts(
            with: CNContactFetchRequest(keysToFetch: keys)
        ) { contact, _ in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            guard !name.isEmpty, !contact.phoneNumbers.isEmpty else { return }
            candidates.append(ShareLink.Candidate(
                name: name,
                numbers: contact.phoneNumbers.map { ($0.label ?? "", $0.value.stringValue) }))
        }
        return candidates
    }

    /// The spoken name the user said, mapped to the card they meant.
    /// Overwritten by a later answer, so a changed mind wins.
    static func rememberedName(for spoken: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: "sharePageNameChoices")
            as? [String: String])?[spoken.lowercased()]
    }

    private static func remember(_ resolved: String, for spoken: String) {
        var stored = UserDefaults.standard.dictionary(forKey: "sharePageNameChoices")
            as? [String: String] ?? [:]
        stored[spoken.lowercased()] = resolved
        UserDefaults.standard.set(stored, forKey: "sharePageNameChoices")
        SaylineLog.log("[share] remembered that choice for next time")
    }

    /// A contact whose name matches but who has no number at all — the
    /// case `readContacts()` filters out and the user cannot see.
    private static func numberlessMatch(for spoken: String) -> String? {
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        var found: String?
        try? CNContactStore().enumerateContacts(
            with: CNContactFetchRequest(keysToFetch: keys)
        ) { contact, stop in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }.joined(separator: " ")
            if contact.phoneNumbers.isEmpty,
               ShareLink.matches(spoken: spoken, name: name) {
                found = name
                stop.pointee = true
            }
        }
        return found
    }

    /// The dictation history the glossary ranks from.
    ///
    /// Read through `HistoryStorage.defaultsKey` and `HistoryEntry`, the
    /// same path the glossary builder uses, so the option order here and
    /// the glossary's ranking cannot disagree. Written from a guessed key
    /// first, which returned an empty string forever and made the ranking
    /// a silent no-op — the failure this whole file's comments keep
    /// warning about, committed once more.
    private static func dictationHistory() -> String {
        let data = UserDefaults.standard.data(forKey: HistoryStorage.defaultsKey) ?? Data()
        let entries = (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
        return entries.map(\.text).joined(separator: " ")
    }

    /// Per-contact, because the failure table says asked once and then
    /// remembered — for that contact, not globally.
    private static func rememberCountryCode(_ code: String, for name: String) {
        var stored = UserDefaults.standard.dictionary(forKey: "sharePageCountryCodes")
            as? [String: String] ?? [:]
        stored[name] = code
        UserDefaults.standard.set(stored, forKey: "sharePageCountryCodes")
    }

    static func storedCountryCode(for name: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: "sharePageCountryCodes")
            as? [String: String])?[name]
    }

    // MARK: - Delivery

    /// Decision 12: the scheme first, `wa.me` when the app is absent.
    private static func openWhatsApp(number: String?, message: String, who: String) -> Step {
        if let scheme = ShareLink.whatsappURL(number: number, message: message),
           NSWorkspace.shared.urlForApplication(toOpen: scheme) != nil {
            SaylineLog.log("[share] opening WhatsApp prefilled for \(who) — not sent")
            NSWorkspace.shared.open(scheme)
            return .opened
        }
        if let web = ShareLink.waMeURL(number: number, message: message) {
            SaylineLog.log("[share] WhatsApp app absent, falling back to wa.me for \(who)")
            NSWorkspace.shared.open(web)
            return .opened
        }
        return .failed("Couldn't open WhatsApp.")
    }

    /// Decision 6: opens the picker. A cancelled picker does nothing and
    /// retries nothing — there is no "did they send it" to observe, and
    /// inventing one would be auto-send in another costume.
    private static func airDrop(url: URL) -> Step {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            return .failed("AirDrop isn't available on this Mac.")
        }
        SaylineLog.log("[share] opening the AirDrop picker")
        service.perform(withItems: [url])
        return .opened
    }
}
