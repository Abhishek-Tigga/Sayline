import Cocoa

/// Curated, clean-cut app icons for known apps, keyed by bundle ID —
/// real macOS app icons (from NSWorkspace) always carry Apple's baked-in
/// rounded-square canvas, padding, and drop shadow, which is *part of
/// the icon bitmap itself*, not something clippable off. For apps we
/// bother to curate, we bundle a proper transparent-background asset
/// instead and skip the system icon entirely. Anything not in this
/// catalog falls back to the real system icon, shown at its native
/// shape (no circle clip) so it renders clean without fighting its own
/// geometry — see RecordingIndicatorView.appIconBox.
enum AppIconCatalog {
    private static let bundleIDToResource: [String: String] = [
        "com.anthropic.claudefordesktop": "claude",
    ]

    /// Loads directly from the bundled SVG rather than an asset catalog
    /// entry — NSImage renders SVG natively since macOS 11, so no
    /// asset-catalog step is needed for a handful of curated icons.
    static func icon(forBundleID bundleID: String?) -> NSImage? {
        guard let bundleID, let resourceName = bundleIDToResource[bundleID] else { return nil }
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "svg") else {
            NSLog("Sayline: curated icon \"\(resourceName)\" not found in bundle")
            return nil
        }
        return NSImage(contentsOf: url)
    }
}
