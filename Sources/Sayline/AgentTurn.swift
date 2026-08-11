import AppKit
import Foundation

/// What running one action did, from the user's point of view.
///
/// Replaces `AgentExecutor.execute`'s `Bool`, which could say "worked" or
/// "didn't" and nothing else. Everything that needed to say more — I showed
/// a message, I asked a question, I am still working — jumped the queue as
/// its own `if case` in AppDelegate. There were six of those, and meetings
/// would have added two more.
///
/// The distinction that matters is who ends the turn. An action that speaks
/// for itself must not have the indicator pulled out from under it.
enum ActionOutcome {
    /// Silent success. If every action returns this, the pill goes away.
    case done
    /// The handler already showed the user something and owns the ending.
    case reported
    /// A question is on screen. Nothing may touch the indicator until it
    /// resolves — see FloatingIndicatorWindow's queue.
    case asking
    case failed(String)
}

/// Runs the actions from one agent turn and decides how the turn ends.
///
/// Actions dispatch in parallel, deliberately: "remind me to call mom, then
/// open Safari" opens Safari immediately rather than waiting for the
/// reminder conversation. That was an explicit product call (2026-08-11) —
/// waiting would be more correct and would feel slower. The race it used to
/// create is fixed in the indicator instead, by queueing questions rather
/// than letting a second one displace the first.
@MainActor
final class AgentTurnRunner {
    private let indicator: FloatingIndicatorWindow
    private let reminders: ReminderCoordinator
    private let meetings: MeetingCoordinator

    init(indicator: FloatingIndicatorWindow,
         reminders: ReminderCoordinator,
         meetings: MeetingCoordinator) {
        self.indicator = indicator
        self.reminders = reminders
        self.meetings = meetings
    }

    func run(_ actions: [AgentAction]) {
        var failures: [String] = []
        var ownsTheEnding = false

        for action in actions {
            NSLog("Sayline: agent executing -> \(action)")
            switch outcome(for: action) {
            case .done:
                continue
            case .reported, .asking:
                ownsTheEnding = true
            case .failed(let message):
                failures.append(message)
            }
        }

        if let first = failures.first {
            indicator.flashMessage(first, duration: 3.0)
        } else if !ownsTheEnding {
            indicator.hide()
        }
    }

    private func outcome(for action: AgentAction) -> ActionOutcome {
        switch action {
        case .answerQuery(let query):
            let answer = AgentExecutor.answer(query)
            NSLog("Sayline: agent answered -> \(answer)")
            indicator.flashMessage(answer, duration: 4.5)
            return .reported

        case .createReminder(let title, let due):
            Task { await reminders.create(title: title, due: due) }
            return .asking

        case .cancelReminder(let name):
            Task { await reminders.cancel(name: name) }
            return .asking

        case .joinMeeting:
            Task { await meetings.join() }
            return .asking

        case .whatsNextMeeting:
            Task { await meetings.whatsNext() }
            return .asking

        case .emptyTrash:
            return confirmEmptyTrash()

        case .openedSiteButCouldNotSearch(let label, _, _):
            AgentExecutor.execute(action)
            indicator.flashMessage("Opened \(label) — can't search it directly", duration: 3.0)
            return .reported

        case .unknownWebsite(let requested):
            AgentExecutor.execute(action)
            // Refuse rather than guess a TLD, and say what would work
            // instead — a bare "couldn't do that" leaves no way to succeed.
            indicator.flashMessage("Say the full address, like \(requested).com", duration: 3.5)
            return .reported

        case .openSystemSettingsFallback(let requestedPaneName):
            AgentExecutor.execute(action)
            indicator.flashMessage("Couldn't find \"\(requestedPaneName)\" settings", duration: 3.0)
            return .reported

        default:
            return AgentExecutor.execute(action) ? .done : .failed("Agent: couldn't complete that")
        }
    }

    /// Emptying the Trash is the only permanent, unrecoverable thing a
    /// misheard sentence can do, and until now it happened instantly.
    ///
    /// The reason recorded for treating it as safe was that the Trash is
    /// recoverable. That is true of *putting things in* it; emptying is the
    /// one irreversible step in that workflow — it destroys the safety net
    /// rather than using it. The same backlog rejects voice file-deletion
    /// because "a wrong 'delete that file' has no safety net", which is the
    /// same argument pointing the other way.
    ///
    /// It shipped unconfirmed because the follow-up primitive did not exist
    /// yet. It does now, so this costs one click.
    private func confirmEmptyTrash() -> ActionOutcome {
        let count = AgentExecutor.trashItemCount()
        guard count != 0 else {
            indicator.showNotice("The Trash is already empty",
                                 pill: "Empty the trash", duration: 2.4)
            return .reported
        }
        let detail = count.map { "\($0) item\($0 == 1 ? "" : "s") — this cannot be undone" }
            ?? "This cannot be undone"
        indicator.askFollowUp(
            FollowUpRequest(
                question: "Empty the Trash?",
                detail: detail,
                kind: .confirm(primary: "Empty it", secondary: "Keep it"),
                isDestructive: true
            )
        ) { [weak self] answer in
            guard let self else { return }
            guard answer == .confirmed else {
                // Declined, escaped or timed out all mean keep it.
                self.indicator.showNotice("Kept it", detail: "The Trash was not emptied",
                                          pill: "Empty the trash", duration: 2.4)
                return
            }
            if AgentExecutor.execute(.emptyTrash) {
                self.indicator.showNotice("Trash emptied", pill: "Empty the trash")
            } else {
                self.indicator.showNotice("Couldn't empty the Trash",
                                          detail: "Nothing was deleted",
                                          pill: "Empty the trash", duration: 3.4)
            }
        }
        return .asking
    }
}
