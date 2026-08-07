import SwiftUI

enum RecordingIndicatorState: Equatable {
    case recording
    case transcribing
    case cleaningUp
    case agentRouting
    /// Briefly shown then auto-hidden — surfaces agent answers and
    /// failures (no match, app not found, declined request) that
    /// previously had no visible feedback at all.
    case message(String)
}

/// Which floating-pill design to render — lets the two designs be
/// compared live, side by side in practice (different hotkeys, not
/// simultaneously on screen), without either one's code touching the
/// other's file.
enum PillUIVersion {
    case v3
    case v4
}

final class IndicatorViewModel: ObservableObject {
    @Published var state: RecordingIndicatorState = .recording
    @Published var focusedAppInfo: FocusedAppInfo?
    @Published var isAgentMode: Bool = false
    /// Smoothed live mic loudness (0…1) driving the waveform.
    @Published var audioLevel: Float = 0
    /// Set once, right before a panel is created for a given hold —
    /// read at panel-build time in FloatingIndicatorWindow, not observed
    /// live, since the panel is disposable and rebuilt per show() anyway.
    var uiVersion: PillUIVersion = .v3
}

/// Third UI pass, built against the Figma frame at node 14:100
/// (figma.com/design/fnMh8Ujn4OxhdW9IKNFaH9, pulled 2026-08-06): a Logo
/// Container and a Waveform Container, two elements only — the earlier
/// bot/agent-eyes box is deliberately out of this pass, per explicit
/// direction ("no bot box for now"). Both containers are pure
/// `#000000`, matching the frame exactly (not the `#1F1F1F` from the
/// previous attempt).
///
/// Figma only specifies the *recording* state (the waveform placeholder
/// is explicitly a placeholder — the real content is meant to fill that
/// box edge-to-edge, not sit inset inside extra padding). It has no
/// element at all for Transcribing/Cleaning up/agent messages, so those
/// reuse the Waveform Container's same visual language with text
/// instead of the canvas — a deliberate interpretation to flag, not
/// something pulled from the design file.
struct RecordingIndicatorView: View {
    @ObservedObject var viewModel: IndicatorViewModel

    /// `#0A0A0A` at 80% opacity, layered over a real backdrop-blur
    /// material — this is what actually distinguishes the bar from busy
    /// content behind it (confirmed via a 6-variant HTML comparison)
    /// rather than the shadow-caused edge from the previous pass, which
    /// is now off entirely.
    private static let containerTint = Color(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0A / 255).opacity(0.75)

    /// A blur "of 1" doesn't map to a literal parameter here the way
    /// CSS's `backdrop-filter: blur(1px)` does — AppKit/SwiftUI
    /// materials are fixed-intensity presets (.ultraThinMaterial,
    /// .thinMaterial, …), not a continuous blur-radius dial.
    /// `.ultraThinMaterial` is the subtlest preset available, used here
    /// as the closest approximation — flagged as a real gap pending
    /// live confirmation it reads as intended, not a guess I'm
    /// confident matches "1" exactly.
    private static func materialBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.ultraThinMaterial)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).fill(containerTint))
    }
    private static let textColor = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255)
    // Text states need to fit inside a fixed-size panel — see the
    // crash this caused in the previous attempt (unbounded label width
    // fighting NSHostingView's auto-resize). Capped well under the
    // panel's width with margin to spare.
    private static let statusLabelMaxWidth: CGFloat = 220

    /// "Smooth" from the HTML motion prototype (2026-08-06) — confirmed
    /// live against Springy/Snappy alternatives before porting.
    private static let agentModeAnimation: Animation = .timingCurve(0.65, 0, 0.35, 1, duration: 0.42)

    /// Logo hides and the waveform box takes over its space (88 -> 128,
    /// total pill width unchanged) for the whole agent-mode session, not
    /// just while actively recording — avoids it popping back mid-session
    /// during transcribing/cleaning-up.
    private var hidesLogoContainer: Bool {
        showsWaveform && viewModel.isAgentMode
    }

    var body: some View {
        HStack(spacing: 4) {
            if !hidesLogoContainer {
                logoContainer
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            if showsWaveform {
                waveformContainer
            } else {
                statusContainer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(Self.agentModeAnimation, value: viewModel.isAgentMode)
    }

    /// Transcribing/cleaning-up are typically sub-second — showing a text
    /// swap for them read as flickery/noisy, so they keep the same
    /// waveform box on screen instead (frozen/idle rather than live,
    /// since audio capture has already stopped by then). Only states
    /// with something real to say (agent routing, a message/failure)
    /// still switch to the text container.
    private var showsWaveform: Bool {
        switch viewModel.state {
        case .recording, .transcribing, .cleaningUp: return true
        case .agentRouting, .message: return false
        }
    }

    // MARK: - Logo Container (36×36: nested 4pt + 2pt padding around a 24×24 icon)

    private var logoContainer: some View {
        Color.clear
            .frame(width: 36, height: 36)
            .background(Self.materialBackground(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(logoContent)
    }

    /// Figma builds this as two nested auto-layout paddings — an outer
    /// 4px wrapping an inner 2px wrapping the 24×24 logo — but the inner
    /// wrapper has no background of its own, so it collapses to one
    /// combined 6px offset here with an identical visual result
    /// (figma.com/design/fnMh8Ujn4OxhdW9IKNFaH9, node 20:116, verified
    /// directly after two rounds of mismatched padding values).
    ///
    /// Curated icons (AppIconCatalog) are clean, purpose-built assets —
    /// safe to fit exactly into that slot. The real system-icon
    /// fallback is deliberately *not* clipped to that shape: a genuine
    /// macOS app icon already carries its own baked-in rounded-square
    /// canvas, padding, and shadow, so forcing it into a second,
    /// different rounded-square reintroduces the exact boundary
    /// artifact found and fixed in the previous pass. Shown at its
    /// native shape instead, aspect-fit, so there's nothing left to
    /// clip against.
    @ViewBuilder
    private var logoContent: some View {
        if let curated = AppIconCatalog.icon(forBundleID: viewModel.focusedAppInfo?.bundleID) {
            Image(nsImage: curated)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let icon = viewModel.focusedAppInfo?.icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 24)
        }
    }

    // MARK: - Waveform Container (88×36 normally, 128×36 in agent mode — same
    // 8pt horizontal / 6pt vertical padding either way, so the extra width
    // goes to the canvas itself rather than sitting as empty padding)

    private var waveformContainer: some View {
        let innerWidth: CGFloat = viewModel.isAgentMode ? 112 : 72
        let outerWidth: CGFloat = viewModel.isAgentMode ? 128 : 88
        return ScrollingWaveformCanvas(currentLevel: viewModel.audioLevel, isLive: viewModel.state == .recording)
            .frame(width: innerWidth, height: 24)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(width: outerWidth, height: 36)
            .background(Self.materialBackground(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Agent mode only, and only on this box — not the logo
            // container. BorderBeamKit vendored directly into this target
            // (see BorderBeamKit/LICENSE-BorderBeamKit.txt for why).
            .borderBeam(.sm, colorVariant: .ocean, active: viewModel.isAgentMode, borderRadius: 8)
    }

    // MARK: - Status container (not in Figma — reuses the waveform box's visual language for text states)

    private var statusContainer: some View {
        Text(statusLabel)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(Self.textColor)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Self.statusLabelMaxWidth, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background(Self.materialBackground(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusLabel: String {
        switch viewModel.state {
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .cleaningUp: return "Cleaning up"
        case .agentRouting: return "Agent: thinking"
        case .message(let text): return text
        }
    }
}

/// Real mic-reactive scrolling waveform with a fixed-position playhead —
/// prototyped and tuned as a standalone HTML/Canvas mockup before this
/// port (validated parameters, 2026-08-06). New bars are born at the
/// playhead and pushed left as audio comes in; the playhead itself is
/// drawn fresh every redraw at a fixed screen position, independent of
/// the bar history, which is what makes it read as stationary while the
/// wave scrolls underneath it.
///
/// `levels` lives in `@State` here rather than the shared view model —
/// the floating panel is disposable (rebuilt fresh on every `show()`,
/// see FloatingIndicatorWindow), so a new panel naturally gets fresh
/// `@State`, which resets the waveform history at the start of every
/// new dictation for free without any explicit reset call, while still
/// persisting correctly across state transitions within one dictation
/// (recording → transcribing reuses the same panel).
private struct ScrollingWaveformCanvas: View {
    var currentLevel: Float
    var isLive: Bool

    // Re-tuned specifically at real size (80×30) via the HTML
    // prototype's dedicated "Real-size tuning" section (2026-08-06) —
    // the first pass of these values was tuned against a much larger
    // exploratory canvas and didn't hold up at actual scale.
    private static let barSpacing: CGFloat = 2
    private static let barThickness: CGFloat = 1
    private static let barRoundness: CGFloat = 0.25
    private static let playheadThickness: CGFloat = 1
    private static let maxAmplitudeFraction: CGFloat = 0.75
    private static let idleAmplitudeFraction: CGFloat = 0.10
    private static let emptyDotAmplitudeFraction: CGFloat = 0.10
    /// Sample cadence — how often a new bar is born and the rest shift
    /// left by one spacing-increment. Still a placeholder (not part of
    /// this latest tuning pass) — flagged for live comparison.
    private static let sampleInterval: TimeInterval = 0.06

    private static let waveColor = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255)
    private static let dotColor = Color.white.opacity(0.18)
    private static let playheadColor = Color(red: 0xC9 / 255, green: 0x99 / 255, blue: 0x0A / 255)

    @State private var levels: [Float] = []

    var body: some View {
        Canvas { context, size in
            draw(context: context, size: size)
        }
        .onReceive(Timer.publish(every: Self.sampleInterval, on: .main, in: .common).autoconnect()) { _ in
            sample()
        }
    }

    private func sample() {
        let level: Float = isLive ? max(currentLevel, Float(Self.idleAmplitudeFraction)) : 0
        levels.insert(level, at: 0)
        if levels.count > 60 { levels.removeLast(levels.count - 60) }
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let centerX = size.width / 2
        let centerY = size.height / 2
        // Small margin so the playhead never touches the box's own edges.
        let playheadHalf = max(4, size.height / 2 - 2)
        let barMaxHeight = playheadHalf * Self.maxAmplitudeFraction

        for (i, level) in levels.enumerated() {
            let x = centerX - CGFloat(i) * Self.barSpacing
            if x < 0 { break }
            let barH = min(barMaxHeight, max(1, CGFloat(level) * barMaxHeight))
            let rect = CGRect(x: x - Self.barThickness / 2, y: centerY - barH, width: Self.barThickness, height: barH * 2)
            context.fill(Path(roundedRect: rect, cornerRadius: Self.barRoundness), with: .color(Self.waveColor))
        }

        // Empty-dot region to the right of the playhead — uniform
        // height, no wave pattern (a wave here would misleadingly imply
        // it's showing real data; there's no "future" in a live take).
        let dotH = playheadHalf * Self.emptyDotAmplitudeFraction
        var dotX = centerX + 10
        while dotX < size.width - 2 {
            let rect = CGRect(x: dotX - Self.barThickness / 2, y: centerY - dotH, width: Self.barThickness, height: dotH * 2)
            context.fill(Path(roundedRect: rect, cornerRadius: Self.barRoundness), with: .color(Self.dotColor))
            dotX += Self.barSpacing
        }

        var playheadPath = Path()
        playheadPath.move(to: CGPoint(x: centerX, y: centerY - playheadHalf))
        playheadPath.addLine(to: CGPoint(x: centerX, y: centerY + playheadHalf))
        context.stroke(
            playheadPath,
            with: .color(Self.playheadColor),
            style: StrokeStyle(lineWidth: Self.playheadThickness, lineCap: .round)
        )
    }
}
