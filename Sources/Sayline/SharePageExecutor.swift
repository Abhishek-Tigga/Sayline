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
        guard let number = selfNumber, !number.isEmpty else {
            return askSelfNumber(message: message)
        }
        return openWhatsApp(number: number, message: message, who: "yourself")
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
        switch ShareLink.resolve(spoken: spoken, in: candidates) {
        case .resolved(let name, let number):
            SaylineLog.log("[share] resolved to \(name)")
            return openWhatsApp(number: number, message: message, who: name)

        case .ambiguous(let name, let options):
            // Decision 5: ask, never guess. A wrong recipient is the worst
            // outcome this feature can produce, and silence picks nobody.
            SaylineLog.log("[share] ambiguous recipient: \(options.count) options")
            return .ask(question: "Which \(name)?",
                        detail: options.prefix(2).joined(separator: " or "),
                        choices: Array(options.prefix(2))) { answer in
                guard let answer else { return .failed("") }
                // Re-resolve against the narrowed answer rather than
                // indexing the option list: the user may say a surname,
                // and the same matching rule should decide both times.
                let narrowed = candidates.filter {
                    ShareLink.matches(spoken: answer, name: $0.name)
                        || $0.numbers.contains { $0.number == answer }
                }
                guard narrowed.count == 1 else {
                    return .failed("Still not sure which \(name) — nothing sent.")
                }
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
            SaylineLog.log("[share] no contact matched what was heard")
            return .failed("No contact called \"\(heard)\".")
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
