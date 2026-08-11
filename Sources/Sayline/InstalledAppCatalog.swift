import AppKit
import Foundation

/// The apps on this Mac, by name.
///
/// Exists so the fast path can tell "open Safari" (an app that is right
/// here) from "open YouTube" (a website). Without it, matching "open X"
/// locally would either miss most apps or steal every website.
///
/// Scanned once at launch and cached. The list only changes when software
/// is installed, and a newly installed app simply routes through the model
/// until the next launch — the same answer, a second slower.
enum InstalledAppCatalog {
    private static var namesByNormalized: [String: String] = [:]
    private static var loaded = false

    private static let searchPaths = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
        // Finder and friends live here, not in /Applications, and "close
        // Finder" is a thing people say.
        "/System/Library/CoreServices",
    ]

    static func load() {
        guard !loaded else { return }
        loaded = true
        let fm = FileManager.default
        for path in searchPaths {
            guard let entries = try? fm.contentsOfDirectory(atPath: path) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let name = String(entry.dropLast(4))
                namesByNormalized[normalize(name)] = name
            }
        }
        SaylineLog.log("found \(namesByNormalized.count) installed apps")
    }

    /// The app's real name for a spoken one, or nil if nothing matches.
    ///
    /// Exact match only, after normalising. Fuzzy matching belongs to the
    /// model — this exists to answer "am I certain?", and anything less
    /// than certain should cost a round trip rather than open the wrong
    /// thing.
    static func realName(for spoken: String) -> String? {
        load()
        return namesByNormalized[normalize(spoken)]
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
