import AppKit
import SwiftUI

/// The app's typeface.
///
/// Inter, bundled as `Resources/Inter.ttf` and registered at launch by
/// `ATSApplicationFontsPath` in Info.plist. Bundled rather than assumed:
/// Inter was not installed on any machine tested, and Figma's numbers are
/// Inter's — the pill measured 168pt wide against the design's 175 purely
/// because SF Pro sets "Agent Listening" 7pt narrower.
enum Typeface {
    static let familyName = "Inter"

    /// Checked once. A missing font is the kind of failure that hides:
    /// `Font.custom` silently falls back to the system face, so the app
    /// keeps working and merely stops matching the design, which is
    /// exactly the sort of drift nobody notices for weeks. This makes it
    /// say so.
    static let isAvailable: Bool = {
        let available = NSFont(name: familyName, size: 16) != nil
        SaylineLog.log(available
            ? "Inter registered from the app bundle"
            : "Inter NOT registered — falling back to the system font. Check that "
              + "Resources/Inter.ttf is in the bundle and ATSApplicationFontsPath is set.")
        return available
    }()

    /// The AppKit font, for measuring. Must match what `ui` renders —
    /// measuring in one weight and drawing in another sizes a box too
    /// narrow for its own text, and it then wraps where it should not.
    static func nsFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard isAvailable else { return .systemFont(ofSize: size, weight: weight) }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: familyName,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size)
            ?? NSFont(name: familyName, size: size)
            ?? .systemFont(ofSize: size, weight: weight)
    }

    /// Inter at a size and weight, or the system font if it is missing.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        isAvailable
            ? .custom(familyName, fixedSize: size).weight(weight)
            : .system(size: size, weight: weight)
    }
}
