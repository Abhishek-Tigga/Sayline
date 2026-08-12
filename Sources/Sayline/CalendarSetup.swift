import Foundation

/// The one-time card that gets someone's calendar actually connected.
///
/// Sayline reads whatever macOS Calendar holds. A person whose calendar
/// lives in Google gets nothing until they add that account in System
/// Settings, and even then CalDAV refreshes every fifteen minutes by
/// default — so the answer can be confidently, silently wrong. Measured on
/// 2026-08-11: four queries over 83 seconds returned a title the user had
/// renamed twelve minutes earlier.
///
/// Neither half can be automated. There is no public API to add a CalDAV
/// account, the refresh interval lives in a protected store, and
/// `refreshSourcesIfNecessary()` was measured not to force a pull. So the
/// honest remaining move is to walk the two steps once and open every door
/// we can open on the way.
///
/// Three steps rather than two, because the middle one is a wait. Adding an
/// account happens in another app and takes as long as it takes; a card
/// that raced ahead to "now set the refresh rate" while someone was still
/// signing in would be talking to nobody.
struct CalendarSetupCard: Equatable {
    enum Step: Equatable {
        /// What Sayline can see right now, and the offer to change it.
        case review
        /// Waiting while they add an account in System Settings.
        case adding
        /// The refresh interval — the half that causes wrong answers.
        case refreshRate
    }

    let step: Step
    let accounts: [ConnectedAccount]

    /// "2 Google accounts", "Google and iCloud", "Nothing connected".
    var summary: String {
        guard !accounts.isEmpty else { return "No calendar accounts connected" }
        let parts = accounts.map { account -> String in
            let count = account.addresses.count
            return count > 1 ? "\(count) \(account.provider) accounts" : account.provider
        }
        if parts.count == 1 { return "\(parts[0]) connected" }
        return "\(parts.dropLast().joined(separator: ", ")) and \(parts.last!) connected"
    }

    /// The addresses themselves, which is the part that answers "is it the
    /// right account". Empty when EventKit exposed none.
    var addressLines: [String] {
        accounts.flatMap { account in
            account.addresses.isEmpty ? [] : account.addresses.map { "\(account.provider) · \($0)" }
        }
    }

    var title: String {
        switch step {
        case .review: return accounts.isEmpty ? "No calendars connected" : "Calendar accounts"
        case .adding: return "Add your account"
        case .refreshRate: return "One last step"
        }
    }

    var detail: String {
        switch step {
        case .review:
            return accounts.isEmpty
                ? "Sayline reads your Mac's calendar. Google and Outlook have to be added in System Settings first."
                : "Sayline only sees accounts added to this Mac. Missing one?"
        case .adding:
            return "In System Settings, click Add Account and choose Google. Come back and press Done when it is added."
        case .refreshRate:
            return "Set Refresh Calendars to Every minute. Without it, changes take up to 15 minutes to reach Sayline."
        }
    }

    var primaryLabel: String {
        switch step {
        case .review: return "Add an account"
        case .adding: return "Done"
        case .refreshRate: return "Open Calendar settings"
        }
    }

    var secondaryLabel: String {
        switch step {
        case .review: return "Looks right"
        case .adding: return "Cancel"
        case .refreshRate: return "Skip"
        }
    }
}

enum CalendarSetupAction: Equatable {
    case primary
    case dismiss
}

/// Remembers that the card has been seen, so it is offered once.
enum CalendarSetupState {
    private static let key = "com.abhishektigga.sayline.calendarSetupDismissed"

    static var hasBeenDismissed: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func markDismissed() {
        UserDefaults.standard.set(true, forKey: key)
    }

    /// For testing the card again after dismissing it.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
