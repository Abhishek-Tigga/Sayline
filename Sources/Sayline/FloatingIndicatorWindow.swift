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
final class FloatingIndicatorWindow {
    private let panel: NSPanel
    private let viewModel = IndicatorViewModel()

    private let width: CGFloat = 320
    private let height: CGFloat = 190
    private let bottomMargin: CGFloat = 40

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: RecordingIndicatorView(viewModel: viewModel))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
        reposition()
    }

    func show(state: RecordingIndicatorState) {
        viewModel.state = state
        panel.orderFrontRegardless()
        NSLog("Sayline: indicator shown -> \(state)")
    }

    func updateStyle(_ style: DictationStyle) {
        viewModel.style = style
        NSLog("Sayline: indicator style -> \(style.displayName)")
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
        panel.orderOut(nil)
        NSLog("Sayline: indicator hidden")
    }

    private func reposition() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - width / 2
        let y = screenFrame.minY + bottomMargin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
