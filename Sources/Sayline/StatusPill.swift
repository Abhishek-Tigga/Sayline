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
    /// Only varied by the blur comparison in `--preview-pill`. The blur
    /// radius is not settable on NSVisualEffectView, so the material is
    /// chosen by eye instead — see `BackdropBlur`.
    var material: NSVisualEffectView.Material = .underWindowBackground
    /// 14 × 10, settled on the rendered pill by the user 2026-08-14.
    ///
    /// Deliberately NOT node 23:1234's `padding: 8px 16px`. The route here
    /// was 16 × 10 (first node), 10 × 8 (crammed), 12 × 8, 16 × 8 (second
    /// node), and finally 14 × 10 — judged on screen rather than in Figma,
    /// which is why it wins over the file.
    var horizontalPadding: CGFloat = 14
    var verticalPadding: CGFloat = 10

    var body: some View {
        HStack(spacing: Self.gap) {
            WaveformLoader()
            Text(text)
                .font(Typeface.ui(16))
                .foregroundStyle(PillStyle.foreground)
                .fixedSize()          // never wrap; the pill grows instead
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .surfaceBackground(surface, cornerRadius: PillStyle.cornerRadius, material: material)
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
        hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 420)

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
/// Renders the REAL indicator plus the blur-material comparison.
///
/// Showing `StatusPill` alone would prove only that the pill draws; this
/// goes through the same view the floating window uses.
private struct PillPreview: View {
    /// Fill opacities to choose between.
    ///
    /// The material is settled; this is the remaining lever on how much
    /// blurred backdrop shows. Figma asks for a 16 background blur (which
    /// it exports as `blur(8px)` — Figma writes CSS at half its own
    /// value), and NSVisualEffectView has no radius to set, so "less
    /// blur" has to be bought by letting less of the backdrop through the
    /// fill. 0.75 is the spec.
    private static let fills: [Double] = [0.75, 0.82, 0.88, 0.94, 1.0]

    private static func surface(_ opacity: Double) -> SurfaceStyle {
        .flat(fill: Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255)
            .opacity(opacity))
    }

    var body: some View {
        ZStack {
            // Near-white to near-black on purpose: a blurred backdrop and a
            // darkening shadow both have to be judged at each end.
            LinearGradient(colors: [Color(white: 0.95), Color(white: 0.04)],
                           startPoint: .leading, endPoint: .trailing)
            VStack(spacing: 18) {
                HStack(spacing: 20) {
                    RecordingIndicatorView(viewModel: model(agent: false, work: false))
                        .frame(height: 40)
                    RecordingIndicatorView(viewModel: model(agent: false, work: true))
                        .frame(height: 40)
                    RecordingIndicatorView(viewModel: model(agent: true, work: false))
                        .frame(height: 40)
                }
                Divider().opacity(0.4)
                ForEach(Array(Self.fills.enumerated()), id: \.offset) { _, opacity in
                    HStack(spacing: 12) {
                        Text(opacity == 0.75 ? "75% (spec)"
                             : opacity == 1.0 ? "100% (opaque)"
                             : "\(Int(opacity * 100))%")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 2)
                            .frame(width: 110, alignment: .trailing)
                        StatusPill(text: "Agent Listening", surface: Self.surface(opacity))
                    }
                }
            }
            .padding(20)
        }
        .ignoresSafeArea()
    }

    private func model(agent: Bool, work: Bool) -> IndicatorViewModel {
        let viewModel = IndicatorViewModel()
        viewModel.isAgentMode = agent
        viewModel.isWorkMode = work
        return viewModel
    }
}
