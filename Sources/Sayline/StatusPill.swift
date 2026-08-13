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
/// **When this is wired in, fold the surface into
/// `surfaceBackground(_:cornerRadius:)` in `RecordingIndicatorView.swift`
/// rather than keeping both.** That function already carries the same
/// fill — `SurfaceStyle.shipping` is `.flat(#141414 @ 75%)` — and its own
/// comment says it exists "so the pill and the speech box can't drift
/// apart". Two surfaces drifting apart is precisely the bug that had to be
/// resolved out of the Figma, and it would be careless to recreate it in
/// code. It needs the stroke and drop shadow added, which it currently
/// lacks.
struct StatusPill: View {
    var text: String
    /// 10 × 8, changed from the Figma's 16 × 10 by the user 2026-08-14.
    var horizontalPadding: CGFloat = 10
    var verticalPadding: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.gap) {
            WaveformLoader()
            Text(text)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Self.label)
                .fixedSize()          // never wrap; the pill grows instead
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(Self.surface)
    }

    // MARK: - The shared surface
    //
    // Fill, stroke, blur and shadow are identical on the pill and the
    // speech box — the user's call when the rule card and the drawn frames
    // disagreed. Kept as one view so the two cannot drift apart again,
    // which is exactly what had happened in the Figma.
    static let gap: CGFloat = 6
    static let label = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255)

    @ViewBuilder
    static func surfaceShape(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255).opacity(0.75))
            .background(.ultraThinMaterial.opacity(0.0), in: shape)
            .overlay(
                shape.strokeBorder(
                    Color(red: 0x66 / 255, green: 0x66 / 255, blue: 0x66 / 255).opacity(0.25),
                    lineWidth: 1)
            )
            .shadow(color: Color(red: 0x61 / 255, green: 0x61 / 255, blue: 0x61 / 255).opacity(0.25),
                    radius: 2, x: 0, y: 1)
    }

    private static var surface: some View {
        surfaceShape(radius: 8)
    }
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

private struct PillPreview: View {
    var body: some View {
        ZStack {
            // Something for the blur and the faint stroke to sit against —
            // both are invisible on a flat backdrop, and a preview that
            // hides them is not showing the design.
            LinearGradient(colors: [Color(white: 0.32), Color(white: 0.06)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 26) {
                StatusPill(text: "Agent Listening")
                StatusPill(text: "Listening")
                HStack(spacing: 18) {
                    WaveformLoader(size: 15)
                    WaveformLoader(size: 30)
                    WaveformLoader(size: 60)
                }
            }
        }
        .ignoresSafeArea()
    }
}
