import AppKit
import Foundation

/// Runs the two meeting commands end to end: permission, the query, the
/// answer.
///
/// Mirrors `ReminderCoordinator` on purpose, including the offer-settings
/// flow after a refusal. That shape is built and verified; a second one
/// invented from scratch would be a second set of mistakes.
@MainActor
final class MeetingCoordinator {
    private let store = MeetingStore()
    private let indicator: FloatingIndicatorWindow

    init(indicator: FloatingIndicatorWindow) {
        self.indicator = indicator
    }

    // MARK: - Join

    func join() async {
        guard await ensureAccess() else { return }
        let now = Date()
        let meetings = await store.meetings(around: now)

        guard let meeting = MeetingSelection.nextJoinable(from: meetings, now: now) else {
            // Nothing joinable. If something is there but linkless, say what
            // it is — "no meetings" would be false, and the person can see
            // their own calendar.
            if let next = MeetingSelection.next(from: meetings, now: now) {
                indicator.showNotice(
                    "No join link on your next meeting",
                    detail: "\(next.spokenName) at \(Self.clock.string(from: next.start))",
                    pill: "Join my next meeting",
                    duration: 4.0
                )
            } else {
                indicator.showNotice(
                    "Nothing to join",
                    detail: "No meetings in the next 30 minutes",
                    pill: "Join my next meeting"
                )
            }
            return
        }

        guard let url = meeting.joinURL else { return }
        confirmJoin(meeting, url: url)
    }

    /// Shows which meeting is about to open, then opens it.
    ///
    /// Requested 2026-08-11 after the first live test: joining worked and
    /// was instant, and instant was the problem — "very fast but also very
    /// abrupt, it does not give me a mental break to think about". The name
    /// was already announced, but only as the browser was opening, which is
    /// too late to be a decision.
    ///
    /// So the announcement moves in front of the action, with ten seconds
    /// of grace. Doing nothing still joins, because this is the one
    /// confirmation in the app where silence should mean go: the cost of
    /// joining a meeting you did not want is leaving it, and the cost of
    /// not joining is missing the meeting you just asked for. Every other
    /// confirmation here times out to no, and that inversion is declared at
    /// the call site rather than buried — see `TimeoutOutcome`.
    ///
    /// The speed the fast path bought is not lost. It went into knowing
    /// *which* meeting, instantly; the pause is deliberate, not latency.
    private func confirmJoin(_ meeting: Meeting, url: URL) {
        indicator.askFollowUp(
            FollowUpRequest(
                question: "Joining \(meeting.spokenName)",
                detail: "\(Self.clock.string(from: meeting.start)) · \(url.host ?? "")",
                kind: .confirm(primary: "Join now", secondary: "Not this one"),
                timeoutMeans: .confirmed,
                timeout: 10
            )
        ) { [weak self] answer in
            guard let self else { return }
            guard answer != .declined else {
                self.indicator.showNotice("Didn't join",
                                          detail: meeting.spokenName,
                                          pill: "Join my next meeting", duration: 2.4)
                return
            }
            self.open(url, for: meeting)
        }
    }

    private func open(_ url: URL, for meeting: Meeting) {
        NSLog("%@", "Sayline: joining \"\(meeting.spokenName)\" -> \(url.absoluteString)")
        if NSWorkspace.shared.open(url) {
            indicator.showNotice(
                "Joining \(meeting.spokenName)",
                detail: Self.clock.string(from: meeting.start),
                pill: "Join my next meeting"
            )
        } else {
            indicator.showNotice(
                "Couldn't open the meeting link",
                detail: meeting.spokenName,
                pill: "Join my next meeting",
                duration: 4.0
            )
        }
    }

    // MARK: - What's next

    func whatsNext() async {
        guard await ensureAccess() else { return }
        let now = Date()
        let meetings = await store.meetings(around: now)

        guard let meeting = MeetingSelection.next(from: meetings, now: now) else {
            indicator.showNotice(
                "Nothing coming up",
                detail: "No meetings in the next 30 minutes",
                pill: "What's my next meeting"
            )
            return
        }

        // The box rather than the pill flash, decided 2026-08-11. The design
        // chose a flash to ship the smaller thing first and named "if the
        // flash proves too small" as the trigger for a box; a name, a time
        // and a link status is three facts, which is more than one line
        // holds. The box existed and was verified by then.
        let when = Self.clock.string(from: meeting.start)
        let detail = meeting.joinURL == nil ? "\(when) — no join link" : when
        indicator.showNotice(meeting.spokenName, detail: detail,
                             pill: "What's my next meeting", duration: 4.5)
    }

    // MARK: - Access

    private func ensureAccess() async -> Bool {
        switch await store.requestAccess() {
        case .granted:
            return true
        case .failed(let message):
            NSLog("Sayline: calendar access failed -> \(message)")
            indicator.showNotice("Couldn't reach your calendar",
                                 detail: "Try again in a moment",
                                 pill: "Calendar", duration: 3.6)
            return false
        case .denied:
            offerSettings()
            return false
        }
    }

    /// macOS will not show the prompt twice, so System Settings is the only
    /// route left. Offered once, opened only on a yes.
    private func offerSettings() {
        indicator.askFollowUp(
            FollowUpRequest(
                question: "Calendar access is off. Open System Settings?",
                kind: .confirm(primary: "Open Settings", secondary: "Not now")
            )
        ) { answer in
            guard answer == .confirmed else { return }
            guard let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
            NSWorkspace.shared.open(url)
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}
