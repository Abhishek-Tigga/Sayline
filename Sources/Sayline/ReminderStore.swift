import EventKit
import Foundation

/// Reminders, backed by Apple's own store rather than one of ours.
///
/// The trade was made deliberately (DESIGN-meetings-reminders.md): Apple
/// Reminders already syncs to iPhone, already fires notifications and
/// already has a UI, and building our own means rebuilding three things
/// that already exist. We drop it if the notification UI disappoints, or
/// the moment we want something it cannot do — asking to be reminded again
/// when a reminder fires is the motivating example.
///
/// Full access rather than write-only, because cancel-by-name has to read
/// the list to find a match.
enum ReminderAccess: Equatable {
    case granted
    /// Refused, or restricted by policy. Both are dead ends from code —
    /// macOS remembers a no and will not show the prompt again.
    case denied
    case failed(String)
}

struct ReminderMatch: Equatable {
    let id: String
    let title: String
    let due: Date?
    /// Higher is closer. Only meaningful within one search.
    let score: Int
}

final class ReminderStore {
    private let store = EKEventStore()

    /// The last reminder we created, and when. Backs "cancel that", which
    /// is deliberately narrow: past a few minutes "that" is genuinely
    /// ambiguous, and a wrong guess deletes something real.
    private(set) var lastCreatedID: String?
    private(set) var lastCreatedTitle: String?
    private(set) var lastCreatedAt: Date?
    static let cancelThatWindow: TimeInterval = 5 * 60

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
    }

    /// Asks only when macOS would actually show the prompt. A refusal is
    /// permanent from here — the system will not ask twice — so callers
    /// must offer the settings route rather than trying again.
    func requestAccess() async -> ReminderAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return .granted
        case .denied, .restricted, .writeOnly:
            // writeOnly counts as denied here: it cannot read, and every
            // cancel path needs to.
            return .denied
        default:
            do {
                let granted = try await store.requestFullAccessToReminders()
                return granted ? .granted : .denied
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Creating

    /// Creates a reminder in the default list.
    ///
    /// An undated reminder is a real outcome, not a failure: when the time
    /// is missing or unreadable the reminder is still created, because
    /// losing what someone asked to be reminded of is worse than losing
    /// the time they asked for it.
    @discardableResult
    func create(title: String, due: Date?) throws -> String {
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()

        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due
            )
            // Without an alarm a due date is just a label — Reminders shows
            // it in the list and never notifies. "Remind me" that doesn't
            // remind is the one failure this feature cannot have.
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }

        try store.save(reminder, commit: true)
        lastCreatedID = reminder.calendarItemIdentifier
        lastCreatedTitle = title
        lastCreatedAt = Date()
        SaylineLog.log("created reminder \"\(title)\"\(due.map { " due \($0)" } ?? " with no time")")
        return reminder.calendarItemIdentifier
    }

    // MARK: - Cancelling

    /// The reminder "cancel that" refers to, if it is still in scope.
    func recentlyCreated() -> (id: String, title: String)? {
        guard let id = lastCreatedID,
              let title = lastCreatedTitle,
              let at = lastCreatedAt,
              Date().timeIntervalSince(at) <= Self.cancelThatWindow else { return nil }
        return (id, title)
    }

    /// Everything in the default list matching a spoken name, closest
    /// first.
    ///
    /// Searches the whole list rather than only what Sayline made — nobody
    /// remembers which reminders came from voice, so a tool that only
    /// cancelled its own would feel broken half the time. That reach is
    /// exactly why the caller confirms before deleting anything.
    func search(name: String) async -> [ReminderMatch] {
        guard let calendar = store.defaultCalendarForNewReminders() else { return [] }
        let predicate = store.predicateForReminders(in: [calendar])
        let reminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: found ?? [])
            }
        }

        let wanted = Self.tokens(name)
        guard !wanted.isEmpty else { return [] }

        return reminders
            .filter { !$0.isCompleted }
            .compactMap { reminder -> ReminderMatch? in
                let title = reminder.title ?? ""
                let score = Self.score(title: title, wanted: wanted)
                guard score > 0 else { return nil }
                return ReminderMatch(
                    id: reminder.calendarItemIdentifier,
                    title: title,
                    due: reminder.dueDateComponents.flatMap(Calendar.current.date(from:)),
                    score: score
                )
            }
            .sorted { $0.score > $1.score }
    }

    func delete(id: String) throws {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw NSError(domain: "Sayline", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "That reminder no longer exists",
            ])
        }
        let title = reminder.title ?? "reminder"
        try store.remove(reminder, commit: true)
        if id == lastCreatedID { lastCreatedID = nil }
        SaylineLog.log("deleted reminder \"\(title)\"")
    }

    // MARK: - Matching

    private static let noiseWords: Set<String> = [
        "the", "a", "an", "my", "reminder", "reminders", "to", "for", "about",
    ]

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !noiseWords.contains($0) && $0.count > 1 }
    }

    /// Whole-word overlap, with a bonus for an exact title.
    ///
    /// Deliberately not fuzzy character matching. A near-miss on letters
    /// ("dentist" vs "dentists") gains little, while the failure it invites
    /// — deleting a reminder that merely looks similar — is permanent.
    private static func score(title: String, wanted: [String]) -> Int {
        let have = Set(tokens(title))
        guard !have.isEmpty else { return 0 }
        let overlap = wanted.filter { have.contains($0) }.count
        guard overlap > 0 else { return 0 }
        let exact = Set(wanted) == have ? 5 : 0
        return overlap * 2 + exact
    }
}
