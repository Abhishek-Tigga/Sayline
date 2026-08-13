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
    /// 16 × 8, matching Figma node 23:1234 (`padding: 8px 16px`).
    ///
    /// Took a detour to get here: the earlier node said 16 × 10, 10 × 8 was
    /// tried and read as crammed, 12 × 8 was a guess in between, and the
    /// updated node settles it at 16 × 8.
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 8

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
    /// Candidates for the backdrop. `backdrop-filter: blur(8px)` cannot be
    /// asked for directly, so the job is to pick whichever material reads
    /// closest to it. Named so the winner can be identified on sight.
    private static let candidates: [(String, NSVisualEffectView.Material)] = [
        ("hudWindow (previous)", .hudWindow),
        ("popover", .popover),
        ("menu", .menu),
        ("sidebar", .sidebar),
        ("fullScreenUI", .fullScreenUI),
        ("underWindowBackground (SHIPPING)", .underWindowBackground),
    ]

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
                ForEach(Array(Self.candidates.enumerated()), id: \.offset) { _, candidate in
                    HStack(spacing: 12) {
                        Text(candidate.0)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 2)
                            .frame(width: 150, alignment: .trailing)
                        StatusPill(text: "Agent Listening", material: candidate.1)
                            .overlay(GeometryReader { geometry in
                                Text("\(Int(geometry.size.width.rounded()))×\(Int(geometry.size.height.rounded()))")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.black)
                                    .padding(.horizontal, 3)
                                    .background(.yellow)
                                    .offset(x: geometry.size.width + 6, y: 8)
                            })
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
