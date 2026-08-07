import Cocoa

/// Watches for a chosen modifier key (see HotkeyOption) being held
/// down/released, system-wide, via a low-level CGEventTap. Also catches
/// Tab while the hotkey is held as a "cycle dictation style" shortcut,
/// swallowing that keystroke so it doesn't get typed into whatever app is
/// focused. Requires Accessibility permission to be granted before
/// `start()` will succeed.
final class HotkeyManager {
    private static let cycleStyleKeyCode: Int64 = 48 // kVK_Tab
    private static let agentModeKeyCode: Int64 = 49 // kVK_Space

    /// Changeable at runtime — the tap watches all flagsChanged events
    /// regardless of key, so switching which one we treat as "the
    /// hotkey" doesn't require recreating the tap.
    var hotkeyOption: HotkeyOption = .rightOption
    /// A second, independent hold-to-talk key — fixed (not exposed in
    /// Settings) rather than user-configurable, since its only purpose
    /// right now is letting the v3 and v4 floating-pill designs be
    /// compared live: primary (Right Option) triggers v4, this triggers
    /// v3. Both feed the same recording/transcription pipeline.
    let secondaryHotkeyOption: HotkeyOption = .rightCommand

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPrimaryActive = false
    private var isSecondaryActive = false
    /// Guards against keyboard auto-repeat: holding Space sends many
    /// rapid keyDown events, not just one, so without this we'd fire
    /// onAgentModeRequested (and log) dozens of times per hold. Shared
    /// across both hotkeys since only one hold is realistically active
    /// at once — this is "was agent mode requested during the current
    /// hold," not per-key state.
    private var agentModeAlreadyRequestedThisHold = false

    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?
    var onSecondaryHotkeyDown: (() -> Void)?
    var onSecondaryHotkeyUp: (() -> Void)?
    var onCycleStyleRequested: (() -> Void)?
    /// Fired when Space is pressed while either hotkey is held — flags
    /// the *current* recording as an agent request rather than
    /// dictation. Per-hold, not a persistent toggle: each new hold
    /// defaults back to dictation unless Space is pressed again during
    /// that hold.
    var onAgentModeRequested: (() -> Void)?

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
        NSLog("Sayline: hotkey listener started (hold \(hotkeyOption.displayName) for v4, \(secondaryHotkeyOption.displayName) for v3)")
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
            let isHotkeyActive = isPrimaryActive || isSecondaryActive
            if isHotkeyActive && keyCode == Self.cycleStyleKeyCode {
                NSLog("Sayline: style cycle requested")
                onCycleStyleRequested?()
                return nil // swallow Tab while dictating so it isn't typed
            }
            if isHotkeyActive && keyCode == Self.agentModeKeyCode {
                if !agentModeAlreadyRequestedThisHold {
                    agentModeAlreadyRequestedThisHold = true
                    NSLog("Sayline: agent mode requested")
                    onAgentModeRequested?()
                }
                return nil // swallow Space while dictating so it isn't typed
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

        if keyCode == hotkeyOption.rawValue {
            let isPressed = event.flags.contains(hotkeyOption.flagMask)
            if isPressed && !isPrimaryActive {
                isPrimaryActive = true
                agentModeAlreadyRequestedThisHold = false
                NSLog("Sayline: primary hotkey DOWN")
                onHotkeyDown?()
            } else if !isPressed && isPrimaryActive {
                isPrimaryActive = false
                NSLog("Sayline: primary hotkey UP")
                onHotkeyUp?()
            }
        }

        // Guards against the (unusual) case where a user's customized
        // primary hotkey collides with the fixed secondary — without
        // this both blocks would fire for the same physical key event.
        if keyCode == secondaryHotkeyOption.rawValue && secondaryHotkeyOption != hotkeyOption {
            let isPressed = event.flags.contains(secondaryHotkeyOption.flagMask)
            if isPressed && !isSecondaryActive {
                isSecondaryActive = true
                agentModeAlreadyRequestedThisHold = false
                NSLog("Sayline: secondary hotkey DOWN")
                onSecondaryHotkeyDown?()
            } else if !isPressed && isSecondaryActive {
                isSecondaryActive = false
                NSLog("Sayline: secondary hotkey UP")
                onSecondaryHotkeyUp?()
            }
        }
    }
}
