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

    /// Simulates Cmd+Z. Used by the "scratch that" voice command. Reliable
    /// when the last insertion went through the clipboard-paste fallback
    /// (paste is almost universally undoable); less guaranteed for direct
    /// AX-written text, since that bypasses the app's normal input
    /// pipeline and may not always land on its undo stack — a known,
    /// accepted limitation rather than something worth chasing further.
    static func undo() {
        simulateCommandKey(6) // kVK_ANSI_Z
    }

    // MARK: - Direct AX insertion

    /// Accessibility calls are synchronous cross-process IPC, and without an
    /// explicit cap they inherit a system default measured in seconds. A slow
    /// target (Electron apps are the usual culprit) therefore stalls whichever
    /// thread makes the call. That stall is what starved the event tap and
    /// froze system input on 2026-08-09 — see HotkeyManager.tapThread. Half a
    /// second is far longer than a healthy app needs and short enough that a
    /// wedged one just drops to the clipboard fallback.
    private static let axTimeout: Float = 0.5

    private static func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, axTimeout)
        var focusedRef: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        )
        guard focusResult == .success, let focusedRef else { return false }
        let element = focusedRef as! AXUIElement
        // The timeout is per-element, so the focused element needs its own.
        AXUIElementSetMessagingTimeout(element, axTimeout)

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
        simulateCommandKey(vKeyCode)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pasteboard.clearContents()
            if let previousContents {
                pasteboard.setString(previousContents, forType: .string)
            }
        }
    }

    private static func simulateCommandKey(_ keyCode: CGKeyCode) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
