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
final class FloatingIndicatorWindow {
    private var panel: NSPanel?
    private let viewModel = IndicatorViewModel()

    // A fixed-size "stage" the small pill centers/bottom-anchors within
    // (via RecordingIndicatorView's own frame alignment) — wider and
    // taller than the pill itself actually needs, with margin to spare
    // for the widest text state ("Agent Listening").
    private let width: CGFloat = 320
    private let height: CGFloat = 46
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

    func updateAgentMode(_ isAgentMode: Bool) {
        viewModel.isAgentMode = isAgentMode
        if isAgentMode {
            NSLog("Sayline: agent mode flagged for this recording")
        }
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        NSLog("Sayline: indicator hidden")
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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
