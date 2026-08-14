import Carbon
import Cocoa

/// Watches for a chosen modifier key (see HotkeyOption) being held
/// down/released, system-wide. Requires Accessibility permission to be
/// granted before `start()` will succeed.
///
/// **Two taps since 2026-08-14 — the freeze fix.** macOS holds keyboard
/// delivery for an active (`.defaultTap`) tap until its callback
/// answers, and disables the tap when it decides the answer is too slow;
/// our polite re-enable then put the same tap straight back in the
/// keyboard's path, converting one hiccup into a sustained freeze. That
/// loop is the best surviving explanation for every observed freeze
/// (four incidents, three disproven theories — review/LEDGER.md).
///
/// So the permanent tap is now **listen-only**: it receives a copy of
/// events after delivery, nothing ever waits on it, and however slow its
/// callback gets, the keyboard cannot freeze because of it. The failure
/// mode is removed, not made rarer.
///
/// The only thing that ever needed an active tap is swallowing Space
/// during a hold so it isn't typed while dictating. A tiny active tap
/// (keyDown only) is created at hotkey-down and torn down at hotkey-up:
/// the freeze surface shrinks from all day to the seconds a hold lasts,
/// and "while idle, Sayline holds nothing" now covers the dangerous tap
/// kind too. `Sayline --selftest-hotkey` asserts both halves.
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

    /// The always-on listen-only tap: gesture detection, never blocking.
    private var permanentTap: EventTap?
    /// The hold-scoped active tap: exists only between hotkey-down and
    /// hotkey-up, solely so Space can be swallowed while dictating.
    /// `nil` whenever no hold is in progress — asserted by the selftest,
    /// because a leftover is invisible to whoever caused it.
    private var holdTap: EventTap?
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
    /// immediately no matter what the app is doing. (The listen-only
    /// split removes the holding-input half of that story; the dedicated
    /// thread stays because the *hold* tap is active and does block.)
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

    /// Fired when the breaker trips, so the app can tell the user their
    /// hotkey is gone and why.
    var onTapGaveUp: (() -> Void)?
    private var isHotkeyActive = false
    /// Guards against keyboard auto-repeat: holding Space sends many
    /// rapid keyDown events, not just one, so without this we'd fire
    /// onAgentModeRequested (and log) dozens of times per hold. Shared
    /// by the hold tap and the listen-only fallback path, so the request
    /// fires once no matter which tap sees Space first.
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
    /// is not worth breaking someone's dialog. (The listen-only tap could
    /// not consume it anyway — the policy and the mechanism now agree.)
    var onEscapePressed: (() -> Void)?

    /// Whether the hold-scoped active tap currently exists. For
    /// `--selftest-hotkey`, which asserts it appears during a hold and —
    /// the half that matters — is gone once the hold ends.
    var holdTapIsInstalled: Bool { holdTap?.isInstalled ?? false }

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
                                   + "; " + (self.permanentTap?.health ?? "no tap"))
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
        let tap = EventTap(label: "hotkey", options: .listenOnly, mask: mask) {
            [weak self] type, event in
            guard let self else { return Unmanaged.passUnretained(event) }
            return self.handle(event: event, type: type)
        }
        tap.onDisabled = { [weak self] type in
            guard let self else { return }
            // Both threads' states go on this line, plus what the callback
            // has actually been costing. Earlier versions logged the main
            // thread alone and concluded from "main ok" that the refusal
            // came from outside the process — a conclusion the measurement
            // could not support, because the tap thread was never watched.
            SaylineLog.log("event tap was disabled by the system (\(type.rawValue)) — "
                           + StallWatchdog.shared.snapshot + "; "
                           + (self.permanentTap?.health ?? "no tap"))
            self.noteDisable()
        }
        guard tap.install() else {
            SaylineLog.log("failed to create event tap — is Accessibility permission granted?")
            return false
        }
        permanentTap = tap
        SaylineLog.log("hotkey listener started listen-only on its own thread (hold \(hotkeyOption.displayName))")
        return true
    }

    func stop() {
        tapThread?.cancel()
        tapThread = nil
    }

    /// Runs on the tap thread as its run loop exits, so the sources are
    /// removed from the same run loop they were added to.
    private func uninstallTap() {
        removeHoldTap()
        permanentTap?.uninstall()
        permanentTap = nil
        tapDidInstall = false
    }

    // MARK: - The hold-scoped active tap

    /// The one active (`.defaultTap`) tap left in the app, alive only
    /// while a hold is in progress. Its sole job is swallowing Space so
    /// it isn't typed while dictating — the single thing a listen-only
    /// tap cannot do. Created here on the tap thread (this runs inside
    /// the permanent tap's callback), so both taps' callbacks share one
    /// run loop and the gesture state needs no locking.
    private func installHoldTap() {
        guard holdTap == nil, !tappedOut else { return }
        let tap = EventTap(label: "hold", options: .defaultTap,
                           mask: CGEventMask(1 << CGEventType.keyDown.rawValue)) {
            [weak self] type, event in
            guard let self, type == .keyDown,
                  event.getIntegerValueField(.keyboardEventKeycode) == Self.agentModeKeyCode
            else { return Unmanaged.passUnretained(event) }
            self.requestAgentMode()
            return nil // swallow Space while dictating so it isn't typed
        }
        tap.onDisabled = { type in
            // No re-enable machinery, deliberately: this tap dies with
            // the hold and the next hold gets a fresh one. Worst case for
            // one hold is an unswallowed Space. Fighting the system over
            // an active tap is the exact behavior the freeze fix removed.
            SaylineLog.log("hold tap disabled by the system (\(type.rawValue)) mid-hold — "
                           + "Space may reach the app until the hold ends")
        }
        if tap.install() {
            holdTap = tap
        } else {
            // Fail open: dictation and agent mode both still work through
            // the listen-only tap — see the fallback in `handle`. Only
            // the swallow is lost, and one stray space beats a dead
            // feature.
            SaylineLog.log("hold tap failed to install — Space will not be swallowed this hold")
        }
    }

    private func removeHoldTap() {
        holdTap?.uninstall()
        holdTap = nil
    }

    // MARK: - Disable policy (permanent tap)

    /// Stops fighting when the system keeps rejecting us.
    ///
    /// Written after the freeze recurred on 2026-08-11 with the tap
    /// enabled and secure input off — the case the previous theory
    /// explicitly did not cover. Seven disables in 96 seconds, and a user
    /// whose keyboard stopped working until the app was killed.
    ///
    /// Since the listen-only split, re-enabling this tap can no longer
    /// harm the keyboard — the stakes have dropped from "dead keyboard"
    /// to "dead hotkey". The breaker stays anyway: the cause of the
    /// disables is still unknown (review/LEDGER.md, OPEN), and while it
    /// is, a system that keeps rejecting us is telling us something we
    /// don't understand. Giving up loudly still beats persisting quietly.
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
            // The active tap must not outlive the decision to stand down.
            // This runs on the tap thread (disable events arrive in the
            // callback), so the teardown is on the right run loop.
            removeHoldTap()
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
    /// against the window server. Both matter less now that this tap is
    /// listen-only — nothing waits on it — but the policy is kept until
    /// the disables themselves are explained.
    private func reenableTapIfSafe() {
        // The one place `tapEnable` is called for the permanent tap, so a
        // disable can never re-enter the callback that asked for it.
        if tappedOut {
            if let permanentTap, !hasTurnedTapOff {
                hasTurnedTapOff = true
                permanentTap.disable()
                SaylineLog.log("event tap switched off on the tap thread")
            }
            return
        }
        guard tapNeedsReenable, let permanentTap else { return }

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
        // With a listen-only tap this is caution rather than necessity —
        // re-arming cannot freeze anything now. But a disable while main
        // is stalled means the app cannot service a hold anyway, so there
        // is nothing to gain by hurrying, and the discipline is kept
        // until the disables are explained.
        let mainSilence = StallWatchdog.shared.mainThreadSilence
        if mainSilence >= 2 {
            if !loggedProofOfLifeWait {
                loggedProofOfLifeWait = true
                SaylineLog.log(String(format:
                    "not re-enabling the tap while the main thread is stalled (%.1fs)", mainSilence))
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
        permanentTap.enable()
        SaylineLog.log(String(format: "event tap re-enabled after %.0fs — %@; %@",
                              backoff, StallWatchdog.shared.snapshot, permanentTap.health))
    }

    // MARK: - Gesture logic

    private func requestAgentMode() {
        guard !agentModeAlreadyRequestedThisHold else { return }
        agentModeAlreadyRequestedThisHold = true
        SaylineLog.log("agent mode requested")
        onAgentModeRequested?()
    }

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        switch type {
        case .flagsChanged:
            handleFlagsChanged(event: event)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.escapeKeyCode {
                onEscapePressed?()
            } else if isHotkeyActive, keyCode == Self.agentModeKeyCode, holdTap == nil {
                // Fallback for a hold whose active tap failed to install:
                // Space cannot be swallowed, but agent mode must still
                // work. When the hold tap exists it both swallows and
                // fires the request, and this branch stays out of the way.
                requestAgentMode()
            }
        default:
            break
        }
        // Listen-only: the system ignores this return value. It exists
        // only to satisfy the EventTap handler signature.
        return Unmanaged.passUnretained(event)
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
            installHoldTap()
            SaylineLog.log("hotkey DOWN")
            onHotkeyDown?()
        } else if !isPressed && isHotkeyActive {
            isHotkeyActive = false
            removeHoldTap()
            SaylineLog.log("hotkey UP")
            onHotkeyUp?()
        }
    }
}
