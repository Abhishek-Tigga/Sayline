import Cocoa
import SwiftUI

/// Owns a normal (titled, closable, resizable) window showing dictation
/// history — a scrollable list needs real space, so this is a separate
/// window rather than crammed into the small menu bar popover.
final class HistoryWindowController {
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

        let hosting = NSHostingView(rootView: HistoryView().environmentObject(appDelegate))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sayline History"
        window.contentView = hosting
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
