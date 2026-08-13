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

    /// Inter at a size and weight, or the system font if it is missing.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        isAvailable
            ? .custom(familyName, fixedSize: size).weight(weight)
            : .system(size: size, weight: weight)
    }

    // MARK: - Monospace

    /// IBM Plex Mono, bundled the same way and for the same reason.
    ///
    /// Used only for the speech box's "Command" header, chosen over the
    /// pixel faces: it says terminal without the costume, and it will age
    /// better than an 8-bit face if the app grows up around it. Regular and
    /// Medium ship; nothing asks for another weight.
    static let monoFamilyName = "IBM Plex Mono"

    static let isMonoAvailable: Bool = {
        let available = NSFont(name: monoFamilyName, size: 10) != nil
        SaylineLog.log(available
            ? "IBM Plex Mono registered from the app bundle"
            : "IBM Plex Mono NOT registered — falling back to the system monospace.")
        return available
    }()

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        isMonoAvailable
            ? .custom(monoFamilyName, fixedSize: size).weight(weight)
            : .system(size: size, weight: weight, design: .monospaced)
    }
}
