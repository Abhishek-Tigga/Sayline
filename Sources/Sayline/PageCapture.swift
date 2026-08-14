import Foundation
import AppKit

/// Reads the front browser's current tab URL, and nothing else.
///
/// Split from `AgentExecutor` so the Apple Event surface for this feature
/// is one small auditable file. Decision 3 of `DESIGN-whatsapp-share.md`
/// governs *when* this runs: only on a hold that has been flagged for
/// agent mode, never on a plain dictation. While idle, Sayline holds
/// nothing — an Apple Event fired on every hotkey press would break that
/// for a URL almost no dictation needs.
enum PageCapture {

    /// Bundle IDs that answer a URL query, by dialect.
    ///
    /// Safari and the Chromium family disagree about how to name the
    /// front tab, so the script is chosen by family rather than written
    /// once and hoped over. Firefox is deliberately absent — decision 11:
    /// it does not answer AppleScript URL queries at all, and a visible
    /// failure is better than a guess scraped from a window title.
    static let safariLike: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    static let chromiumLike: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    static let firefoxLike: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
    ]

    enum Failure: Error, Equatable {
        case notABrowser(appName: String)
        case firefox
        /// Scriptable, but the query came back empty or was refused —
        /// most often Automation permission not yet granted.
        case refused(appName: String)

        /// What the user is told. From the design's failure table:
        /// every branch says what happened and, where there is one, the
        /// way out.
        var message: String {
            switch self {
            case .notABrowser:
                return "Nothing to share here — this works from a browser."
            case .firefox:
                return "Firefox can't share its page — it doesn't answer that request. Try Safari or Chrome."
            case .refused(let app):
                return "\(app) didn't share its page. Allow Sayline to control \(app) in System Settings > Privacy & Security > Automation."
            }
        }
    }

    /// The front app's current tab, or a classified failure.
    ///
    /// Logs the host only. The log file is meant to be handed over, and
    /// a full reading history in it would make that a worse trade than
    /// the bug it helps diagnose.
    static func currentPageURL() -> Result<URL, Failure> {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            return .failure(.notABrowser(appName: "This app"))
        }
        let name = app.localizedName ?? bundleID

        if firefoxLike.contains(bundleID) { return .failure(.firefox) }

        let script: String
        if safariLike.contains(bundleID) {
            script = "tell application id \"\(bundleID)\" to return URL of front document"
        } else if chromiumLike.contains(bundleID) {
            script = "tell application id \"\(bundleID)\" to return URL of active tab of front window"
        } else {
            return .failure(.notABrowser(appName: name))
        }

        SaylineLog.log("[share] asking \(name) for the current page")
        guard let raw = AgentExecutor.appleScriptString(script)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, let url = URL(string: raw) else {
            SaylineLog.log("[share] \(name) returned no URL — automation denied or no window")
            return .failure(.refused(appName: name))
        }
        SaylineLog.log("[share] captured a page on \(url.host ?? "?")")
        return .success(url)
    }
}
