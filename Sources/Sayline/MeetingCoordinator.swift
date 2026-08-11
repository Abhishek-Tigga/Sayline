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
                reportEmpty(now: now, pill: "Join my next meeting")
            }
            offerSetupIfFirstTime()
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
        SaylineLog.log("joining \"\(meeting.spokenName)\" -> \(url.absoluteString)")
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
            reportEmpty(now: now, pill: "What's my next meeting")
            offerSetupIfFirstTime()
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
        offerSetupIfFirstTime()
    }

    /// Says why nothing was found, which is not always "nothing is on".
    ///
    /// A Google Calendar that was never added to macOS produces exactly the
    /// same empty result as a genuinely free afternoon, and telling someone
    /// "no meetings" while their meeting is open in another tab is the kind
    /// of wrong that reads as a broken app rather than a setup step.
    private func reportEmpty(now: Date, pill: String) {
        switch store.diagnoseEmptiness(around: now) {
        case .noCalendarsConfigured:
            SaylineLog.log("no event calendars are configured on this Mac")
            indicator.askFollowUp(
                FollowUpRequest(
                    question: "No calendars are set up on this Mac",
                    detail: "Google and Outlook calendars have to be added in System Settings before Sayline can see them. Open it?",
                    kind: .confirm(primary: "Open Settings", secondary: "Not now")
                )
            ) { answer in
                guard answer == .confirmed else { return }
                guard let url = URL(string:
                    "x-apple.systempreferences:com.apple.preferences.internetaccounts") else { return }
                NSWorkspace.shared.open(url)
            }

        case .suspiciouslyEmpty:
            // Calendars exist and hold nothing for a whole day either side.
            // Possible, and also what an unsynced account looks like — so
            // say both rather than pick one.
            SaylineLog.log("calendars exist but hold no events for 24h either side — possible sync gap")
            indicator.showNotice(
                "No meetings found",
                detail: "If a meeting is missing it may not have synced. Calendar → Settings → Accounts → Refresh Calendars can be set to Every minute.",
                pill: pill, duration: 6.0
            )

        case .nothingScheduled:
            indicator.showNotice(
                "Nothing coming up",
                detail: "No meetings in the next 30 minutes",
                pill: pill
            )
        }
    }

    // MARK: - One-time setup card

    /// Offers the two manual setup steps once, under the answer.
    ///
    /// Shown alongside rather than instead: the answer we just gave is
    /// probably right, and refusing to say what the next meeting is would
    /// be a worse trade than saying it with a caveat attached.
    ///
    /// Once, then never again. A card that reappears every time someone
    /// checks their calendar is a card people learn to dismiss without
    /// reading — and this one is asking for two minutes in two other apps,
    /// which is only worth asking for while it is still novel.
    private func offerSetupIfFirstTime() {
        guard !CalendarSetupState.hasBeenDismissed else { return }
        present(.init(step: .connect, accounts: store.connectedAccounts()))
    }

    private func present(_ card: CalendarSetupCard) {
        indicator.showSetupCard(card) { [weak self] action in
            guard let self else { return }
            switch (card.step, action) {
            case (.connect, .primary):
                // Internet Accounts is where Google and Outlook are added,
                // and it is the one step with a working deep link.
                if let url = URL(string:
                    "x-apple.systempreferences:com.apple.preferences.internetaccounts") {
                    NSWorkspace.shared.open(url)
                }
                // Straight to step two rather than ending here — the
                // refresh interval is the half that actually causes wrong
                // answers, and nobody would come back for it on their own.
                self.present(.init(step: .refreshRate, accounts: card.accounts))

            case (.refreshRate, .primary):
                // Calendar's own settings cannot be deep-linked; opening
                // the app is as close as we get, and the card says which
                // two keystrokes follow.
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
                self.finishSetup()

            case (_, .dismiss):
                self.finishSetup()
            }
        }
    }

    private func finishSetup() {
        CalendarSetupState.markDismissed()
        indicator.dismissSetupCard()
        SaylineLog.log("calendar setup card dismissed — it will not be offered again")
    }

    // MARK: - Access

    private func ensureAccess() async -> Bool {
        switch await store.requestAccess() {
        case .granted:
            return true
        case .failed(let message):
            SaylineLog.log("calendar access failed -> \(message)")
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
