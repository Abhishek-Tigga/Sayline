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
    var motion: WaveformLoader.Motion = .ringSpin
    var loaderColour: Color = PillStyle.Loader.dictation
    /// Shown for a moment and then crossfaded away, leaving `text`. Used to
    /// announce a mode change without the pill carrying the announcement
    /// for the whole hold.
    var announcement: String? = nil
    var announcedAt: Date = .distantPast
    /// Whether the settled label breathes.
    var breathes: Bool = false

    /// How long the announcement holds at full strength, and how long each
    /// transition into and out of it takes.
    private static let announcementHold = 0.5
    private static let crossfade = 0.45
    /// Peak blur on whichever label is leaving or arriving.
    private static let maxBlur: CGFloat = 3
    /// "Pronounced · Slow" from the breathing-options prototype, and the
    /// same values the pill used before the redesign dropped it.
    private static let breatheCycle = 2.6
    private static let breatheFloor = 0.3
    /// 12 × 8, settled on the rendered pill by the user 2026-08-14.
    ///
    /// Deliberately NOT node 23:1234's `padding: 8px 16px`. Judged on
    /// screen rather than in Figma, which is why it wins over the file, and
    /// it took a while to land: 16 × 10, 10 × 8 (crammed), 12 × 8, 16 × 8,
    /// 14 × 10, 14 × 8, and back to 12 × 8.
    var horizontalPadding: CGFloat = 12
    var verticalPadding: CGFloat = 8

    var body: some View {
        HStack(spacing: Self.gap) {
            WaveformLoader(motion: motion, colour: loaderColour)
            label
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .surfaceBackground(surface, cornerRadius: PillStyle.cornerRadius, material: material)
    }

    /// Both labels live in a ZStack whichever is showing, so the pill's
    /// width is settled from the first frame. Swapping the views instead
    /// would resize the pill mid-crossfade, which is the one moment the
    /// eye is already on it.
    ///
    /// TimelineView rather than `@State` + `withAnimation`: an explicit
    /// transaction here was found live to bleed into the material and fade
    /// the whole pill toward transparent. Anything animating inside this
    /// tree has to be a pure function of the clock.
    private var label: some View {
        TimelineView(.animation) { timeline in
            let now = timeline.date
            let presence = Self.announcementPresence(
                elapsed: now.timeIntervalSince(announcedAt),
                hasAnnouncement: announcement != nil)

            let breathAlpha: Double = {
                guard breathes else { return 1 }
                let t = now.timeIntervalSinceReferenceDate
                let phase = (sin(t * 2 * .pi / Self.breatheCycle) + 1) / 2
                return 1 - phase * (1 - Self.breatheFloor)
            }()

            // One value drives everything, so both directions are the same
            // motion played forwards and backwards rather than two
            // hand-written transitions that can drift apart.
            ZStack(alignment: .leading) {
                if let announcement {
                    text(announcement)
                        .opacity(presence)
                        .blur(radius: Self.maxBlur * (1 - presence))
                }
                text(text)
                    .opacity((1 - presence) * breathAlpha)
                    .blur(radius: Self.maxBlur * presence)
            }
            // The pill hugs: width follows the same value, so it widens as
            // the announcement arrives and shrinks as it leaves. Measured
            // rather than guessed — see `width(of:)`.
            .frame(width: Self.labelWidth(text: text, announcement: announcement,
                                          presence: presence),
                   alignment: .leading)
        }
    }

    private func text(_ string: String) -> some View {
        Text(string)
            .font(Typeface.ui(16))
            .foregroundStyle(PillStyle.foreground)
            .fixedSize()          // never wrap; the pill grows instead
    }

    /// How present the announcement is, 0 to 1.
    ///
    /// Rises as work mode is entered, holds, then falls as it hands back.
    /// Opacity, blur and width are all read off this one number, which is
    /// why the two transitions are guaranteed to match: they are the same
    /// curve, one played in reverse.
    static func announcementPresence(elapsed: Double, hasAnnouncement: Bool) -> Double {
        guard hasAnnouncement, elapsed >= 0 else { return 0 }
        if elapsed < crossfade {
            return smoothstep(elapsed / crossfade)
        }
        let afterHold = elapsed - crossfade - announcementHold
        if afterHold <= 0 { return 1 }
        guard afterHold < crossfade else { return 0 }
        return 1 - smoothstep(afterHold / crossfade)
    }

    private static func smoothstep(_ k: Double) -> Double {
        let x = min(1, max(0, k))
        return x * x * (3 - 2 * x)
    }

    /// Width of the label area at a given presence.
    ///
    /// Measured with the real font rather than left to the layout system.
    /// A ZStack sizes itself to its widest child, so the pill would sit at
    /// the announcement's width for the entire hold and never shrink —
    /// which is the thing being fixed.
    static func labelWidth(text: String, announcement: String?, presence: Double) -> CGFloat {
        let settled = width(of: text)
        guard let announcement else { return settled }
        let announced = width(of: announcement)
        return settled + (announced - settled) * presence
    }

    private static var widthCache: [String: CGFloat] = [:]

    static func width(of string: String) -> CGFloat {
        if let cached = widthCache[string] { return cached }
        let font = NSFont(name: Typeface.familyName, size: 16) ?? .systemFont(ofSize: 16)
        let measured = (string as NSString)
            .size(withAttributes: [.font: font]).width.rounded(.up)
        widthCache[string] = measured
        return measured
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
/// Renders the REAL indicator, not `StatusPill` on its own, so the label
/// logic and the shared surface are exercised too.
private struct PillPreview: View {
    /// Held in @State, created once. Building them inside `body` meant a
    /// fresh view model on every frame — and since entering work mode
    /// stamps the announcement time, the "Work Mode" flash would restart
    /// forever and never hand over to "Listening".
    @State private var plain = IndicatorViewModel()
    @State private var work = PillPreview.workModel()
    @State private var agent = PillPreview.agentModel()

    private static func workModel() -> IndicatorViewModel {
        let m = IndicatorViewModel(); m.isWorkMode = true; return m
    }
    private static func agentModel() -> IndicatorViewModel {
        let m = IndicatorViewModel(); m.isAgentMode = true; return m
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.95), Color(white: 0.04)],
                           startPoint: .leading, endPoint: .trailing)
            VStack(spacing: 22) {
                HStack(spacing: 20) {
                    RecordingIndicatorView(viewModel: plain).frame(height: 44)
                    RecordingIndicatorView(viewModel: work).frame(height: 44)
                    RecordingIndicatorView(viewModel: agent).frame(height: 44)
                }
                Button("Replay the work-mode flash") {
                    work.isWorkMode = false
                    work.isWorkMode = true
                }
            }
            .padding(20)
        }
        .ignoresSafeArea()
    }
}
