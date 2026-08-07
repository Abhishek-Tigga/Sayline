import Foundation

/// The tone/register axis for cleanup, layered on top of the fixed
/// "Clean" disfluency-removal pass: e.g. Email adds a polished,
/// professional lean on top of the usual filler/false-start cleanup.
enum AppContext: String {
    case email
    case chat
    case code
    case general

    /// Extra guidance appended to the style's base prompt. nil for
    /// .general (no adjustment) and .code (handled separately — see
    /// TranscriptCleaner, which forces verbatim for code regardless of
    /// style rather than using a prompt fragment at all).
    var promptFragment: String? {
        switch self {
        case .email:
            return "This is being dictated into an email. Use a polished, professional register appropriate for email correspondence."
        case .chat:
            return "This is being dictated into a chat/messaging app. Keep it casual and conversational — contractions are fine."
        case .code, .general:
            return nil
        }
    }
}

/// Maps a frontmost app's bundle identifier to a context category. Only
/// covers app-level detection — cannot distinguish different modes/tabs
/// within the same app (e.g. a chat tab vs a code tab in the same app
/// share one bundle ID). See FocusedAppInfo for the window-title signal
/// used to probe whether finer-grained detection is even possible.
enum AppContextDetector {
    private static let emailBundleIDs: Set<String> = [
        "com.apple.mail",
        "com.microsoft.Outlook",
        "com.readdle.smartemail-Mac",
        "com.superhuman.electron",
    ]

    private static let chatBundleIDs: Set<String> = [
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.apple.MobileSMS",
        "com.apple.iChat",
        "com.microsoft.teams2",
        "ru.keepcoder.Telegram",
    ]

    private static let codeBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        "dev.warp.Warp-Stable",
    ]

    /// Browsers all share one bundle ID regardless of what site is open,
    /// so bundle ID alone can't tell "Gmail tab" from any other tab —
    /// found via live testing (dictating into Gmail-in-Chrome fell to
    /// .general even though the window title clearly said "Gmail"). For
    /// browsers specifically, also check the window title for a known
    /// webmail signature before falling back to bundle-ID-only mapping.
    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser", // Arc
        "com.brave.Browser",
    ]

    private static let webmailTitleSignatures = ["gmail", "outlook", "yahoo mail", "protonmail"]

    static func context(forBundleID bundleID: String?, windowTitle: String?) -> AppContext {
        guard let bundleID else { return .general }

        if browserBundleIDs.contains(bundleID), let windowTitle, containsWebmailSignature(windowTitle) {
            return .email
        }

        if emailBundleIDs.contains(bundleID) { return .email }
        if chatBundleIDs.contains(bundleID) { return .chat }
        if codeBundleIDs.contains(bundleID) { return .code }
        return .general
    }

    private static func containsWebmailSignature(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return webmailTitleSignatures.contains { lowered.contains($0) }
    }
}
