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
    /// So the proof-of-life refusal is logged once per stall, not every
    /// 250ms slice for as long as the main thread is out.
    private var loggedProofOfLifeWait = false
    /// When the tap was disabled, most recent last. Backs the circuit
    /// breaker below.
    private var recentDisables: [Date] = []
    private var tappedOut = false
    /// So the breaker's disable happens exactly once, off the callback.
    private var hasTurnedTapOff = false

    // MARK: - Tap health
    //
    // All tap-thread only: written in the callback, read in
    // `reenableTapIfSafe` and `noteDisable`, both of which run on that same
    // thread. No locking, and none should be added without checking that
    // still holds.
    //
    // These exist because `tapDisabledByTimeout` means "your callback took
    // too long" and this project has never known what its callback cost or
    // how stale its events were. Two days of freeze analysis rested on a
    // measurement of the main thread, which is neither of those things.
    private var callbackCount = 0
    private var lastCallbackMillis = 0.0
    private var worstCallbackMillis = 0.0
    private var lastDeliveryLagMillis = 0.0
    private var worstDeliveryLagMillis = 0.0
    private var lastLagWarning = Date.distantPast

    /// Mach ticks to nanoseconds. Computed once; the ratio never changes
    /// for the life of the process.
    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// One line describing how well the tap is being serviced, for any log
    /// that needs it. Cheap enough to build on a disable.
    private var tapHealth: String {
        String(format: "callback last %.1fms worst %.1fms over %d events; "
                     + "delivery lag last %.0fms worst %.0fms",
               lastCallbackMillis, worstCallbackMillis, callbackCount,
               lastDeliveryLagMillis, worstDeliveryLagMillis)
    }

    /// Records what one callback cost, and how stale the event already was
    /// when it arrived.
    ///
    /// The lag is the interesting half. Fable's mechanism candidate is that
    /// macOS holds keyboard events for an active tap that is slow to
    /// service, and disables the tap once delivery backs up. If that is
    /// right, lag climbs before a disable — so this number should be rising
    /// in the seconds before the next freeze, and flat if the cause is
    /// outside this process.
    fileprivate func recordDelivery(event: CGEvent, spentNanos: UInt64) {
        let spent = Double(spentNanos) / 1_000_000
        callbackCount += 1
        lastCallbackMillis = spent
        worstCallbackMillis = max(worstCallbackMillis, spent)

        let timebase = Self.machTimebase
        let now = mach_absolute_time()
        let created = event.timestamp
        guard timebase.denom != 0, now > created else { return }
        let lag = Double(now - created) * Double(timebase.numer)
                / Double(timebase.denom) / 1_000_000
        lastDeliveryLagMillis = lag
        worstDeliveryLagMillis = max(worstDeliveryLagMillis, lag)

        // Rate-limited: a backed-up queue produces many late events at
        // once, and a log line per event would itself slow the callback
        // down — turning the diagnostic into the disease.
        if lag > 250, Date().timeIntervalSince(lastLagWarning) > 5 {
            lastLagWarning = Date()
            SaylineLog.log(String(format:
                "event arrived %.0fms late — delivery is backing up (%@)", lag, StallWatchdog.shared.snapshot))
        }
    }
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
            var slices = 0
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
                // Stamped before anything else in the slice: this is the
                // proof that the tap thread is still turning, and it is the
                // measurement the freeze investigation was missing.
                StallWatchdog.shared.tapBeat()

                // One line, once, about twenty slices in. Instrumentation
                // that only speaks during a failure cannot be trusted at the
                // moment of failure — this is the proof it was running all
                // along, and the baseline the next disable gets compared to.
                slices += 1
                if slices == 20 {
                    SaylineLog.log("tap instrumentation live — " + StallWatchdog.shared.snapshot
                                   + "; " + self.tapHealth)
                }
                self.reenableTapIfSafe()
                // This thread wakes every 250ms anyway, so it is the
                // cheapest place to notice the main thread going quiet —
                // and it keeps running even when main is the thing stuck.
                // The watchdog's own timer covers the reverse case.
                StallWatchdog.shared.check()
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
                // Measured around every callback, because the number macOS
                // acts on is how long we take to answer. `tapDisabledByTimeout`
                // canonically means "your callback took too long", and this
                // project has never once known what its callback cost.
                let began = DispatchTime.now().uptimeNanoseconds
                let result = manager.handle(event: event, type: type)
                manager.recordDelivery(event: event,
                                       spentNanos: DispatchTime.now().uptimeNanoseconds - began)
                return result
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

        // Proof of life before re-arming.
        //
        // Fable's mechanism candidate: macOS disables a tap that is slow to
        // service, and a prompt re-enable puts the same slow tap straight
        // back in the keyboard's path — turning one hiccup into a sustained
        // freeze. Re-enabling is only safe if there is reason to believe the
        // next callback will be answered promptly.
        //
        // The main thread is the check that matters, because the callback
        // hands work to it. Re-arming while main is stalled is precisely how
        // one hiccup is converted into a freeze. The tap thread needs no
        // check here — this code runs on it, so it is provably alive.
        let mainSilence = StallWatchdog.shared.mainThreadSilence
        if mainSilence >= 2 {
            if !loggedProofOfLifeWait {
                loggedProofOfLifeWait = true
                SaylineLog.log(String(format:
                    "not re-enabling the tap while the main thread is stalled (%.1fs) — "
                    + "re-arming a tap we cannot service is what freezes the keyboard", mainSilence))
            }
            return
        }
        if loggedProofOfLifeWait {
            loggedProofOfLifeWait = false
            SaylineLog.log("main thread answering again — the tap may be re-enabled")
        }

        // Backoff, not a fixed second. Repeated disables mean the last
        // re-enable did not help, so trying again at the same rate is the
        // tight loop this is meant to avoid. Doubles per disable in the
        // window, capped so recovery still happens within a few seconds.
        let backoff = min(pow(2, Double(max(0, recentDisables.count - 1))), 8)
        let now = Date()
        guard now.timeIntervalSince(lastTapReenable) >= backoff else { return }
        lastTapReenable = now
        tapNeedsReenable = false
        CGEvent.tapEnable(tap: eventTap, enable: true)
        SaylineLog.log(String(format: "event tap re-enabled after %.0fs — %@; %@",
                              backoff, StallWatchdog.shared.snapshot, tapHealth))
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
            //
            // Both threads' states go on this line, plus what the callback
            // has actually been costing. Earlier versions logged the main
            // thread alone and concluded from "main ok" that the refusal
            // came from outside the process — a conclusion the measurement
            // could not support, because the tap thread was never watched.
            // Read the tap figures first now: they are the ones macOS acts
            // on.
            SaylineLog.log("event tap was disabled by the system (\(type.rawValue)) — "
                           + StallWatchdog.shared.snapshot + "; " + tapHealth)
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
