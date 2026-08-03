import Cocoa
import ApplicationServices

/// Inserts text at the cursor. Prefers writing directly into the focused UI
/// element via the Accessibility API (no clipboard involved); falls back to
/// clipboard + simulated Cmd+V for apps that don't support AX text editing,
/// restoring whatever was previously on the clipboard afterward.
enum TextInjector {
    static func insert(_ text: String) {
        if insertViaAccessibility(text) {
            NSLog("Sayline: inserted text via Accessibility API")
            return
        }
        NSLog("Sayline: AX insertion unavailable, falling back to clipboard paste")
        pasteViaClipboard(text)
    }

    // MARK: - Direct AX insertion

    private static func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard focusResult == .success, let focusedRef else { return false }
        let element = focusedRef as! AXUIElement

        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        )
        guard settableResult == .success, settable.boolValue else { return false }

        let setResult = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef
        )
        guard setResult == .success else { return false }

        // Some apps (web content, Electron, canvas-based editors like Figma)
        // report success without the write actually reaching the rendered UI.
        // Read the field back and only trust it if our text is really there.
        guard let after = stringValue(of: element), after.contains(text) else {
            NSLog("Sayline: AX set reported success but text not found on readback — treating as failed")
            return false
        }
        return true
    }

    private static func stringValue(of element: AXUIElement) -> String? {
        var ref: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    // MARK: - Clipboard fallback

    private static let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

    private static func pasteViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        simulateCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if let previousContents {
                pasteboard.setString(previousContents, forType: .string)
            }
        }
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
