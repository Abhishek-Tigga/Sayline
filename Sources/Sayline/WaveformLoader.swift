import SwiftUI

/// The 3×3 "thinking" indicator.
///
/// A band of darkness travels outward across a fully lit grid: the centre
/// dims first, then the four edges, then the four corners. Not a bright
/// pulse moving out — that reading cannot reproduce the source frames,
/// because it dims the centre as it travels and no source frame has a
/// hollow middle.
///
/// Three numbers describe any frame completely: all four corners share one
/// opacity, all four edges share another, the centre has its own. Only
/// opacity animates; the colour never changes.
///
/// Derived from Figma `g3HFEsLnpetmkjg7i1thBl` node `15:696` (ten frames,
/// described by the user as a rough mockup) and settled against the live
/// prototype in `design/waveform.html`, which carries the full working and
/// the sliders. `DESIGN-pill-ui.md` records the numbers.
struct WaveformLoader: View {
    /// Which motion the grid runs.
    ///
    /// Two, deliberately: the mode has to be readable from the corner of
    /// an eye. Chosen from `design/waveform-variants.html`, which renders
    /// nine candidates side by side inside a pill — keep that page, it is
    /// the library for the next one of these.
    enum Motion {
        /// Darkness travelling outward from the centre. Agent mode. Reads
        /// as thinking.
        case outwardDip
        /// A highlight travelling clockwise around the eight outer cells,
        /// centre steady. Plain dictation and work mode. Reads as waiting
        /// rather than working, which is the distinction that matters —
        /// agent mode is doing something, dictation is listening.
        case ringSpin
    }

    var motion: Motion = .outwardDip
    /// Whole grid. 15 means 5pt cells, matching the Figma placeholder.
    var size: CGFloat = 15
    var colour: Color = .white
    /// The design's 8pt glow, expressed as a SwiftUI shadow radius.
    ///
    /// A quarter, not a half. `radius: glow / 2` was tried first and the
    /// bloom swallowed the grid at 15pt — a white shape that small under a
    /// 4pt shadow reads as a fuzzy dot, losing the hard square edges the
    /// design is explicitly built on. The CSS prototype gets away with a
    /// wider blur because there it is scaled by the mean cell opacity, so
    /// it fades as the ring dims; a constant SwiftUI shadow has no such
    /// relief and has to be tighter.
    var glow: CGFloat = 8
    var period: Double = 0.8

    /// The dip every ring runs, delayed by its distance from the centre.
    ///
    /// Taken from the mockup's *edges* row — the only ring whose dip
    /// completes inside the ten frames, with both a full fall and a full
    /// recovery. The `0.3 → 0.6 → 0.9` step is a frame the mockup skipped;
    /// it jumped 0.3 → 0.9 in one step, which is what made the motion read
    /// as steppy. Adding it halves the worst per-frame opacity change at
    /// 800ms/60fps, 0.131 → 0.069 — better than slowing the cycle to
    /// 1200ms would have managed (0.088). The fix is in the shape, not the
    /// tempo.
    private static let dip: [Double] = [1, 0.8, 0.5, 0.3, 0.1, 0.1, 0.3, 0.6, 0.9, 1]

    /// Share of the cycle one ring's dip occupies, and the lag between one
    /// ring and the next.
    ///
    /// These come to 120% of the cycle, which is deliberate: the local
    /// phase is taken modulo 1, so a dip that overruns wraps into the next
    /// cycle rather than being cut off. The rings therefore overlap, which
    /// is what makes it read as fluid, and the loop stays continuous.
    ///
    /// The mockup's own loop was not continuous — its corners ended at 0.3
    /// and restarted at 1.0, a visible 0.7 pop every cycle, because they
    /// never finished recovering.
    private static let dipFraction = 0.90
    private static let ringLag = 0.15

    /// 0 centre, 1 edge, 2 corner — read row by row.
    private static let ring = [2, 1, 2, 1, 0, 1, 2, 1, 2]

    /// The eight outer cells clockwise from top-left, for `ringSpin`.
    private static let ringOrder = [0, 1, 2, 5, 8, 7, 6, 3]
    /// Settled with the user on the prototype: pulse width 1, which the
    /// spin narrows to 0.7 — a full-width pulse on eight cells lights the
    /// whole ring at once and the travel disappears.
    private static let pulseWidth = 1.0
    /// Cells never go fully dark; the grid stays legible as a grid.
    private static let floor = 0.12
    /// The centre holds while the ring travels. It is the still point the
    /// motion reads against — animate it too and the shape dissolves.
    private static let centreOpacity = 0.55

    var body: some View {
        let cell = size / 3
        TimelineView(.animation) { timeline in
            let phase = (timeline.date.timeIntervalSinceReferenceDate / period)
                .truncatingRemainder(dividingBy: 1)
            // Fixed 3×3, no spacing: the cells butt edge to edge and are
            // square-cornered. Both are explicit in the design and both
            // have been asked for by name.
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { column in
                            Rectangle()
                                .fill(colour)
                                .frame(width: cell, height: cell)
                                .opacity(Self.opacity(at: row * 3 + column, phase: phase, motion: motion))
                        }
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: colour.opacity(0.45), radius: glow / 4)
    }

    /// Opacity of one cell at a phase in turns.
    static func opacity(at index: Int, phase: Double, motion: Motion = .outwardDip) -> Double {
        switch motion {
        case .outwardDip:
            let local = wrap01(phase - Double(ring[index]) * ringLag)
            return dipValue(at: local / dipFraction)
        case .ringSpin:
            guard let step = ringOrder.firstIndex(of: index) else { return centreOpacity }
            let offset = Double(step) / Double(ringOrder.count)
            return floor + (1 - floor) * pulse(phase - offset, width: pulseWidth * 0.7)
        }
    }

    private static func wrap01(_ x: Double) -> Double {
        (x.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
    }

    /// A smooth bump: 1 at t = 0, falling to 0 at ±width/2, wrapping at 1.
    private static func pulse(_ t: Double, width: Double) -> Double {
        let w = wrap01(t)
        let distance = min(w, 1 - w)
        let x = min(1, distance / (width / 2))
        return 0.5 + 0.5 * cos(.pi * x)
    }

    /// Catmull-Rom through `dip`, clamped at both ends so the curve leaves
    /// and rejoins the resting value with zero slope — no velocity kink
    /// where the dip starts and stops.
    private static func dipValue(at u: Double) -> Double {
        guard u > 0, u < 1 else { return 1 }
        let n = dip.count
        let x = u * Double(n - 1)
        let i = Int(x)
        let t = x - Double(i)
        func point(_ k: Int) -> Double { dip[min(max(k, 0), n - 1)] }
        let p0 = point(i - 1), p1 = point(i), p2 = point(i + 1), p3 = point(i + 2)
        let value = 0.5 * (2 * p1
            + (-p0 + p2) * t
            + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
            + (-p0 + 3 * p1 - 3 * p2 + p3) * t * t * t)
        return min(1, max(0, value))
    }
}
