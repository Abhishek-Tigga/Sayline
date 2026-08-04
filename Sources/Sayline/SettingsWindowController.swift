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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sayline Settings"
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
