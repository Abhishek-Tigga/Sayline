import Cocoa
import ApplicationServices

struct FocusedAppInfo {
    let name: String
    let bundleID: String?
    let windowTitle: String?
    let context: AppContext
    /// The app's real icon, captured at hotkey-down for the indicator's
    /// logo box. App-level only — a web app in a browser shows the
    /// browser's icon, not the site's (macOS exposes nothing deeper).
    let icon: NSImage?
}

enum FocusedAppReader {
    static func current() -> FocusedAppInfo {
        let app = NSWorkspace.shared.frontmostApplication
        let name = app?.localizedName ?? "Unknown"
        let bundleID = app?.bundleIdentifier
        let title = focusedWindowTitle(pid: app?.processIdentifier)
        let context = AppContextDetector.context(forBundleID: bundleID, windowTitle: title)
        return FocusedAppInfo(name: name, bundleID: bundleID, windowTitle: title, context: context, icon: app?.icon)
    }

    /// Window-level AX info tends to be exposed even by apps (often
    /// Electron-based) whose deeper accessibility trees are thin —
    /// this is the practical signal for probing whether an app reveals
    /// its current mode/tab in its title, since bundle ID alone can't.
    private static func focusedWindowTitle(pid: pid_t?) -> String? {
        guard let pid else { return nil }
        let axApp = AXUIElementCreateApplication(pid)

        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let windowRef else {
            return nil
        }
        let window = windowRef as! AXUIElement

        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success else {
            return nil
        }
        return titleRef as? String
    }
}
