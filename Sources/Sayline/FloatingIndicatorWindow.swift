import Cocoa
import SwiftUI

/// A small borderless, non-activating overlay window that shows
/// recording/transcribing/cleanup status, plus a style-picker row while
/// actively recording. Never becomes key window and ignores mouse events,
/// so it never steals keyboard focus from whatever app the user is
/// dictating into (that would break AX text insertion, which depends on
/// the real target app staying focused).
///
/// Fixed size for the whole session — the pill inside is always
/// bottom-anchored via RecordingIndicatorView's own frame alignment, so it
/// never shifts position whether or not the style row is showing above it.
///
/// The panel itself is disposable, rebuilt on every show() rather than
/// reused across the app's lifetime — found live that a long-lived
/// NSPanel with .canJoinAllSpaces/.stationary can silently stop
/// responding to orderFrontRegardless() after enough show/hide cycles
/// (Space switches, other apps stealing focus via
/// activateFileViewerSelecting, etc. are the suspected trigger, but the
/// exact AppKit cause wasn't pinned down). A freshly constructed panel
/// can't carry forward whatever internal ordering state got corrupted,
/// so this sidesteps the bug class instead of chasing the root cause.
/// Temporary instrumentation (2026-08-09) for a suspected window leak.
///
/// `hide()` calls `orderOut(_:)` and drops our reference, but never
/// `close()`, and the panel sets `isReleasedWhenClosed = false`. If AppKit
/// is still holding these, every dictation leaves behind a live panel — and
/// each one keeps running three `TimelineView(.animation)` loops (redrawing
/// every display frame, 60–120fps) plus a Liquid Glass material that
/// continuously samples the screen behind it. 22 of those accumulated in
/// one 7-minute session, which is a plausible cause of the system-wide
/// freezes, since a bogged-down graphics system would also explain why the
/// event tap gets cut while the app is otherwise idle.
///
/// Counting creates against deallocs settles it. Equal counts means windows
/// are fine and the freeze is elsewhere; zero deallocs confirms the leak.
private final class IndicatorPanel: NSPanel {
    private static var liveCount = 0

    static func noteCreated() {
        liveCount += 1
        NSLog("Sayline: [panel-leak-probe] created — \(liveCount) alive")
    }

    deinit {
        IndicatorPanel.liveCount -= 1
        NSLog("Sayline: [panel-leak-probe] deallocated — \(IndicatorPanel.liveCount) alive")
    }
}

final class FloatingIndicatorWindow {
    private var panel: NSPanel?
    private let viewModel = IndicatorViewModel()
    /// Fires the fallback if nobody answers. Cancelled on any real answer.
    private var followUpTimer: DispatchWorkItem?
    /// Guards single-fire. A button press racing the timeout must not
    /// deliver two answers — the second would act on a reminder the first
    /// already created.
    private var followUpCompletion: ((FollowUpAnswer) -> Void)?
    /// The question as asked, kept so an unclear spoken answer can be
    /// re-asked without the caller rebuilding it.
    private var followUpRequest: FollowUpRequest?
    /// One re-ask only. Past that we take the safe path rather than
    /// looping someone through a question they cannot answer.
    private var followUpDidRetry = false
    /// Identifies the current notice, so a later one cancels the earlier
    /// one's dismissal rather than both firing.
    private var noticeShownAt: Date?

    // A fixed-size "stage" the small pill centers/bottom-anchors within
    // (via RecordingIndicatorView's own frame alignment) — wider and
    // taller than the pill itself actually needs, with margin to spare
    // for the widest text state ("Agent Listening").
    /// Sized generously rather than resized per state. The speech box can
    /// reach ~324x230, so the old 320x46 stage is far too small. Growing
    /// the panel on every state change would mean resizing and
    /// repositioning mid-animation; an oversized panel costs nothing
    /// instead, because it is transparent and ignores mouse events.
    private let width: CGFloat = 380
    private let height: CGFloat = 320
    // Anchored to the screen's true physical bottom edge (screen.frame,
    // not visibleFrame) rather than the Dock-aware visible area — found
    // live that visibleFrame.minY differs across setups with different
    // Dock configurations, so an identical bottomMargin value produced
    // visibly different positions on an external monitor vs. the
    // MacBook's built-in display. This makes "16px from bottom" literal
    // and consistent everywhere. Tradeoff: if the Dock is visible
    // (not auto-hidden) and tall, it can now sit on top of the pill —
    // accepted since the alternative was inconsistent positioning.
    private let bottomMargin: CGFloat = 16

    func show(state: RecordingIndicatorState) {
        viewModel.state = state
        let panel = self.panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        panel.orderFrontRegardless()
        NSLog("Sayline: indicator shown -> \(state)")
    }

    /// Shows a short-lived failure/status message, then auto-hides —
    /// used for agent outcomes that previously had no visible feedback
    /// at all (no match found, app not found, request declined).
    func flashMessage(_ text: String, duration: TimeInterval = 1.6) {
        show(state: .message(text))
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.viewModel.state == .message(text) else { return }
            self.hide()
        }
    }

    /// Keeps the "hold ⌥ and say…" hint naming the key that is actually
    /// bound. A hint pointing at the wrong key is worse than no hint.
    func updateHotkeySymbol(_ symbol: String) {
        viewModel.hotkeySymbol = symbol
    }

    func updateAgentMode(_ isAgentMode: Bool) {
        viewModel.isAgentMode = isAgentMode
        if isAgentMode {
            NSLog("Sayline: agent mode flagged for this recording")
        }
    }

    /// Shows a result in the same box a question uses, with the command
    /// itself in the pill below — the same two-part shape as the question
    /// that produced it, so an answer does not arrive somewhere new.
    ///
    /// Auto-hides. A pending question wins: a result must never take a
    /// question off screen before it has been answered.
    func showNotice(_ text: String,
                    detail: String? = nil,
                    pill: String,
                    duration: TimeInterval = 3.6) {
        guard followUpCompletion == nil else {
            NSLog("Sayline: notice suppressed — a question is still waiting")
            return
        }
        viewModel.setNotice(text, detail: detail)
        show(state: .message(pill))
        let shown = Date()
        noticeShownAt = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.noticeShownAt == shown else { return }
            self.viewModel.setNotice(nil)
            self.hide()
        }
    }

    /// Sets the text shown in the speech-back box above the pill. Agent
    /// mode only, and only after transcription returns — there are no words
    /// before that, since Groq Whisper is batch rather than streaming.
    func showTranscript(_ text: String?) {
        viewModel.setTranscript(text)
    }

    func hide() {
        // A pending question owns the screen until it is answered, escaped
        // or times out. Without this, a hold too brief to transcribe — or
        // one into a muted mic — takes the question away while its timer
        // keeps running, and the next hold silently becomes dictation
        // again. That is the exact confusion the persistent agent pill
        // exists to prevent, so the invariant is enforced here rather than
        // at each of the six call sites.
        if followUpCompletion != nil {
            NSLog("Sayline: hide() ignored — a question is still waiting for an answer")
            return
        }
        panel?.orderOut(nil)
        panel = nil
        viewModel.setTranscript(nil)
        viewModel.setFollowUp(nil)
        viewModel.setNotice(nil)
        noticeShownAt = nil
        NSLog("Sayline: indicator hidden")
    }

    // MARK: - Follow-up

    /// Puts a question on screen and calls back exactly once, with an
    /// answer or `.timedOut`.
    ///
    /// The panel is click-through in every other state, so that it can
    /// never intercept a click meant for the app underneath. Buttons need
    /// the opposite, so mouse events are enabled only while a question is
    /// up and switched straight back afterwards. `.nonactivatingPanel` is
    /// what makes that safe: a click lands on the button without activating
    /// Sayline, so focus stays in whatever the user was typing into — and
    /// AX text insertion depends on that focus never moving.
    func askFollowUp(_ request: FollowUpRequest,
                     completion: @escaping (FollowUpAnswer) -> Void) {
        finishFollowUp(.timedOut, reason: "replaced by a new question")

        followUpCompletion = completion
        followUpRequest = request
        followUpDidRetry = false
        viewModel.onFollowUpAnswer = { [weak self] answer in
            self?.finishFollowUp(answer, reason: "answered")
        }
        // Agent styling stays on for the whole exchange, not just the
        // recording that started it. While a question is up the next hold
        // of the hotkey is an answer rather than dictation, and the pill is
        // the only thing that says so — a dictation-looking pill whose next
        // hold gets eaten as an answer is a genuinely confusing bug.
        viewModel.isAgentMode = true
        viewModel.setFollowUp(request)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        reposition(panel)
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        NSLog("%@", "Sayline: asking -> \(request.question)")

        restartTimeout()
    }

    /// Delivers a spoken answer. Called when the next transcript arrives,
    /// since answering runs through the normal hold-and-speak pipeline
    /// rather than anything this window owns.
    ///
    /// A yes/no question is read here, because "yes" and "no" mean the same
    /// thing whatever asked them. A value question is passed through
    /// untouched — only the caller knows whether "half past four" parses.
    func answerFollowUp(spoken text: String) {
        guard let request = followUpRequest else { return }
        guard case .confirm = request.kind else {
            finishFollowUp(.spoken(text), reason: "spoken")
            return
        }
        switch SpokenConsent.read(text) {
        case .affirmative:
            finishFollowUp(.confirmed, reason: "said yes")
        case .negative:
            finishFollowUp(.declined, reason: "said no")
        case .unclear where !followUpDidRetry:
            followUpDidRetry = true
            NSLog("%@", "Sayline: couldn't read yes or no from \"\(text)\" — asking once more")
            viewModel.setFollowUp(request) // restarts the countdown
            restartTimeout()
        case .unclear:
            // Safe path. Never guess yes: yes is the irreversible direction.
            finishFollowUp(.declined, reason: "still unclear, taking the safe path")
        }
    }

    /// True while any question is on screen — every kind can be answered by
    /// voice, so the next hold is always an answer rather than dictation.
    var isAwaitingSpokenAnswer: Bool { viewModel.followUp != nil }

    /// Escape, from the event tap. Same outcome as the secondary button:
    /// declined is the safe path for a confirm, and "no time given" for a
    /// value, which still creates the reminder undated.
    func dismissFollowUp() {
        finishFollowUp(.declined, reason: "escape")
    }

    private func restartTimeout() {
        followUpTimer?.cancel()
        let timer = DispatchWorkItem { [weak self] in
            self?.finishFollowUp(.timedOut, reason: "no answer in \(Int(followUpTimeout))s")
        }
        followUpTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + followUpTimeout, execute: timer)
    }

    private func finishFollowUp(_ answer: FollowUpAnswer, reason: String) {
        guard let completion = followUpCompletion else { return }
        followUpCompletion = nil
        followUpRequest = nil
        followUpDidRetry = false
        followUpTimer?.cancel()
        followUpTimer = nil
        viewModel.onFollowUpAnswer = nil
        viewModel.setFollowUp(nil)
        panel?.ignoresMouseEvents = true
        NSLog("%@", "Sayline: follow-up \(reason) -> \(answer)")
        completion(answer)
    }

    private func makePanel() -> NSPanel {
        let panel = IndicatorPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        IndicatorPanel.noteCreated()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Forces dark rendering for the whole hosted view tree regardless
        // of the system-wide Light/Dark setting — matters for the real
        // Liquid Glass material (macOS 26+), which is colorScheme-aware.
        // Doesn't fix the material's separate backdrop-adaptive flicker
        // (see RecordingIndicatorView's KNOWN OPEN ISSUE note) — that's
        // driven by content behind the window, not app-declared
        // appearance — but is still correct to keep regardless.
        panel.appearance = NSAppearance(named: .darkAqua)
        // .statusBar (not .floating) so the pill renders above the Dock
        // when it's visible/not-auto-hidden — .floating sits above
        // normal app windows but below the Dock, which let a
        // non-auto-hidden Dock visually cover the pill.
        panel.level = .statusBar
        panel.hasShadow = false // temporarily disabled to test a reported lighter-than-black edge on all 4 sides
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: RecordingIndicatorView(viewModel: viewModel))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        return panel
    }

    private func reposition(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let x = screenFrame.midX - width / 2
        let y = screenFrame.minY + bottomMargin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
