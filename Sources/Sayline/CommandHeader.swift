import AppKit
import SwiftUI

/// The `>_` prompt, drawn as pixels rather than as a vector glyph.
///
/// Hand-drawn on an 8×8 grid because the label beside it is monospaced and
/// terminal-flavoured; an antialiased vector glyph next to it reads as an
/// icon that happened to land there rather than part of the same idea.
///
/// 12pt over an 8-cell grid is 1.5pt per cell — three device pixels on a
/// Retina display, so every cell lands whole and the edges stay hard. On a
/// 1x display it would be 1.5 device pixels and soften; every Mac this
/// ships to is Retina, so that is accepted rather than designed around.
struct PixelPromptIcon: View {
    var size: CGFloat = 12
    var colour: Color

    /// `#` is a lit pixel. Chevron on the left, underscore at the baseline.
    private static let pattern = [
        "........",
        "#.......",
        ".#......",
        "..#.....",
        "...#....",
        "..#.....",
        ".#......",
        "#...###.",
    ]

    var body: some View {
        Canvas { context, canvasSize in
            let cell = canvasSize.width / CGFloat(Self.pattern.count)
            for (y, row) in Self.pattern.enumerated() {
                for (x, character) in row.enumerated() where character == "#" {
                    let rect = CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell,
                                      width: cell, height: cell)
                    context.fill(Path(rect), with: .color(colour))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)      // the label beside it already says it
    }
}

/// "`>_` Command", above the transcript in the speech box.
///
/// Figma node 35:1648: a 12pt glyph, gap 2, then the word at 10pt in
/// `#E6E6E6`, the row sitting 4 above the transcript and aligned to its
/// leading edge.
struct CommandHeader: View {
    static let iconSize: CGFloat = 12
    static let iconGap: CGFloat = 2
    static let gapToTranscript: CGFloat = 4
    static let fontSize: CGFloat = 10
    static let label = "Command"
    /// #E6E6E6 — brighter than the transcript's #CCCCCC. It is a label, and
    /// it sits above the thing it labels, so it reads first and briefly.
    static let colour = Color(red: 0xE6 / 255, green: 0xE6 / 255, blue: 0xE6 / 255)

    var body: some View {
        HStack(spacing: Self.iconGap) {
            PixelPromptIcon(size: Self.iconSize, colour: Self.colour)
            Text(Self.label)
                .font(Typeface.mono(Self.fontSize, weight: .medium))
                .foregroundStyle(Self.colour)
                .fixedSize()
        }
    }

    /// How wide the header needs to be, so the box can hug the wider of the
    /// header and the transcript rather than clipping this.
    static var width: CGFloat {
        let font = NSFont(name: Typeface.monoFamilyName, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let text = (label as NSString).size(withAttributes: [.font: font]).width
        return (iconSize + iconGap + text).rounded(.up)
    }
}
