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
/// honest remaining move is to teach the two steps once, name the accounts
/// already connected so the decision is informed, and get out of the way.
///
/// Shown once and then never again unless asked for. A card that reappears
/// every time someone checks their calendar is a card people learn to
/// dismiss without reading.
struct CalendarSetupCard: Equatable {
    enum Step: Equatable {
        /// What Sayline can see, and the offer to change it.
        case connect
        /// Said after Internet Accounts opens — the part that lives inside
        /// Calendar.app and cannot be deep-linked to.
        case refreshRate
    }

    let step: Step
    /// Accounts currently supplying event calendars, by name. Empty is the
    /// loudest possible version of this card.
    let accounts: [String]

    var title: String {
        switch step {
        case .connect:
            return accounts.isEmpty ? "No calendars connected" : "Calendar setup"
        case .refreshRate:
            return "One more step"
        }
    }

    var detail: String {
        switch step {
        case .connect:
            if accounts.isEmpty {
                return "Sayline reads your Mac's calendar. Google and Outlook have to be added in System Settings first."
            }
            return "Sayline reads your Mac's calendar, so it only sees accounts added here."
        case .refreshRate:
            return "In Calendar, press ⌘, then Accounts, and set Refresh Calendars to Every minute. Otherwise changes take up to 15 minutes to reach Sayline."
        }
    }

    var primaryLabel: String {
        step == .connect ? "Open Accounts" : "Open Calendar"
    }

    var secondaryLabel: String {
        step == .connect ? "Not now" : "Done"
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
