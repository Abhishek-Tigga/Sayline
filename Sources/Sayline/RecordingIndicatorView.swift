import AppKit
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

final class IndicatorViewModel: ObservableObject {
    @Published var state: RecordingIndicatorState = .recording
    @Published var isAgentMode: Bool = false
    /// What the user said, shown in the speech-back box above the pill.
    /// Only set in agent mode, and only once transcription returns — we
    /// have no words before then (Groq Whisper is batch, not streaming).
    @Published var transcript: String?
    /// Anchor for the word-by-word reveal. Held here rather than in
    /// @State so every stack in the opacity comparison animates in
    /// lockstep from the same instant.
    @Published var transcriptSetAt: Date = .distantPast

    func setTranscript(_ text: String?) {
        transcript = text
        transcriptSetAt = Date()
    }
}

// MARK: - Shared visual constants

enum PillStyle {
    /// #F2F2F2 — hsl(0, 0%, 95%), a pure neutral (no hue/saturation).
    static let foreground = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255)
    /// True black. Opacity is applied per-instance so the comparison
    /// harness can render several at once.
    static let tintBase = Color(red: 0, green: 0, blue: 0)
    static let defaultTintOpacity: Double = 0.70
    static let cornerRadius: CGFloat = 8
}

/// TEMPORARY — exists only on the `ui-speech-back` branch, to judge pill
/// opacity against real backdrops in one pass instead of rebuilding once
/// per value (each rebuild also costs a re-grant of Accessibility, so
/// serial comparison was expensive and relied on memory between builds).
///
/// Set to `nil` for normal single-pill rendering.
enum OpacityComparison {
    static let values: [Double]? = [1.0, 0.9, 0.8, 0.7]
}

// MARK: - Top level

/// The floating overlay: in agent mode a speech-back box showing what was
/// said, four linear processing dots, then the status pill. In plain
/// dictation just the pill.
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
/// material instead of the real API, a dark-outlined dual-tone text/icon
/// treatment — were all tried and reverted; none were acceptable. The
/// adaptivity isn't a side effect layered on top of the glass look, it
/// IS the glass look. Explicit call (2026-08-07): keep the real glass,
/// flicker included, rather than any of the workarounds. Note the speech
/// box inherits this, and on a surface that size it reads louder than it
/// does on the pill.
///
/// Every visual value here was validated in a standalone HTML prototype
/// first (see scratchpad `speechback/`), which caught three real bugs
/// before any Swift was written — including a max-width that could never
/// apply because the parent shrank to fit its widest child, a trap that
/// exists in SwiftUI layout too.
struct RecordingIndicatorView: View {
    @ObservedObject var viewModel: IndicatorViewModel

    var body: some View {
        Group {
            if let values = OpacityComparison.values {
                HStack(alignment: .bottom, spacing: 20) {
                    ForEach(values, id: \.self) { value in
                        IndicatorStack(
                            viewModel: viewModel,
                            tintOpacity: value,
                            label: "\(Int(value * 100))"
                        )
                    }
                }
            } else {
                IndicatorStack(
                    viewModel: viewModel,
                    tintOpacity: PillStyle.defaultTintOpacity,
                    label: nil
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// One complete assembly: speech box, connector dots, pill. Figma spaces
/// these 8px apart (node 70:95 and siblings).
private struct IndicatorStack: View {
    @ObservedObject var viewModel: IndicatorViewModel
    let tintOpacity: Double
    let label: String?

    var body: some View {
        VStack(spacing: 8) {
            if let transcript = viewModel.transcript, !transcript.isEmpty {
                SpeechBackBox(
                    text: transcript,
                    setAt: viewModel.transcriptSetAt,
                    tintOpacity: tintOpacity
                )
                LinearProcessingDots()
            }

            PillView(viewModel: viewModel, tintOpacity: tintOpacity)

            if let label {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PillStyle.foreground.opacity(0.55))
            }
        }
    }
}

// MARK: - Speech-back box

/// Shows the transcript above the pill. Sized to the finished text before
/// any word appears — revealing into a box that is still growing makes it
/// reflow on every word, which reads as jitter.
private struct SpeechBackBox: View {
    let text: String
    let setAt: Date
    let tintOpacity: Double

    static let maxWidth: CGFloat = 324
    static let fontSize: CGFloat = 12
    static let lineHeight: CGFloat = 15
    /// The largest Figma variant ("many line") is ~13 lines. Past that the
    /// box stops growing and the text is trimmed from the front, keeping
    /// the end — the tail is usually the actual instruction.
    static let maxLines = 13
    /// Whole reveal lands in ~0.4s regardless of length. Word by word, not
    /// letter by letter: letters read as a fake typewriter and drag, words
    /// read as a thought forming and are far fewer animation steps.
    static let revealDuration: TimeInterval = 0.4
    static let perWordFade: TimeInterval = 0.26

    var body: some View {
        let fitted = Self.fit(text)
        let metrics = Self.metrics(for: fitted)

        TimelineView(.animation) { timeline in
            Text(Self.attributed(fitted, elapsed: timeline.date.timeIntervalSince(setAt)))
                .font(.system(size: Self.fontSize))
                .lineSpacing(Self.lineHeight - Self.fontSize - 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: Self.maxWidth - metrics.horizontalPadding * 2, alignment: .leading)
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.vertical, metrics.verticalPadding)
                .glassBackground(cornerRadius: metrics.cornerRadius, tintOpacity: tintOpacity)
        }
    }

    /// Per-word alpha computed from wall-clock time rather than
    /// `withAnimation`. Deliberate: an explicit animation transaction in
    /// this part of the tree was found live to bleed into the Liquid Glass
    /// material itself, fading the whole surface toward transparent.
    /// Computing from elapsed time creates no transaction to propagate.
    private static func attributed(_ text: String, elapsed: TimeInterval) -> AttributedString {
        let words = text.split(separator: " ", omittingEmptySubsequences: false)
        let step = words.isEmpty ? 0 : min(0.034, revealDuration / Double(words.count))
        var result = AttributedString()
        for (index, word) in words.enumerated() {
            let start = Double(index) * step
            let progress = max(0, min(1, (elapsed - start) / perWordFade))
            // ease-out, matching the prototype's cubic-bezier feel
            let eased = 1 - pow(1 - progress, 3)
            var run = AttributedString(word + (index < words.count - 1 ? " " : ""))
            run.foregroundColor = PillStyle.foreground.opacity(eased)
            result += run
        }
        return result
    }

    // MARK: Sizing

    private struct Metrics {
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let cornerRadius: CGFloat
    }

    /// Padding scales with the box so the corner radius stays visually
    /// proportional — deliberate in the Figma variants, not drift.
    private static func metrics(for text: String) -> Metrics {
        switch resolvedLineCount(text) {
        case 1:      return Metrics(horizontalPadding: 12, verticalPadding: 8, cornerRadius: 12)
        case 2...3:  return Metrics(horizontalPadding: 16, verticalPadding: 12, cornerRadius: 14)
        case 4...7:  return Metrics(horizontalPadding: 16, verticalPadding: 12, cornerRadius: 16)
        default:     return Metrics(horizontalPadding: 20, verticalPadding: 16, cornerRadius: 18)
        }
    }

    /// Padding changes the width available, which can change the line
    /// count, which can change the padding. Two passes settles it.
    private static func resolvedLineCount(_ text: String) -> Int {
        let first = lineCount(text, horizontalPadding: 16)
        let padding: CGFloat = first == 1 ? 12 : (first >= 8 ? 20 : 16)
        return lineCount(text, horizontalPadding: padding)
    }

    private static func lineCount(_ text: String, horizontalPadding: CGFloat) -> Int {
        let available = maxWidth - horizontalPadding * 2
        let attributed = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: fontSize)]
        )
        let bounds = attributed.boundingRect(
            with: CGSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return max(1, Int((bounds.height / lineHeight).rounded()))
    }

    private static func fit(_ text: String) -> String {
        guard resolvedLineCount(text) > maxLines else { return text }
        var words = text.split(separator: " ").map(String.init)
        while words.count > 4 {
            words.removeFirst()
            let candidate = "… " + words.joined(separator: " ")
            if resolvedLineCount(candidate) <= maxLines { return candidate }
        }
        return "… " + words.joined(separator: " ")
    }
}

// MARK: - Linear processing dots

/// The same sequential-dim idea as the pill's four-dot glyph, laid out in
/// a row instead of a square (Figma "Processing Cubes", node 70:99): four
/// 4x4 squares, 4px apart, 28px total.
private struct LinearProcessingDots: View {
    private static let dotSize: CGFloat = 4
    private static let gap: CGFloat = 4
    private static let cycle: TimeInterval = 1.25
    private static let dimOpacity: Double = 0.28

    var body: some View {
        // Driven from wall-clock time for the same reason as the text
        // reveal — no animation transaction to leak into the glass.
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: Self.gap) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(PillStyle.foreground)
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .opacity(Self.opacity(at: t, index: index))
                }
            }
        }
        .frame(height: Self.dotSize)
    }

    /// A brightness wave running left to right. Smooth (cosine) rather
    /// than stepped — a stepped variant read as stuttery in the prototype.
    private static func opacity(at time: TimeInterval, index: Int) -> Double {
        let stagger = 0.14 * Double(index)
        let phase = ((time - stagger).truncatingRemainder(dividingBy: cycle)) / cycle
        guard phase < 0.32 else { return dimOpacity }
        let bump = (1 - cos(phase / 0.32 * 2 * .pi)) / 2 // 0 -> 1 -> 0
        return dimOpacity + (1 - dimOpacity) * bump
    }
}

// MARK: - Pill

private struct PillView: View {
    @ObservedObject var viewModel: IndicatorViewModel
    let tintOpacity: Double

    /// Figma's nested 8/2.5 outer + 4 inner padding collapses to one
    /// combined value (no intermediate background between the two).
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 6.5
    /// "Pronounced · Slow" from the breathing-options prototype.
    private static let breatheCycleSeconds: Double = 2.6
    private static let breatheFloor: Double = 0.3

    var body: some View {
        content
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .glassBackground(cornerRadius: PillStyle.cornerRadius, tintOpacity: tintOpacity)
            // BorderBeamKit on both modes: agent gets .sm/.ocean at full
            // strength; plain dictation uses the pulse family's inward
            // variant (.pulseInner, not .pulseOutside — the outward bloom
            // read badly) at .mono/40%, so the two states stay distinct.
            .borderBeam(
                viewModel.isAgentMode ? .sm : .pulseInner,
                colorVariant: viewModel.isAgentMode ? .ocean : .mono,
                active: true,
                borderRadius: Double(PillStyle.cornerRadius),
                strength: viewModel.isAgentMode ? 1.0 : 0.4
            )
    }

    /// TimelineView rather than `@State` + `withAnimation` on purpose: an
    /// explicit transaction here was found live to bleed into the Liquid
    /// Glass material, fading the whole pill toward transparent. Glass
    /// reacts to any animation passing through its part of the tree, not
    /// just properties it is bound to.
    private var content: some View {
        HStack(spacing: 6) {
            ProcessingDotsIcon(rotated: viewModel.isAgentMode)
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = (sin(t * 2 * .pi / Self.breatheCycleSeconds) + 1) / 2
                let opacity = 1.0 - phase * (1.0 - Self.breatheFloor)
                Text(viewModel.isAgentMode ? "Agent Listening" : "Listening")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(PillStyle.foreground)
                    .opacity(opacity)
            }
        }
    }
}

// MARK: - Glass

private extension View {
    /// One place for the container treatment so the pill and the speech
    /// box can't drift apart, and so the comparison harness only has to
    /// vary a single number.
    @ViewBuilder
    func glassBackground(cornerRadius: CGFloat, tintOpacity: Double) -> some View {
        let tint = PillStyle.tintBase.opacity(tintOpacity)
        if #available(macOS 26.0, *) {
            self.glassEffect(
                Glass.regular.tint(tint),
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
        } else {
            // Pre-macOS 26 fallback — real Liquid Glass isn't reachable.
            self.background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius).fill(tint))
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// Four static dots, one of which dips to near-invisible at a time,
/// cycling clockwise (top-left -> top-right -> bottom-right ->
/// bottom-left) — confirmed order after an earlier HTML prototype got it
/// wrong (CSS grid auto-placement fills row-by-row, not the corner order
/// its own code comment claimed). Built with explicit VStack/HStack
/// nesting instead of a grid specifically to avoid that same class of
/// auto-placement ambiguity.
private struct ProcessingDotsIcon: View {
    var rotated: Bool

    private static let dotSize: CGFloat = 4
    private static let gap: CGFloat = 2
    private static let stepInterval: TimeInterval = 0.2 // 800ms loop / 4 steps
    private static let dimOpacity: Double = 0.06

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
            .fill(PillStyle.foreground)
            .frame(width: Self.dotSize, height: Self.dotSize)
            .opacity(dimIndex == index ? Self.dimOpacity : 1.0)
    }
}
