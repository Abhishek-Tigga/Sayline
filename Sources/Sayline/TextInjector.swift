import Cocoa

/// Puts text on the clipboard and simulates Cmd+V to paste it into
/// whatever app/field currently has focus.
enum TextInjector {
    private static let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

    static func pasteAtCursor(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        simulateCommandV()
    }

    private static func simulateCommandV() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
