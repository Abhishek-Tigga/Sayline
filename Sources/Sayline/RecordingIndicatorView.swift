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
    /// Work mode gets its own label and accent, set the instant the
    /// double-tap registers rather than when the text arrives.
    @Published var isWorkMode: Bool = false
    /// What the user said, shown in the speech-back box above the pill.
    /// Only set in agent mode, and only once transcription returns — we
    /// have no words before then (Groq Whisper is batch, not streaming).
    @Published var transcript: String?
    /// Anchor for the word-by-word reveal. Held here rather than in
    /// @State so every stack in the opacity comparison animates in
    /// lockstep from the same instant.
    @Published var transcriptSetAt: Date = .distantPast

    /// The question currently on screen, if any. See FollowUp.swift.
    @Published var followUp: FollowUpRequest?
    /// Something Sayline is telling the user, in the same box a question
    /// would use. Not a question — nothing to answer, no countdown.
    @Published var notice: (text: String, detail: String?)?
    /// Anchor for the draining countdown line, same wall-clock approach as
    /// the dots and the text reveal.
    @Published var followUpStartedAt: Date = .distantPast
    /// Called by the buttons. The window owns the single-fire guard and the
    /// timeout, so the view can stay a plain function of state.
    var onFollowUpAnswer: ((FollowUpAnswer) -> Void)?
    /// The one-time calendar setup card, shown under the answer.
    @Published var setupCard: CalendarSetupCard?
    var onSetupAction: ((CalendarSetupAction) -> Void)?
    /// Returns false when the change was refused — deselecting the last
    /// account, which is always a slip.
    var onAccountToggle: ((String, Bool) -> Bool)?
    @Published var accountRefusal: String?
    /// The configured hotkey, for the "hold ⌥ and say…" hint.
    @Published var hotkeySymbol: String = "⌥" 

    func setTranscript(_ text: String?) {
        transcript = text
        transcriptSetAt = Date()
    }

    func setFollowUp(_ request: FollowUpRequest?) {
        followUp = request
        followUpStartedAt = Date()
    }

    func setNotice(_ text: String?, detail: String? = nil) {
        notice = text.map { ($0, detail) }
    }
}

// MARK: - Shared visual constants

enum PillStyle {
    /// #F2F2F2 — hsl(0, 0%, 95%), a pure neutral (no hue/saturation).
    static let foreground = Color(red: 0xF2 / 255, green: 0xF2 / 255, blue: 0xF2 / 255)
    /// True black. Opacity is applied per-instance so the comparison
    /// harness can render both surfaces at once.
    static let tintBase = Color(red: 0, green: 0, blue: 0)
    static let defaultTintOpacity: Double = 0.70
    static let cornerRadius: CGFloat = 8
}

/// The container treatment.
///
/// `.flat` ships. `.liquidGlass` is PARKED, not dead — kept compiling and
/// one constant away from returning, on the explicit instruction not to
/// delete it (2026-08-10).
///
/// They were never two tints of the same thing. `.liquidGlass` is the real
/// macOS 26 material, which re-renders itself brighter over light content;
/// that adaptivity is the whole look and also the source of the known
/// flicker, and it reads far louder on a surface the size of the speech
/// box than it ever did on the pill. `.flat` is an ordinary blurred
/// backdrop under a fixed fill, so it cannot adapt and does not flicker —
/// which is what a box holding a question the user has to read needs.
enum SurfaceStyle: Equatable {
    /// PARKED. Real Liquid Glass with a tint over it, true black at 70%.
    case liquidGlass(tint: Color)
    /// Figma node 91:778 — `bg-[rgba(20,20,20,0.75)]` over
    /// `backdrop-blur`. Flat and non-adaptive.
    case flat(fill: Color)

    /// What renders. Swap to `parkedGlass` to bring the old look back.
    static let shipping = SurfaceStyle.flat(
        fill: Color(red: 0x14 / 255, green: 0x14 / 255, blue: 0x14 / 255).opacity(0.75)
    )
    /// PARKED — the previous shipping look, kept for a one-line revert.
    static let parkedGlass = SurfaceStyle.liquidGlass(
        tint: PillStyle.tintBase.opacity(PillStyle.defaultTintOpacity)
    )
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
        IndicatorStack(viewModel: viewModel, surface: .shipping, label: nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// One complete assembly: speech box, connector dots, pill — spaced 8px
/// apart per Figma (node 70:95 and siblings). Both surfaces in a stack
/// share one style, so the comparison is like for like.
private struct IndicatorStack: View {
    @ObservedObject var viewModel: IndicatorViewModel
    let surface: SurfaceStyle
    let label: String?

    var body: some View {
        // Explicitly centred: the box and the pill share one vertical axis
        // and sit symmetrically one above the other, rather than both
        // hanging off a left edge.
        VStack(alignment: .center, spacing: 8) {
            if let followUp = viewModel.followUp {
                FollowUpBox(
                    request: followUp,
                    startedAt: viewModel.followUpStartedAt,
                    surface: surface,
                    onAnswer: { viewModel.onFollowUpAnswer?($0) },
                    hotkeySymbol: viewModel.hotkeySymbol
                )
                LinearProcessingDots()
            } else if let notice = viewModel.notice {
                NoticeBox(text: notice.text, detail: notice.detail, surface: surface)
                LinearProcessingDots()
            } else if viewModel.setupCard == nil, let transcript = viewModel.transcript, !transcript.isEmpty {
                SpeechBackBox(
                    text: transcript,
                    setAt: viewModel.transcriptSetAt,
                    surface: surface
                )
                LinearProcessingDots()
            }
            // Below the answer and above the pill, so the answer stays the
            // thing being read and this is the footnote to it.
            if let card = viewModel.setupCard {
                SetupBox(
                    card: card, surface: surface,
                    onAction: { viewModel.onSetupAction?($0) },
                    onToggle: { id, on in
                        if viewModel.onAccountToggle?(id, on) == false {
                            viewModel.accountRefusal = "Keep at least one account on"
                        } else {
                            viewModel.accountRefusal = nil
                        }
                    },
                    refusal: viewModel.accountRefusal
                )
            }
            PillView(viewModel: viewModel, surface: surface)
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
    let surface: SurfaceStyle

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
                .surfaceBackground(surface, cornerRadius: metrics.cornerRadius)
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

// MARK: - Notice

/// Sayline saying something, in the box a question would have used.
///
/// Shares FollowUpBox's geometry and marker on purpose: the box means
/// "this is Sayline talking" whether it wants an answer or not, and a
/// result arriving in a different-looking surface than the question that
/// produced it would read as a different thing happening.
///
/// Deliberately plain for now — no countdown, nothing to press. A proper
/// result surface is still to be designed.
private struct NoticeBox: View {
    let text: String
    let detail: String?
    let surface: SurfaceStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SaylineMarker()
            Text(text)
                .font(.system(size: SpeechBackBox.fontSize, weight: .semibold))
                .foregroundStyle(PillStyle.foreground)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.system(size: SpeechBackBox.fontSize))
                    .foregroundStyle(PillStyle.foreground)
                    .opacity(0.75)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: 324 - 32, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .surfaceBackground(surface, cornerRadius: 14)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Marks a box as Sayline speaking rather than the user's own words read
/// back. Shared so a notice and a question are unmistakably the same voice.
private struct SaylineMarker: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(PillStyle.foreground)
                .frame(width: 4, height: 4)
            Text("SAYLINE")
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(PillStyle.foreground)
        }
        .opacity(0.5)
        .padding(.bottom, 6)
    }
}

// MARK: - Calendar setup

/// The one-time card that teaches the two manual steps.
///
/// Deliberately not a question: it sits under whatever answer was given
/// rather than replacing it. Refusing to say what the next meeting is,
/// when we probably have it right, would be a worse trade than answering
/// with a caveat attached.
private struct SetupBox: View {
    let card: CalendarSetupCard
    let surface: SurfaceStyle
    let onAction: (CalendarSetupAction) -> Void
    let onToggle: (String, Bool) -> Void
    /// Shown when a toggle was refused, so the refusal is explained rather
    /// than looking like the switch is broken.
    let refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SaylineMarker()
            Text(card.title)
                .font(.system(size: SpeechBackBox.fontSize, weight: .semibold))
                .foregroundStyle(PillStyle.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Text(card.detail)
                .font(.system(size: SpeechBackBox.fontSize))
                .foregroundStyle(PillStyle.foreground)
                .opacity(0.75)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)

            if card.step == .review, !card.accounts.isEmpty {
                accountList
            }

            HStack(spacing: 6) {
                Button(card.primaryLabel) { onAction(.primary) }
                    .buttonStyle(FollowUpButtonStyle(role: .primary))
                Button(card.secondaryLabel) { onAction(.dismiss) }
                    .buttonStyle(FollowUpButtonStyle(role: .secondary))
            }
            .padding(.top, 11)
        }
        .frame(maxWidth: 324 - 32, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .surfaceBackground(surface, cornerRadius: 14)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Every account, with a switch, inside a fixed height.
    ///
    /// Scrolls rather than grows: this panel floats over whatever someone
    /// is working in, and a card that gets taller with each account added
    /// would eventually cover it. Three rows are visible and the rest are
    /// a scroll away, so four accounts and fourteen look the same from
    /// outside.
    private var accountList: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(card.summary)
                .font(.system(size: 11, weight: .medium))
                .opacity(0.9)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(card.accounts) { account in
                        AccountRow(account: account, onToggle: onToggle)
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 86)
            .scrollIndicators(.visible)

            if let refusal { 
                Text(refusal)
                    .font(.system(size: 10))
                    .opacity(0.6)
            }
        }
        .foregroundStyle(PillStyle.foreground)
        .padding(.top, 8)
    }
}

/// One account, with the switch that includes or excludes it.
private struct AccountRow: View {
    let account: ConnectedAccount
    let onToggle: (String, Bool) -> Void
    @State private var isOn: Bool

    init(account: ConnectedAccount, onToggle: @escaping (String, Bool) -> Void) {
        self.account = account
        self.onToggle = onToggle
        _isOn = State(initialValue: account.isSelected)
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { newValue in isOn = newValue; onToggle(account.id, newValue) }
        )) {
            Text(account.label)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(PillStyle.foreground.opacity(0.85))
    }
}

// MARK: - Follow-up

/// The question box. Shares the speech box's geometry deliberately — this
/// is the same surface saying something, not a new component.
///
/// What distinguishes it is the "Sayline" marker. Without it the question
/// is indistinguishable from the transcript being read back, and that is
/// the one ambiguity that must not exist here: someone would answer a
/// question they thought was their own words echoed at them.
private struct FollowUpBox: View {
    let request: FollowUpRequest
    let startedAt: Date
    let surface: SurfaceStyle
    let onAnswer: (FollowUpAnswer) -> Void
    /// Passed in rather than read here — the hotkey is user-configurable,
    /// and a hint naming the wrong key is worse than no hint.
    let hotkeySymbol: String

    private static let maxWidth: CGFloat = 324
    private static let horizontalPadding: CGFloat = 16
    private static let verticalPadding: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SaylineMarker()
            Text(request.question)
                .font(.system(size: SpeechBackBox.fontSize))
                .foregroundStyle(PillStyle.foreground)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = request.detail {
                Text(detail)
                    .font(.system(size: SpeechBackBox.fontSize, weight: .semibold))
                    .foregroundStyle(PillStyle.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
            }
            // Buttons and voice on every question, not one or the other.
            // Hands on the trackpad click; hands elsewhere talk.
            actions
            hintRow(hint)
        }
        .frame(maxWidth: Self.maxWidth - Self.horizontalPadding * 2, alignment: .leading)
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, Self.verticalPadding)
        .surfaceBackground(surface, cornerRadius: 14)
        .overlay(alignment: .bottomLeading) { countdown }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if case .confirm(let primary, let secondary) = request.kind {
                Button(primary) { onAnswer(.confirmed) }
                    .buttonStyle(FollowUpButtonStyle(
                        role: request.isDestructive ? .destructive : .primary))
                Button(secondary) { onAnswer(.declined) }
                    .buttonStyle(FollowUpButtonStyle(role: .secondary))
            }
            // A quick choice delivers exactly what saying it would, so the
            // caller parses one thing rather than branching on how the
            // answer arrived.
            ForEach(request.quickChoices, id: \.label) { choice in
                Button(choice.label) { onAnswer(.spoken(choice.spoken)) }
                    .buttonStyle(FollowUpButtonStyle(role: .secondary))
            }
        }
        .padding(.top, 11)
    }

    /// Names the key on every question. Nothing else on screen says the
    /// microphone is closed, and without it people talk into a mic that
    /// isn't listening.
    ///
    /// When silence means go, the hint says so instead. The draining bar
    /// looks identical either way, and the same picture must not silently
    /// mean "this disappears" in one place and "this happens" in another.
    private var hint: String {
        if request.timeoutMeans == .confirmed {
            return "Continuing automatically — hold \(hotkeySymbol) and say no to stop"
        }
        switch request.kind {
        case .confirm: return "Hold \(hotkeySymbol) and say yes or no"
        case .value(let hint): return hint
        }
    }

    private func hintRow(_ hint: String) -> some View {
        Text(hint)
            .font(.system(size: 11))
            .foregroundStyle(PillStyle.foreground)
            .opacity(0.55)
            .padding(.top, 9)
    }

    /// Wall-clock driven, like the dots — no animation transaction, so
    /// nothing leaks into the surface beneath.
    private var countdown: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startedAt)
            let remaining = max(0, 1 - elapsed / request.timeout)
            GeometryReader { geo in
                Rectangle()
                    .fill(PillStyle.foreground.opacity(0.32))
                    .frame(width: geo.size.width * remaining, height: 1.5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct FollowUpButtonStyle: ButtonStyle {
    enum Role { case primary, secondary, destructive }
    let role: Role

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(background.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var foreground: Color {
        switch role {
        case .primary: return Color(red: 0x16 / 255, green: 0x16 / 255, blue: 0x1A / 255)
        case .destructive: return Color(red: 0x1A / 255, green: 0x0E / 255, blue: 0x0D / 255)
        case .secondary: return PillStyle.foreground
        }
    }

    private var background: Color {
        switch role {
        case .primary: return PillStyle.foreground.opacity(0.92)
        case .destructive: return Color(red: 1, green: 0x5F / 255, blue: 0x57 / 255).opacity(0.9)
        case .secondary: return PillStyle.foreground.opacity(0.12)
        }
    }
}

// MARK: - Pill

/// Chooses the wording; `StatusPill` does the drawing.
///
/// The pill is one implementation now, shared with the standalone preview,
/// so the thing being reviewed and the thing that ships cannot diverge.
private struct PillView: View {
    @ObservedObject var viewModel: IndicatorViewModel
    let surface: SurfaceStyle

    var body: some View {
        StatusPill(text: label, surface: surface)
    }

    private var label: String {
        if viewModel.isAgentMode { return "Agent Listening" }
        if viewModel.isWorkMode { return "Work Listening" }
        return "Listening"
    }
}

// MARK: - Glass

/// A plain blurred backdrop, used by the `.flat` surface.
///
/// KNOWN APPROXIMATION: Figma specifies a 4px background blur, and there
/// is no macOS API that takes a backdrop-blur radius the way CSS
/// `backdrop-filter: blur(4px)` does. `NSVisualEffectView` is the only
/// real backdrop blur available, and its radius is fixed by the material
/// rather than settable. `.hudWindow` is the closest match for a small
/// overlay. In practice the gap is small here: the fill sits at 75%
/// opacity, so only a quarter of the backdrop shows through at all.
/// The blurred backdrop.
///
/// `backdrop-filter: blur(8px)` cannot be implemented directly. It blurs
/// the pixels behind the window, which belong to other apps and the
/// WindowServer, and an app cannot read them without Screen Recording
/// permission. NSVisualEffectView is the sanctioned route precisely
/// because the app never sees those pixels — the compositor does the blur
/// on its behalf.
///
/// The cost is that the radius is not exposed. A material is a semantic
/// role and Apple picks its blur, so "8px" is not a setting being missed;
/// it is not offered. The material is therefore chosen by eye against the
/// design — see `--preview-pill`, which renders the candidates together.
struct BackdropBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

extension View {
    /// One place for the container treatment so the pill and the speech
    /// box can't drift apart, and so the comparison only has to vary the
    /// style passed in.
    ///
    /// Internal rather than private since 2026-08-14: `StatusPill` lives in
    /// its own file and must use this rather than carry its own copy. The
    /// Figma had drifted apart on exactly these values — the speech boxes
    /// had wandered to `#0F0F0F` with a `#525252` stroke while the pill
    /// stayed `#141414`/`#666666` — and duplicating the treatment in code
    /// is how that happens again.
    ///
    /// Stroke and drop shadow were added here at the same time, from the
    /// settled spec in `DESIGN-pill-ui.md`. They apply to every caller:
    /// pill, speech box, notice, setup and follow-up. That is deliberate —
    /// they are one family of floating surfaces and the rule is written
    /// for the family.
    @ViewBuilder
    func surfaceBackground(_ style: SurfaceStyle, cornerRadius: CGFloat,
                           material: NSVisualEffectView.Material = .hudWindow) -> some View {
        surfaceFill(style, cornerRadius: cornerRadius, material: material)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color(red: 0x66 / 255, green: 0x66 / 255, blue: 0x66 / 255)
                        .opacity(0.25), lineWidth: 1)
            )
            .background(outerShadow(cornerRadius: cornerRadius))
    }

    /// The drop shadow, clipped so it exists only OUTSIDE the surface.
    ///
    /// `.shadow()` cannot be used directly here. SwiftUI paints a blurred
    /// copy of the shape behind the *whole* view, including the area the
    /// shape itself covers — unlike CSS `box-shadow`, which is clipped to
    /// outside the border box. Our fill is 75% opaque, so that dark copy
    /// showed straight through it and darkened the surface: the pill read
    /// as near-black instead of `#141414` over a blur, with a grey bloom
    /// around it. Reported by the user as "the drop shadow has a darken
    /// effect on top", and confirmed by rendering the same view with the
    /// shadow disabled — the fill came back to its intended lightness and
    /// the bloom vanished.
    ///
    /// So the shadow is cast by an opaque shape and the shape's own area
    /// is then punched out, leaving only the part that should have been
    /// outside all along. The mask is inflated so the blur is not clipped
    /// at the edge of the punched rectangle.
    @ViewBuilder
    private func outerShadow(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape
            .fill(Color.black)
            // Figma: #616161 at 25%, x0 y1, blur 4, **blend mode darken**.
            //
            // Darken cannot be reproduced. It is min(backdrop, shadow) per
            // channel, so it needs the pixels behind the window, and an app
            // cannot read those — see the note on backdrop blur below.
            // Rendered normally, #616161 is a mid grey: over a dark
            // wallpaper it would LIGHTEN, producing a pale halo where the
            // design intends nothing at all, since darken leaves anything
            // darker than #616161 untouched.
            //
            // Black approximates the intent far better than the literal
            // colour does: it only ever darkens, which is the half of
            // darken's behaviour that is reachable. Opacity is dropped to
            // 0.18 because black at 0.25 reads heavier than a grey at 0.25.
            // The radius is 2 for a CSS blur of 4.
            .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
            .compositingGroup()
            .mask(
                Rectangle()
                    .padding(-12)
                    .overlay(shape.blendMode(.destinationOut))
                    .compositingGroup()
            )
    }

    @ViewBuilder
    private func surfaceFill(_ style: SurfaceStyle, cornerRadius: CGFloat,
                             material: NSVisualEffectView.Material) -> some View {
        switch style {
        case .liquidGlass(let tint):
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

        case .flat(let fill):
            self.background(
                BackdropBlur(material: material)
                    .overlay(fill)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            )
        }
    }
}
