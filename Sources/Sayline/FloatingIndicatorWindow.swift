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

    // Wide enough for the widest text state (statusLabelMaxWidth 220pt
    // + logo box + gaps + padding) with margin to spare; height is the
    // 36pt container plus breathing room for the panel's shadow.
    private let width: CGFloat = 320
    private let height: CGFloat = 46
    // Anchored to screen.visibleFrame (Dock/menu-bar aware) rather than
    // raw screen bounds, so the pill never renders behind a visible
    // Dock. Y position can shift slightly between recordings if the
    // Dock auto-hides/reappears in between — expected, not a bug.
    private let bottomMargin: CGFloat = 8

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

    /// Exponential smoothing between ~20ms tap callbacks — raw RMS is
    /// jumpy enough to make the waveform flicker without it.
    func updateAudioLevel(_ level: Float) {
        viewModel.audioLevel = viewModel.audioLevel * 0.55 + level * 0.45
    }

    func updateFocusedAppInfo(_ info: FocusedAppInfo) {
        viewModel.focusedAppInfo = info
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
        panel.level = .floating
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
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - width / 2
        let y = screenFrame.minY + bottomMargin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
