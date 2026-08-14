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

    /// What the caller should say to the user, when anything stops.
    ///
    /// Returned rather than presented here so the notice path stays the
    /// one the rest of the app uses.
    static var lastMessage: String?

    @discardableResult
    static func run(recipient: ShareLink.Recipient, note: String?,
                    target: ShareLink.Target?, makeDefault: Bool) -> Bool {
        lastMessage = nil

        // The URL first: without it nothing else matters, and its failure
        // messages are the most likely thing a user will meet.
        let url: URL
        switch SharePageState.take() {
        case .success(let captured): url = captured
        case .failure(let why):
            SaylineLog.log("[share] no page to share — \(why)")
            lastMessage = why.message
            return false
        }

        let message = ShareLink.message(note: note, url: url)

        // Decision 7: an explicit spoken target always beats the stored
        // default, and "always" writes the default before it is used.
        var chosen = target ?? defaultTarget
        if makeDefault, let target {
            defaultTarget = target
            SaylineLog.log("[share] default target set to \(target.rawValue)")
        }

        switch recipient {
        case .named(let spoken):
            // Decision 6: a name can only be reached on WhatsApp, so no
            // question is asked and AirDrop is not offered.
            SaylineLog.log("[share] resolving contact for a named send")
            return sendToNamed(spoken: spoken, message: message)

        case .selfTarget, .unnamed:
            if chosen == nil {
                // Decision 7's first-time question. Asking is handled by
                // the caller through FollowUp; with no answer yet, the
                // honest thing is to say so rather than pick one.
                SaylineLog.log("[share] no target chosen and no default — asking")
                lastMessage = "WhatsApp or AirDrop?"
                return false
            }
            if chosen == .airdrop { return airDrop(url: url) }
            guard let number = selfNumber, !number.isEmpty else {
                SaylineLog.log("[share] self send with no stored number")
                lastMessage = "What's your WhatsApp number? Say it once and I'll remember."
                return false
            }
            return openWhatsApp(number: number, message: message, who: "yourself")
        }
    }

    // MARK: - Named sends

    private static func sendToNamed(spoken: String, message: String) -> Bool {
        let store = CNContactStore()
        guard CNContactStore.authorizationStatus(for: .contacts) != .denied else {
            lastMessage = "Sayline needs Contacts to find \(spoken). Allow it in System Settings > Privacy & Security > Contacts."
            return false
        }

        var candidates: [ShareLink.Candidate] = []
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        do {
            try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
                let name = [c.givenName, c.familyName]
                    .filter { !$0.isEmpty }.joined(separator: " ")
                guard !name.isEmpty, !c.phoneNumbers.isEmpty else { return }
                candidates.append(ShareLink.Candidate(
                    name: name,
                    numbers: c.phoneNumbers.map {
                        ($0.label ?? "", $0.value.stringValue)
                    }))
            }
        } catch {
            SaylineLog.log("[share] Contacts read failed: \(error.localizedDescription)")
            lastMessage = "Couldn't read Contacts. Allow Sayline in System Settings > Privacy & Security > Contacts."
            return false
        }

        switch ShareLink.resolve(spoken: spoken, in: candidates) {
        case .resolved(let name, let number):
            SaylineLog.log("[share] resolved to \(name)")
            return openWhatsApp(number: number, message: message, who: name)

        case .ambiguous(let name, let options):
            // Decision 5: ask, never guess. Timeout does nothing.
            SaylineLog.log("[share] ambiguous recipient for \(name): \(options.count) options")
            lastMessage = "\(options.prefix(2).joined(separator: " or "))?"
            return false

        case .needsCountryCode(let name, _):
            SaylineLog.log("[share] \(name) has no country code")
            lastMessage = "What's \(name)'s country code?"
            return false

        case .notFound(let heard):
            // The failure names what was heard, so a mishearing is
            // obvious rather than mysterious.
            SaylineLog.log("[share] no contact matched what was heard")
            lastMessage = "No contact called \"\(heard)\"."
            return false
        }
    }

    // MARK: - Delivery

    /// Decision 12: the scheme first, `wa.me` when the app is absent.
    private static func openWhatsApp(number: String?, message: String, who: String) -> Bool {
        if let scheme = ShareLink.whatsappURL(number: number, message: message),
           NSWorkspace.shared.urlForApplication(toOpen: scheme) != nil {
            SaylineLog.log("[share] opening WhatsApp prefilled for \(who) — not sent")
            NSWorkspace.shared.open(scheme)
            return true
        }
        if let web = ShareLink.waMeURL(number: number, message: message) {
            SaylineLog.log("[share] WhatsApp app absent, falling back to wa.me for \(who)")
            NSWorkspace.shared.open(web)
            return true
        }
        lastMessage = "Couldn't open WhatsApp."
        return false
    }

    /// Decision 6: opens the picker. A cancelled picker does nothing and
    /// retries nothing — there is no "did they send it" to observe, and
    /// inventing one would be the auto-send failure in another costume.
    private static func airDrop(url: URL) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            lastMessage = "AirDrop isn't available on this Mac."
            return false
        }
        SaylineLog.log("[share] opening the AirDrop picker")
        service.perform(withItems: [url])
        return true
    }
}
