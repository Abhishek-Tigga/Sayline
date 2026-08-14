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
    private static var userInstalledNames: Set<String> = []
    private static var loaded = false

    /// The directories users put apps in themselves. Split out for the
    /// vocabulary bias: the first dump of the full catalog spent the
    /// entire glossary budget on alphabetically-early CoreServices
    /// internals (`AOSUIPrefPaneLauncher`, `AccessibilityUIServer`) —
    /// unusual words by any dictionary, said aloud by no one. Apple's
    /// own app names are in every model's training data anyway; the
    /// names worth biasing are the third-party ones that live here.
    private static let userInstalledPaths = [
        "/Applications",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    private static let systemPaths = [
        "/System/Applications",
        "/System/Applications/Utilities",
        // Finder and friends live here, not in /Applications, and "close
        // Finder" is a thing people say.
        "/System/Library/CoreServices",
    ]

    static func load() {
        guard !loaded else { return }
        loaded = true
        let fm = FileManager.default
        for path in userInstalledPaths + systemPaths {
            guard let entries = try? fm.contentsOfDirectory(atPath: path) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let name = String(entry.dropLast(4))
                namesByNormalized[normalize(name)] = name
                if userInstalledPaths.contains(path) {
                    userInstalledNames.insert(name)
                }
            }
        }
        SaylineLog.log("found \(namesByNormalized.count) installed apps (\(userInstalledNames.count) user-installed)")
    }

    /// User-installed app names only, for the vocabulary bias ladder —
    /// see the comment on `userInstalledPaths` for why system apps are
    /// excluded. Sorted so the list is stable run to run: the bias
    /// budget cuts from the end, and which apps fall off must not
    /// depend on filesystem enumeration order.
    static var biasCandidateNames: [String] {
        load()
        return userInstalledNames.sorted()
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
