import AppKit
import Foundation

/// Runs the reminder commands end to end: permission, the missing-time
/// question, the ambiguous-match confirmation, and the result message.
///
/// Separate from ReminderStore, which only knows EventKit, and from
/// AppDelegate, which only dispatches. The interesting behaviour is the
/// conversation — asking for a time, confirming a delete — and it belongs
/// with neither of those.
@MainActor
final class ReminderCoordinator {
    private let store = ReminderStore()
    private let indicator: FloatingIndicatorWindow
    private let hotkeySymbol: () -> String

    init(indicator: FloatingIndicatorWindow, hotkeySymbol: @escaping () -> String) {
        self.indicator = indicator
        self.hotkeySymbol = hotkeySymbol
    }

    // MARK: - Create

    func create(title: String, due: Date?) async {
        guard await ensureAccess() else { return }

        if let due {
            save(title: title, due: due)
            return
        }
        // No time was said. Ask rather than silently creating an undated
        // reminder — someone who says "remind me" usually means at a time,
        // and a reminder that never fires is a quiet failure.
        askForTime(title: title, isRetry: false)
    }

    private func askForTime(title: String, isRetry: Bool) {
        let question = isRetry
            ? "Sorry — when should I remind you?"
            : "What time should I remind you?"
        indicator.askFollowUp(
            FollowUpRequest(
                question: question,
                detail: title,
                kind: .value(hint: "Hold \(hotkeySymbol()) and say a time"),
                quickChoices: [
                    QuickChoice(label: "In an hour", spoken: "in an hour"),
                    QuickChoice(label: "Tomorrow 9am", spoken: "tomorrow at 9am"),
                    QuickChoice(label: "No time", spoken: "no time"),
                ]
            )
        ) { [weak self] answer in
            guard let self else { return }
            Task { await self.handleTimeAnswer(title: title, answer: answer, wasRetry: isRetry) }
        }
    }

    private func handleTimeAnswer(title: String, answer: FollowUpAnswer, wasRetry: Bool) async {
        switch answer {
        case .declined, .timedOut:
            // Escape, "No time", or twenty seconds of silence. The reminder
            // is still created — losing what someone asked to be reminded
            // of is worse than losing the time they wanted it at.
            save(title: title, due: nil)
        case .confirmed:
            save(title: title, due: nil)
        case .spoken(let text):
            if SpokenConsent.read(text) == .negative {
                save(title: title, due: nil)
                return
            }
            if let due = await resolveTime(from: text) {
                save(title: title, due: due)
            } else if !wasRetry {
                NSLog("%@", "Sayline: couldn't read a time from \"\(text)\" — asking once more")
                askForTime(title: title, isRetry: true)
            } else {
                // Asked twice, still unreadable. Create it undated and say
                // so, rather than dropping it after making someone answer.
                NSLog("%@", "Sayline: still no usable time from \"\(text)\" — creating it undated")
                save(title: title, due: nil)
            }
        }
    }

    private func save(title: String, due: Date?) {
        do {
            try store.create(title: title, due: due)
            indicator.showNotice(
                "Reminder created",
                detail: due.map { Self.spoken.string(from: $0) } ?? "No time set",
                pill: title
            )
        } catch {
            NSLog("Sayline: couldn't save reminder -> \(error.localizedDescription)")
            indicator.showNotice(
                "Couldn't create that reminder",
                detail: "Nothing was saved — try again",
                pill: title,
                duration: 4.0
            )
        }
    }

    // MARK: - Cancel

    func cancel(name: String?) async {
        guard await ensureAccess() else { return }

        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            cancelLast()
            return
        }

        let matches = await store.search(name: name)
        switch matches.count {
        case 0:
            indicator.showNotice("No reminder matches that",
                                 detail: "Nothing called \"\(name)\" in your list",
                                 pill: name)
        case 1:
            confirmDelete(matches[0], others: 0)
        default:
            // Several matched. Read back the closest and ask, because there
            // is no undo — EventKit deletion is permanent, and "cancel that"
            // covers the last thing created, not the last thing deleted.
            confirmDelete(matches[0], others: matches.count - 1)
        }
    }

    private func cancelLast() {
        guard let recent = store.recentlyCreated() else {
            // Outside the five-minute window "that" is genuinely ambiguous.
            // Say what would work instead of guessing at a reminder.
            indicator.showNotice("Nothing recent to cancel",
                                 detail: "Say which reminder to remove",
                                 pill: "Cancel that",
                                 duration: 4.0)
            return
        }
        delete(id: recent.id, title: recent.title)
    }

    private func confirmDelete(_ match: ReminderMatch, others: Int) {
        let question = others > 0
            ? "\(others + 1) reminders match. Delete the closest?"
            : "Delete this reminder?"
        indicator.askFollowUp(
            FollowUpRequest(
                question: question,
                detail: Self.describe(match),
                kind: .confirm(primary: "Delete it", secondary: "Keep it"),
                isDestructive: true
            )
        ) { [weak self] answer in
            guard let self else { return }
            guard answer == .confirmed else {
                // Declined, escaped or timed out all mean keep it. Never
                // guess yes: yes is the irreversible direction.
                self.indicator.showNotice("Kept it", detail: "Nothing was deleted", pill: match.title, duration: 2.6)
                return
            }
            self.delete(id: match.id, title: match.title)
        }
    }

    private func delete(id: String, title: String) {
        do {
            try store.delete(id: id)
            indicator.showNotice("Reminder deleted", pill: title)
        } catch {
            NSLog("Sayline: couldn't delete reminder -> \(error.localizedDescription)")
            indicator.showNotice(
                "Couldn't delete that reminder",
                detail: "It's still there",
                pill: title,
                duration: 4.0
            )
        }
    }

    // MARK: - Access

    /// Asks on first use, never at launch. People agree to a prompt they
    /// asked for and refuse one that ambushes them.
    private func ensureAccess() async -> Bool {
        switch await store.requestAccess() {
        case .granted:
            return true
        case .failed(let message):
            NSLog("Sayline: reminders access failed -> \(message)")
            indicator.showNotice("Couldn't reach Reminders",
                                 detail: "Try again in a moment",
                                 pill: "Reminders",
                                 duration: 3.6)
            return false
        case .denied:
            offerSettings()
            return false
        }
    }

    /// macOS will not show the prompt twice, so the only route left is
    /// System Settings. Offered once, opened only on a yes — an app that
    /// keeps asking after a no is the behaviour people uninstall over.
    private func offerSettings() {
        indicator.askFollowUp(
            FollowUpRequest(
                question: "Reminders access is off. Open System Settings?",
                kind: .confirm(primary: "Open Settings", secondary: "Not now")
            )
        ) { answer in
            guard answer == .confirmed else { return }
            guard let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// Turns a spoken time into a date, on device.
    ///
    /// NSDataDetector rather than another round trip to the router: it is
    /// what Apple uses for the same job, it understands "tomorrow at 3",
    /// "in an hour" and "next Tuesday", and it costs no latency or tokens.
    /// The design said the model resolves the time, and it still does for
    /// the original command — this is only the answer to our own question,
    /// where a second API call would be pure waste.
    ///
    /// A time already past is rejected rather than quietly moved. "Remind
    /// me at 9" said at 10pm most likely means tomorrow, but guessing
    /// which day is how a reminder ends up firing at the wrong one.
    private func resolveTime(from text: String) async -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = detector.firstMatch(in: text, range: range),
              let date = match.date else { return nil }
        guard date.timeIntervalSinceNow > -60 else {
            NSLog("%@", "Sayline: \"\(text)\" resolved to \(date), which is in the past — asking again")
            return nil
        }
        // A year out is not a reminder, it is a typo in speech.
        guard date.timeIntervalSinceNow < 366 * 24 * 3600 else { return nil }
        return date
    }

    // MARK: - Formatting

    private static let spoken: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true // "Today", "Tomorrow"
        return f
    }()

    private static func describe(_ match: ReminderMatch) -> String {
        guard let due = match.due else { return match.title }
        return "\(match.title) — \(spoken.string(from: due))"
    }
}