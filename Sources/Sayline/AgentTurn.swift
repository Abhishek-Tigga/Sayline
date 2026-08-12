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
            SaylineLog.log("agent executing -> \(action)")
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
            SaylineLog.log("agent answered -> \(answer)")
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

        case .controlMedia(let command):
            // Off the main thread, always. Finding the target inspects
            // other processes and the AppleScript route waits on another
            // app answering — including, the first time, on a permission
            // dialog someone may leave sitting there. Blocking main on any
            // of that is how this app's unexplained freezes look.
            Task { await self.controlMedia(command) }
            return .asking

        case .askWhatToPlay:
            return askWhatToPlay()

        case .closeCurrentTab:
            return closeCurrentTab()

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

    // MARK: - Media

    /// Finds what is playing, then drives it by whatever route that app
    /// supports.
    ///
    /// The empty case is the one worth caring about. "Nothing is playing"
    /// used to be unsayable — the app had no way to know — so a misheard
    /// "stop" opened YouTube. It is now a real answer, and a trustworthy
    /// one: the detector over-reports rather than under-reports, so an
    /// empty result genuinely means nothing holds the output.
    private func controlMedia(_ command: MediaCommand) async {
        let targets = await Task.detached { MediaTarget.audible() }.value

        // Direction matters, and the media key has none — it is a toggle.
        //
        // Sending it blindly is why "stop the music" *started* paused music
        // and "resume" did nothing: both commands posted the same key, so
        // the outcome depended entirely on what the player was already
        // doing. The detector is what supplies the missing direction.
        //
        // Skip/previous are unaffected: they mean the same thing whatever
        // the current state, so they always send.
        switch (command, targets.isEmpty) {
        case (.pause, true):
            // Nothing audible and asked to stop. Toggling here would start
            // something, which is the opposite of what was asked.
            indicator.flashMessage("Nothing is playing", duration: 2.4)
            return
        case (.play, false):
            // Already playing and asked to play. Toggling would pause it.
            indicator.flashMessage("\(targets[0].appName) is already playing", duration: 2.4)
            return
        case (.play, true):
            // Asked to resume with nothing audible. There is no target to
            // aim at — a paused browser tab may still hold the audio
            // device, but a paused Spotify does not — so send the key
            // broadcast and claim only that.
            await resumeWithNoKnownTarget()
            return
        case (.next, true), (.previous, true):
            indicator.flashMessage("Nothing is playing", duration: 2.4)
            return
        default:
            break
        }

        guard let first = targets.first else { return }

        guard targets.count > 1 else {
            await apply(command, to: first)
            return
        }

        // Two things audible at once — a tab and Spotify, say. Guessing
        // here is a coin flip that pauses the wrong one, and the person
        // asking is the only one who knows which they meant.
        let second = targets[1]
        indicator.askFollowUp(
            FollowUpRequest(
                question: "Which one?",
                detail: "\(first.appName) and \(second.appName) are both playing",
                kind: .confirm(primary: first.appName, secondary: second.appName)
            )
        ) { [weak self] answer in
            guard let self else { return }
            switch answer {
            case .confirmed:
                Task { await self.apply(command, to: first) }
            case .declined:
                Task { await self.apply(command, to: second) }
            case .timedOut, .spoken:
                // Silence picks nothing. Acting on a guess after a
                // question about which of two to act on would make the
                // question decorative.
                self.indicator.flashMessage("Left both alone", duration: 2.4)
            }
        }
    }

    /// "Resume" when nothing is making sound.
    ///
    /// A paused Spotify disappears from the audible list entirely, so there
    /// is no target to route to — but the request is still perfectly
    /// reasonable. Ask the scriptable players directly, since they answer
    /// even while paused, and fall back to the broadcast key otherwise.
    private func resumeWithNoKnownTarget() async {
        let sentence = await Task.detached {
            MediaControl.resumeWhateverWasPaused()
        }.value
        SaylineLog.log("media Play with nothing audible -> \(sentence)")
        indicator.flashMessage(sentence, duration: 3.0)
    }

    private func apply(_ command: MediaCommand, to target: MediaTarget) async {
        let sentence = await Task.detached { MediaControl.perform(command, on: target) }.value
        SaylineLog.log("media \(command.rawValue) on \(target) -> \(sentence)")
        indicator.flashMessage(sentence, duration: 3.0)
    }

    /// Asks what to play, then plays it — without going back to the model.
    ///
    /// The question offers the shape of an answer rather than leaving it
    /// open. "What would you like to hear?" invites silence; naming the
    /// three kinds of answer that work — an artist, a song, a genre — tells
    /// someone that "Bollywood" is a complete reply.
    ///
    /// The reply bypasses the router deliberately. Intent is already known,
    /// so a second round trip would spend two seconds re-deriving it, and
    /// re-routing a bare "Bollywood" risks it coming back as a web search
    /// for the word.
    private func askWhatToPlay() -> ActionOutcome {
        indicator.askFollowUp(
            FollowUpRequest(
                question: "What would you like to hear?",
                detail: "An artist, a song, or a genre — Bollywood, lo-fi, Afrobeat",
                kind: .value(hint: "Hold the hotkey and say it")
            )
        ) { [weak self] answer in
            guard let self else { return }
            guard case .spoken(let request) = answer,
                  !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // Declined or timed out. Nothing was playing before and
                // nothing is playing now, so there is nothing to undo —
                // just say the question closed.
                self.indicator.flashMessage("Nothing playing", duration: 2.0)
                return
            }
            Task { await self.play(request) }
        }
        return .asking
    }

    private func play(_ request: String) async {
        indicator.show(state: .agentRouting)
        // The same top-video path "play lo-fi on YouTube" already uses, so
        // a reply lands on a playing video rather than a results page.
        guard let url = await YouTubeSearch.topVideoURL(for: request) else {
            // No key, no quota, or no network. The search page is what the
            // rest of the app degrades to, so degrade the same way instead
            // of failing — they can press play themselves.
            guard case .site(let label, let searchURL) = WebsiteCatalog.resolve("YouTube", query: request) else {
                indicator.flashMessage("Couldn't find anything for \"\(request)\"", duration: 3.0)
                return
            }
            SaylineLog.log("no video for \"\(request)\" — opening YouTube search instead")
            AgentExecutor.execute(.openWebsite(label: label, url: searchURL))
            indicator.flashMessage("Opened YouTube results for \"\(request)\"", duration: 3.0)
            return
        }
        AgentExecutor.execute(.openWebsite(label: "YouTube — \(request)", url: url))
        indicator.flashMessage("Playing \(request)", duration: 2.4)
    }

    /// Closes a browser tab, and refuses to send the keystroke anywhere
    /// else.
    ///
    /// Cmd+W goes to whatever holds focus. Without this gate, "close this
    /// tab" said while Pages is frontmost closes a document — the command
    /// appears to work while doing something completely different, which is
    /// worse than doing nothing. So it checks first and says either way.
    ///
    /// No confirmation: the request is explicit, and a browser tab comes
    /// back with Cmd+Shift+T. Confirming every one would teach people to
    /// stop using it.
    private func closeCurrentTab() -> ActionOutcome {
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName
        guard let frontmost,
              case .browser = MediaTarget.classify(appName: frontmost) else {
            indicator.flashMessage("The front window isn't a browser", duration: 3.0)
            return .reported
        }

        // Ask the browser, rather than firing Cmd+W and hoping.
        //
        // Cmd+W closes the front *window*, and a window down to its last
        // tab closes completely — which is how "close this tab" took out a
        // whole Chrome window full of open links. Closing the active tab by
        // name leaves the window and its siblings untouched.
        switch MediaControl.tabSituation(in: frontmost) {
        case .oneOfMany(let remaining):
            guard MediaControl.closeActiveTab(in: frontmost) else {
                return .failed("Couldn't close the tab")
            }
            indicator.flashMessage("Closed the tab — \(remaining) left", duration: 2.4)
            return .reported

        case .lastTab:
            // The only tab, so this closes the window however it is done.
            // That is a bigger thing than was asked for, so ask first.
            indicator.askFollowUp(
                FollowUpRequest(
                    question: "That's the last tab",
                    detail: "Closing it closes the \(frontmost) window. Close it?",
                    kind: .confirm(primary: "Close it", secondary: "Keep it")
                )
            ) { [weak self] answer in
                guard let self else { return }
                guard answer == .confirmed else {
                    self.indicator.flashMessage("Left it open", duration: 2.0)
                    return
                }
                _ = MediaControl.closeActiveTab(in: frontmost)
                self.indicator.flashMessage("Closed the \(frontmost) window", duration: 2.4)
            }
            return .asking

        case .unknown:
            // Not scriptable — the keystroke is all we have, and we cannot
            // tell what it will hit. Say so rather than guessing.
            indicator.askFollowUp(
                FollowUpRequest(
                    question: "Close the front \(frontmost) tab?",
                    detail: "Sayline can't check how many tabs are open, so this may close the window.",
                    kind: .confirm(primary: "Close it", secondary: "Cancel")
                )
            ) { [weak self] answer in
                guard let self else { return }
                guard answer == .confirmed else {
                    self.indicator.flashMessage("Left it open", duration: 2.0)
                    return
                }
                _ = AgentExecutor.execute(.closeCurrentTab)
                self.indicator.flashMessage("Sent close to \(frontmost)", duration: 2.4)
            }
            return .asking
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
