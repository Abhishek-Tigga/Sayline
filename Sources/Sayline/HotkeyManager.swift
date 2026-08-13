import Carbon
import Cocoa

/// Watches for a chosen modifier key (see HotkeyOption) being held
/// down/released, system-wide, via a low-level CGEventTap. Requires
/// Accessibility permission to be granted before `start()` will succeed.
final class HotkeyManager {
    private static let agentModeKeyCode: Int64 = 49 // kVK_Space
    /// Work mode: hold the hotkey and press Right Command.
    ///
    /// Replaces the double-tap, which the user found unpleasant in use —
    /// "the double tap option is not feeling nice". This mirrors agent
    /// mode's shape exactly: hold to talk, add one key to change what the
    /// hold means. Two gestures built the same way are one thing to learn
    /// instead of two.
    ///
    /// Command arrives as a modifier, so it is seen in `flagsChanged`
    /// rather than `keyDown` — it cannot be swallowed the way Space is,
    /// and does not need to be: a bare Command press types nothing.
    private static let workModeKeyCode: Int64 = 54 // kVK_RightCommand
    private static let escapeKeyCode: Int64 = 53 // kVK_Escape

    /// Changeable at runtime — the tap watches all flagsChanged events
    /// regardless of key, so switching which one we treat as "the
    /// hotkey" doesn't require recreating the tap.
    var hotkeyOption: HotkeyOption = .rightOption

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The tap gets its own thread and run loop. It used to live on the
    /// main run loop, which meant every tap callback queued behind
    /// whatever the main thread was doing — including the synchronous
    /// Accessibility IPC in FocusedAppReader and TextInjector. When those
    /// blocked (Electron apps answer AX slowly), macOS could not deliver
    /// events to the tap, held keyboard and mouse input while it waited,
    /// and then disabled the tap with kCGEventTapDisabledByTimeout. That
    /// held input *is* a system-wide freeze: observed live 2026-08-09,
    /// three times in ~3 hours, with six timeout events logged in one
    /// 65-second window. On a dedicated thread the callback answers
    /// immediately no matter what the app is doing.
    private var tapThread: Thread?
    private var tapDidInstall = false
    /// Set by the callback, acted on by the thread loop — see
    /// `reenableTapIfSafe`.
    private var tapNeedsReenable = false
    private var lastTapReenable = Date.distantPast
    private var loggedSecureInputWait = false
    /// When the tap was disabled, most recent last. Backs the circuit
    /// breaker below.
    private var recentDisables: [Date] = []
    private var tappedOut = false
    /// So the breaker's disable happens exactly once, off the callback.
    private var hasTurnedTapOff = false
    /// Fired when the breaker trips, so the app can tell the user their
    /// hotkey is gone and why.
    var onTapGaveUp: (() -> Void)?
    private var isHotkeyActive = false
    /// Guards against keyboard auto-repeat: holding Space sends many
    /// rapid keyDown events, not just one, so without this we'd fire
    /// onAgentModeRequested (and log) dozens of times per hold.
    private var agentModeAlreadyRequestedThisHold = false
    private var workModeAlreadyRequestedThisHold = false

    var onHotkeyDown: (() -> Void)?
    var onHotkeyUp: (() -> Void)?

    /// Called on hotkey-down when this hold is a Work hold — a second
    /// press that arrived quickly after a brief first one.
    ///
    /// Deliberately a *separate* callback fired alongside `onHotkeyDown`
    /// rather than a parameter on it. The first press has already started
    /// recording by then, exactly as it always has; nothing waits to
    /// discover whether a second tap is coming, so ordinary dictation
    /// keeps its instant start. This only tells the app that the hold now
    /// in progress means Work.
    var onWorkModeHold: (() -> Void)?

    /// Fired when Space is pressed while the hotkey is held — flags the
    /// *current* recording as an agent request rather than dictation.
    /// Per-hold, not a persistent toggle: each new hold defaults back to
    /// dictation unless Space is pressed again during that hold.
    var onAgentModeRequested: (() -> Void)?
    /// Escape, while a follow-up question is on screen. Observed rather
    /// than consumed: the panel never becomes key window, so this tap is
    /// the only way to hear the key at all — but swallowing it would eat a
    /// press the app underneath may be waiting for. Dismissing our overlay
    /// is not worth breaking someone's dialog.
    var onEscapePressed: (() -> Void)?

    /// Spins up the tap thread and waits briefly for it to report whether
    /// the tap was created, so callers keep the synchronous success/failure
    /// contract they had when this ran inline on the main thread.
    @discardableResult
    func start() -> Bool {
        guard tapThread == nil else { return true }

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            self.tapDidInstall = self.installTap()
            ready.signal()
            guard self.tapDidInstall else { return }
            // A plain CFRunLoopRun() would never return, so the loop is
            // driven in short slices to stay cancellable.
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
                self.reenableTapIfSafe()
                // This thread wakes every 250ms anyway, so it is the
                // cheapest place to notice the main thread going quiet —
                // and it keeps running even when main is the thing stuck.
                StallWatchdog.shared.checkFromBackgroundThread()
            }
            self.uninstallTap()
        }
        thread.name = "com.abhishektigga.sayline.event-tap"
        // Input handling is as latency-critical as it gets — this thread
        // must never be deprioritised behind background work.
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()

        _ = ready.wait(timeout: .now() + 2)
        if !tapDidInstall {
            tapThread = nil
        }
        return tapDidInstall
    }

    private func installTap() -> Bool {
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
            SaylineLog.log("failed to create event tap — is Accessibility permission granted?")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        SaylineLog.log("hotkey listener started on its own thread (hold \(hotkeyOption.displayName))")
        return true
    }

    func stop() {
        tapThread?.cancel()
        tapThread = nil
    }

    /// Runs on the tap thread as its run loop exits, so the source is
    /// removed from the same run loop it was added to.
    private func uninstallTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        tapDidInstall = false
    }

    /// Stops fighting when the system keeps rejecting us.
    ///
    /// Written after the freeze recurred on 2026-08-11 with the tap
    /// enabled and secure input off — the case the previous theory
    /// explicitly did not cover. Seven disables in 96 seconds, and a user
    /// whose keyboard stopped working until the app was killed.
    ///
    /// The cause is still unknown after three disproven theories. What is
    /// known is the shape: when macOS starts repeatedly timing this tap
    /// out, re-enabling it is how the app stays in the input path while
    /// the system is trying to remove it. So it stops.
    ///
    /// A dead hotkey is a bad outcome. A dead keyboard is a much worse
    /// one, and the person cannot even quit the app to fix it. Given an
    /// unexplained failure that harms the machine, giving up loudly beats
    /// persisting quietly.
    private func noteDisable() {
        // Already given up. Every line below must not run twice.
        //
        // On 2026-08-13 this fired **24,884 times** and froze the user's
        // keyboard — the exact outcome the breaker exists to prevent.
        // Two mistakes compounded:
        //
        // 1. `CGEvent.tapEnable(enable: false)` was called from inside the
        //    tap callback, and disabling a tap that way delivers another
        //    `tapDisabled` event, which re-entered here. A loop that fed
        //    itself.
        // 2. Nothing checked whether the breaker had already tripped, so
        //    each pass logged again and fired `onTapGaveUp` again — which
        //    is the notice the user saw, drawn ~25,000 times. The pill
        //    redraw is what actually consumed the machine.
        //
        // The comment on the callback said "let the thread loop decide,
        // rather than fighting the window server from inside the
        // callback". This function was doing exactly what that sentence
        // forbids.
        guard !tappedOut else { return }

        let now = Date()
        recentDisables.append(now)
        recentDisables.removeAll { now.timeIntervalSince($0) > 120 }

        guard recentDisables.count < 4 else {
            tappedOut = true
            tapNeedsReenable = false
            // NOT disabled here. `reenableTapIfSafe` on the tap thread
            // owns every call to `tapEnable`, so the disable cannot
            // re-enter this callback.
            SaylineLog.log("the system disabled the event tap \(recentDisables.count) times in two minutes — "
                  + "giving up rather than fighting for the keyboard. Hotkey is off until relaunch.")
            onTapGaveUp?()
            return
        }
        tapNeedsReenable = true
    }

    /// Restores the tap once it is safe to do so. Runs on the tap thread
    /// between run-loop slices, never from inside the callback.
    ///
    /// Two rules, both learned from the freeze described above:
    /// while Secure Input Mode is on, a password field owns the keyboard
    /// and we stay out of its way entirely; and even afterwards, attempts
    /// are spaced so a persistent failure cannot become a tight loop
    /// against the window server.
    private func reenableTapIfSafe() {
        // The one place `tapEnable` is called, so a disable can never
        // re-enter the callback that asked for it.
        if tappedOut {
            if let eventTap, !hasTurnedTapOff {
                hasTurnedTapOff = true
                CGEvent.tapEnable(tap: eventTap, enable: false)
                SaylineLog.log("event tap switched off on the tap thread")
            }
            return
        }
        guard tapNeedsReenable, let eventTap else { return }

        if IsSecureEventInputEnabled() {
            if !loggedSecureInputWait {
                loggedSecureInputWait = true
                SaylineLog.log("secure input is on (a password field has the keyboard) — leaving the tap off until it ends")
            }
            return
        }
        if loggedSecureInputWait {
            loggedSecureInputWait = false
            SaylineLog.log("secure input ended")
        }

        let now = Date()
        guard now.timeIntervalSince(lastTapReenable) >= 1 else { return }
        lastTapReenable = now
        tapNeedsReenable = false
        CGEvent.tapEnable(tap: eventTap, enable: true)
        SaylineLog.log("event tap re-enabled")
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        switch type {
        case .flagsChanged:
            handleFlagsChanged(event: event)
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.escapeKeyCode {
                onEscapePressed?()
                return Unmanaged.passUnretained(event) // pass through, always
            }
            if isHotkeyActive && keyCode == Self.agentModeKeyCode {
                if !agentModeAlreadyRequestedThisHold {
                    agentModeAlreadyRequestedThisHold = true
                    SaylineLog.log("agent mode requested")
                    onAgentModeRequested?()
                }
                return nil // swallow Space while dictating so it isn't typed
            }
            return Unmanaged.passUnretained(event)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS silently disables an active tap when it decides the
            // callback isn't keeping up. Re-enabling is right; re-enabling
            // *immediately, every time* is what froze a keyboard.
            //
            // Observed 2026-08-11: a Keychain password dialog appeared, the
            // user's keyboard stopped accepting input while the mouse kept
            // working, and this line logged every ~20s. A password field
            // turns on Secure Input Mode, which stops delivering keystrokes
            // to taps; the system then times ours out, we re-enable, and it
            // times out again. Each cycle re-evaluates the input path, and
            // the dialog never receives the keystrokes it is waiting for.
            // The user could not type the password that would have ended
            // the whole thing.
            //
            // The mouse still worked because the tap's mask is keyboard
            // only — flagsChanged and keyDown — which is exactly the shape
            // of the symptom reported.
            //
            // So: mark it and let the thread loop decide, rather than
            // fighting the window server from inside the callback.
            // The main thread's state at this instant is the fact three
            // investigations lacked. Alive means our callback is not
            // blocked by the app and the refusal came from outside the
            // process; stalled means it is ours to find.
            SaylineLog.log("event tap was disabled by the system (\(type.rawValue)) — "
                           + StallWatchdog.shared.snapshot)
            noteDisable()
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(event: CGEvent) {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        // Right Command pressed *during* a hold switches this dictation to
        // Work. Checked before the hotkey guard below, because this is a
        // different key and would otherwise be filtered out.
        if keyCode == Self.workModeKeyCode, isHotkeyActive,
           event.flags.contains(.maskCommand), !workModeAlreadyRequestedThisHold {
            workModeAlreadyRequestedThisHold = true
            SaylineLog.log("work mode requested")
            onWorkModeHold?()
            return
        }

        guard keyCode == hotkeyOption.rawValue else { return }

        let isPressed = event.flags.contains(hotkeyOption.flagMask)
        if isPressed && !isHotkeyActive {
            isHotkeyActive = true
            agentModeAlreadyRequestedThisHold = false
            workModeAlreadyRequestedThisHold = false
            SaylineLog.log("hotkey DOWN")
            onHotkeyDown?()
        } else if !isPressed && isHotkeyActive {
            isHotkeyActive = false
            SaylineLog.log("hotkey UP")
            onHotkeyUp?()
        }
    }
}
