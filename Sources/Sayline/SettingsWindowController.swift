import Cocoa
import SwiftUI

/// Owns a normal (titled, closable) settings window, shown on demand from
/// the menu bar popover. Sayline is an LSUIElement app (no Dock icon, no
/// standard app menu), so we can't rely on the conventional Cmd+, /
/// "Settings…" menu item — this is triggered directly by a button instead.
final class SettingsWindowController {
    private var window: NSWindow?
    private let appDelegate: AppDelegate

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingView(rootView: SettingsView().environmentObject(appDelegate))
        // Stop the hosting view negotiating the window's size limits.
        //
        // By default `NSHostingView` pushes its content's required size
        // into the window's min/max extrema. In a window that cannot
        // resize, taller-than-the-window content makes that negotiation
        // recurse: SwiftUI measures during AppKit's constraint pass, the
        // measurement mutates the view graph, and the graph asks for
        // another constraint pass from inside the current one. AppKit
        // throws, and an uncaught exception in a display cycle is an
        // immediate crash.
        //
        // Crashed on 2026-08-12 and twice on 08-13 with identical stacks —
        // `updateWindowContentSizeExtremaIfNecessary` →
        // `setNeedsUpdateConstraints` → `_postWindowNeedsUpdateConstraints`.
        // The bug predates work mode; adding six rows to Settings pushed
        // the content past the fixed 420pt height and turned latent into
        // reliable.
        hosting.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
            // Resizable as well, so content taller than the window has an
            // honest way out rather than a negotiation nobody can win.
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentMinSize = NSSize(width: 420, height: 320)
        window.title = "Sayline Settings"
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
