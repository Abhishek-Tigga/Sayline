import SwiftUI

/// The small status pill: the waveform loader and a short label.
///
/// Numbers come from `DESIGN-pill-ui.md`, which is the authority rather
/// than the Figma — the rule cards and the drawn frames disagreed in four
/// places and the resolutions there are decisions, not transcription.
///
/// Named `StatusPill` rather than `PillView` because the shipping
/// indicator already has a `PillView`. This is the standalone preview of
/// the replacement, deliberately self-contained so looking at it cannot
/// destabilise the indicator that currently works.
///
/// Used by the live indicator as well as the preview window, so the thing
/// being reviewed and the thing that ships cannot diverge.
struct StatusPill: View {
    var text: String
    /// Defaults to what ships, so the preview needs no argument and the
    /// indicator can still pass the parked glass style through.
    var surface: SurfaceStyle = .shipping
    /// 12 × 8, against the Figma's 16 × 10. The user tried 10 × 8 first
    /// and called it crammed, so horizontal came back up to 12; vertical
    /// stays at 8. Both settled by eye on the rendered pill, 2026-08-14.
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.gap) {
            WaveformLoader()
            Text(text)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(PillStyle.foreground)
                .fixedSize()          // never wrap; the pill grows instead
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .surfaceBackground(surface, cornerRadius: PillStyle.cornerRadius)
    }

    // MARK: - The shared surface

    /// Fill, blur, stroke and shadow all come from
    /// `surfaceBackground(_:cornerRadius:)` rather than being repeated
    /// here. That function's own comment says it exists "so the pill and
    /// the speech box can't drift apart", and drifting apart on exactly
    /// these values is what had to be resolved out of the Figma.
    static let gap: CGFloat = 8

}

/// A window that shows the pill on its own, for judging the visuals before
/// any of it is wired into the live indicator.
///
/// Reached with `--preview-pill`, so it costs a normal launch nothing. It
/// is scaffolding: delete it once the pill is wired in for real.
final class PillPreviewWindowController {
    private var window: NSWindow?

    func show() {
        let hosting = NSHostingView(rootView: PillPreview())
        // Sized here rather than negotiated: an NSHostingView that argues
        // with a fixed window over size extrema is what crashed Settings
        // on 2026-08-12.
        hosting.sizingOptions = []
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 300)

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Pill preview"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

/// Renders the REAL indicator, not `StatusPill` on its own.
///
/// Showing the pill directly would prove only that the pill draws; it
/// would not exercise `PillView`'s label logic or the shared
/// `surfaceBackground`, which are the parts that were just rewired. This
/// goes through the same view the floating window uses.
private struct PillPreview: View {
    var body: some View {
        ZStack {
            // Something for the blur and the faint stroke to sit against —
            // both are invisible on a flat backdrop, and a preview that
            // hides them is not showing the design.
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            HStack(spacing: 22) {
                indicator(mode: "plain")
                indicator(mode: "work")
                indicator(mode: "agent")
            }
        }
        .ignoresSafeArea()
    }

    private func indicator(mode: String) -> some View {
        let viewModel = IndicatorViewModel()
        viewModel.isAgentMode = (mode == "agent")
        viewModel.isWorkMode = (mode == "work")
        return RecordingIndicatorView(viewModel: viewModel)
            .frame(height: 60)
    }
}
