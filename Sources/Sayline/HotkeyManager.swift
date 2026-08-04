import Cocoa

/// Watches for the Right Option key being held down/released, system-wide,
/// via a low-level CGEventTap. Also catches Tab while Right Option is held
/// as a "cycle dictation style" shortcut, swallowing that keystroke so it
/// doesn't get typed into whatever app is focused. Requires Accessibility
/// permission to be granted before `start()` will succeed.
final class HotkeyManager {
    private static let rightOptionKeyCode: Int64 = 61 // kVK_RightOption
    private static let cycleStyleKeyCode: Int64 = 48 // kVK_Tab

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isHotkeyActive = false

    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    var onCycleStyleRequested: (() -> Void)?

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(event: event, type: type)
            },
            userInfo: selfPointer
        ) else {
            NSLog("Sayline: failed to create event tap — is Accessibility permission granted?")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("Sayline: hotkey listener started (hold Right Option)")
        return true
    }

    func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        switch type {
        case .flagsChanged:
            handleFlagsChanged(event: event)
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if isHotkeyActive && keyCode == Self.cycleStyleKeyCode {
                NSLog("Sayline: style cycle requested")
                onCycleStyleRequested?()
                return nil // swallow Tab while dictating so it isn't typed
            }
            return Unmanaged.passUnretained(event)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS can silently disable an active tap if it decides the
            // callback isn't keeping up — without this, the hotkey goes
            // dead with zero indication anything happened.
            NSLog("Sayline: event tap was disabled by the system (\(type.rawValue)), re-enabling")
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Self.rightOptionKeyCode else { return }

        let isPressed = event.flags.contains(.maskAlternate)
        if isPressed && !isHotkeyActive {
            isHotkeyActive = true
            NSLog("Sayline: hotkey DOWN")
            onHotkeyDown?()
        } else if !isPressed && isHotkeyActive {
            isHotkeyActive = false
            NSLog("Sayline: hotkey UP")
            onHotkeyUp?()
        }
    }
}
