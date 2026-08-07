import SwiftUI

/// Fourth UI pass — a single small "chip" pill (Figma node 36:656/657/688,
/// fnMh8Ujn4OxhdW9IKNFaH9), built to compare live against v3 rather than
/// replace it outright: v3 stays on RIGHT OPTION, this lives on RIGHT
/// COMMAND (see HotkeyManager's secondaryHotkeyOption). No waveform, no
/// app-icon logo box — just a four-dot processing glyph plus a status
/// word ("Listening" / "Agent Listening").
///
/// Container: real macOS 26 Liquid Glass (`.glassEffect()`), falling
/// back to `.ultraThinMaterial` + tint below macOS 26.
///
/// KNOWN OPEN ISSUE, deliberately left as-is for now: real Liquid Glass
/// is backdrop-adaptive — over bright content it animates itself toward
/// a lighter rendering (confirmed live, frame by frame, from a screen
/// recording: a smooth ~1.3s fade, reproducible only over light
/// backgrounds, not dark ones). Several attempts to suppress this while
/// keeping the real API — tinting the glass directly, an opaque overlay
/// in front of it, a lighter overlay, a hand-approximated non-adaptive
/// material instead of the real API — were all tried and reverted; none
/// were acceptable. The adaptivity isn't a side effect layered on top of
/// the glass look, it IS the glass look, so it doesn't cleanly separate
/// from "looks like glass" while still calling the real API. Explicit
/// call (2026-08-07): keep the real glass, flicker included, rather than
/// any of the workarounds — needs a real solution, not a patch, revisit
/// before this ships.
///
/// Every visual value here was validated in a standalone HTML/Canvas
/// prototype first (glass vs. material comparison, 8 dot-animation
/// variants, 3 text-breathing options) before porting, same practice as
/// v3's waveform.
struct RecordingIndicatorViewV4: View {
    @ObservedObject var viewModel: IndicatorViewModel

    /// #F2F2F2 — confirmed as hsl(0, 0%, 95%), a pure neutral (no hue/
    /// saturation), matching v3's own textColor/waveColor exactly, not a
    /// new value invented for this pass.
    private static let dotAndTextColor = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255)
    /// True black at 70% opacity — last value confirmed against the
    /// real glass path before the workaround detour (see the KNOWN OPEN
    /// ISSUE note above).
    private static let fillTint = Color(red: 0, green: 0, blue: 0).opacity(0.70)
    private static let cornerRadius: CGFloat = 8

    /// Figma's nested 8/2.5 outer + 4 inner padding collapses to one
    /// combined value the same way v3's logo container padding did (no
    /// intermediate background between the two, so nothing is lost).
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 6.5

    /// "Pronounced · Slow" from the breathing-options prototype: floor
    /// 0.3 opacity, full 2.6s breath cycle.
    private static let breatheCycleSeconds: Double = 2.6
    private static let breatheFloor: Double = 0.3

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                pillContent
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.vertical, Self.verticalPadding)
                    .glassEffect(
                        Glass.regular.tint(Self.fillTint),
                        in: RoundedRectangle(cornerRadius: Self.cornerRadius)
                    )
            } else {
                // Pre-macOS 26 fallback: same treatment already shipped
                // in v3 (.ultraThinMaterial + tinted overlay) — real
                // Liquid Glass isn't reachable below macOS 26.
                pillContent
                    .padding(.horizontal, Self.horizontalPadding)
                    .padding(.vertical, Self.verticalPadding)
                    .background(
                        RoundedRectangle(cornerRadius: Self.cornerRadius)
                            .fill(.ultraThinMaterial)
                            .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).fill(Self.fillTint))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
            }
        }
        // BorderBeamKit on both modes now, not just agent — agent keeps
        // the existing .sm/.ocean/full-strength rotate beam; plain
        // dictation uses the pulse family's inward variant (.pulseInner,
        // not .pulseOutside) at .mono/40% strength — inward specifically
        // because the outward bloom from .pulseOutside was the thing
        // that prompted this change (an inner-glow HTML prototype was
        // explored first, but .pulseInner already does this natively).
        .borderBeam(
            viewModel.isAgentMode ? .sm : .pulseInner,
            colorVariant: viewModel.isAgentMode ? .ocean : .mono,
            active: true,
            borderRadius: Double(Self.cornerRadius),
            strength: viewModel.isAgentMode ? 1.0 : 0.4
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    /// Driven by TimelineView rather than `@State` + `withAnimation`
    /// on purpose: an explicit `withAnimation` transaction here was
    /// found live to bleed into the real Liquid Glass material's own
    /// rendering, causing the whole pill (not just the text) to fade
    /// toward fully transparent over the animation's duration — Glass
    /// appears to react to any animation transaction passing through
    /// its part of the tree, not just properties it's directly bound
    /// to. Computing opacity per-frame from wall-clock time instead
    /// creates no animation transaction at all, so nothing propagates.
    private var pillContent: some View {
        HStack(spacing: 6) {
            ProcessingDotsIconV4(rotated: viewModel.isAgentMode)
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = (sin(t * 2 * .pi / Self.breatheCycleSeconds) + 1) / 2 // 0...1
                let opacity = 1.0 - phase * (1.0 - Self.breatheFloor)
                Text(label)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Self.dotAndTextColor)
                    .opacity(opacity)
            }
        }
    }

    private var label: String {
        viewModel.isAgentMode ? "Agent Listening" : "Listening"
    }
}

/// Four static dots, one of which dips to near-invisible at a time,
/// cycling clockwise (top-left -> top-right -> bottom-right ->
/// bottom-left) — confirmed order after an earlier HTML prototype got it
/// wrong (CSS grid auto-placement fills row-by-row, not the corner order
/// its own code comment claimed). Built here with explicit VStack/HStack
/// nesting instead of a grid specifically to avoid that same class of
/// auto-placement ambiguity — SwiftUI stacks lay out children in
/// exactly the order written, no auto-placement to get wrong.
private struct ProcessingDotsIconV4: View {
    var rotated: Bool

    private static let dotSize: CGFloat = 4
    private static let gap: CGFloat = 2
    private static let stepInterval: TimeInterval = 0.2 // 800ms loop / 4 steps
    private static let dimOpacity: Double = 0.06
    private static let color = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255)

    /// 0 = top-left, 1 = top-right, 2 = bottom-right, 3 = bottom-left.
    @State private var dimIndex = 0

    var body: some View {
        VStack(spacing: Self.gap) {
            HStack(spacing: Self.gap) {
                dot(0) // top-left
                dot(1) // top-right
            }
            HStack(spacing: Self.gap) {
                dot(3) // bottom-left
                dot(2) // bottom-right
            }
        }
        .frame(width: 12, height: 12)
        .rotationEffect(.degrees(rotated ? 45 : 0))
        .onReceive(Timer.publish(every: Self.stepInterval, on: .main, in: .common).autoconnect()) { _ in
            dimIndex = (dimIndex + 1) % 4
        }
    }

    private func dot(_ index: Int) -> some View {
        Circle()
            .fill(Self.color)
            .frame(width: Self.dotSize, height: Self.dotSize)
            .opacity(dimIndex == index ? Self.dimOpacity : 1.0)
    }
}
