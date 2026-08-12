# Fable — main-thread deadlock in CoreAudio (and probably *the* freeze)

Open `/Users/abhishektigga/Documents/Dictation/Sayline`.

This is not a request to find the cause. The cause is captured in a stack
trace, below. It is a request to check that the diagnosis is right, that
the fix is the right shape, and that it does not break the most critical
path in the app.

## The evidence

Symptom escalated over three builds: dictation captured `frames: 0`, then
the whole app hung — menu bar icon dead, hotkey dead, `%CPU 33`, state `R`.
Main thread never recovered (3+ minutes).

The log stops mid-`beginRecording`:

```
22:36:39.512  hotkey DOWN
22:36:39.881  focused app -> Claude
              (nothing — no "recording started", no [mic] diagnostic)
22:36:40.807  hotkey UP
22:36:40.978  MAIN THREAD STALLED — no heartbeat for 2.1s
```

`sample` of the hung process, main thread:

```
AppDelegate.beginRecording()                    AppDelegate.swift:313
  AudioRecorder.start(preferredDeviceUID:)      AudioRecorder.swift:113
    -[AVAudioNode outputFormatForBus:]
      AVAudioIONodeImpl::GetOutputFormat
        AVAudioIOUnit::GetClientFormat
          _dispatch_sync_f_slow
            __DISPATCH_WAIT_FOR_QUEUE__
              _dispatch_event_loop_wait_for_ownership
                kevent_id
```

Line 113 is `let format = input.outputFormat(forBus: 0)`.

The queue it is waiting for, `DispatchQueue_724: AVAudioIOUnit (serial)`,
is itself stuck:

```
AVAudioIOUnit::IOUnitPropertyListener           ← device-config change
  AVAudioIOUnit_OSX::_GetHWFormat
    AudioObjectGetPropertyData_mac_imp
      HALPlugIn::ObjectGetPropertyData
        HALC_ProxyObject::GetPropertyData
          HALC_Object_GetPropertyData_DAI32     ← 543 samples, mach IPC
```

So: `outputFormat(forBus:)` is a `dispatch_sync` onto AVFAudio's internal
queue; that queue is servicing a hardware-property listener that is doing a
slow round trip to `coreaudiod`; the main thread waits and never returns.

This machine's audio device list is unstable, which is very likely what
keeps the listener firing:

```
BenQ MA270UP
Abhishek's iphone Microphone      (Continuity)
Bass Baggie                       (listed twice — duplicated Bluetooth)
Bass Baggie
MacBook Air Microphone
Microsoft Teams Audio             (virtual driver)
```

An earlier recording also ran on `CADefaultDeviceAggregate-61109-0`, an
aggregate device macOS created on its own.

## The claim worth checking hardest

**This is probably the long-standing freeze.** `CLAUDE.md` records four
incidents where the user's whole keyboard stopped until Sayline was killed,
with three theories disproven: event-tap starvation, an `NSPanel` leak
(14 created, 14 deallocated), and Secure Input contention. The fourth
incident had the tap enabled and secure input off, which the third theory
explicitly did not cover.

A main thread wedged in CoreAudio explains it without needing any of them:
the app stops responding, so macOS disables the CGEvent tap with
`kCGEventTapDisabledByTimeout`, and keystrokes stop being delivered until
the process dies. `StallWatchdog` was built specifically to tell "our
callback is blocked" from "the system refused us", and it has now fired
with a stack that says the first.

Check whether that reasoning holds. If it does not, say so plainly — a lot
would be built on it.

## The fix (in `HEAD`, `claimed-fixed`, unverified)

`AudioRecorder` now does all engine work on a private serial queue and
never on the main thread. `start` and `stop` take completion handlers and
call them back on main. `AppDelegate.handleHotkeyUp` moves its
post-processing inside `stop`'s completion.

Review for:

1. **The release-before-start race.** The hotkey can go up before the
   engine has started. The serial queue preserves order, but confirm the
   state machine cannot end up recording with nobody to stop it, or
   double-stopping.
2. **`isRecording` ownership.** Written on main to block re-entry, but the
   engine work is elsewhere. Is there a window where main believes it is
   recording and the engine is not, that matters?
3. **The zero-frame symptom.** Does moving off main actually fix it, or
   only the hang? A tap that never fires because the IO unit is wedged may
   still never fire. If so, say what else is needed — a timeout, a device
   reset, refusing to start when the HAL is unresponsive.
4. **Whether anything else touches audio from main.** `SoundEffectPlayer`,
   and `NowPlaying.swift` (added today, uses
   `kAudioHardwarePropertyProcessObjectList`) — the latter is only called
   from the media actions, off main, but confirm.
5. **Whether a device this unstable should be handled explicitly.** Pinning
   `preferredInputDeviceUID` to a device that vanishes is a candidate for
   making the churn worse, and there is a duplicated Bluetooth device here.

## Rules

Every rebuild changes the ad-hoc signature and costs the user their
Accessibility and Microphone grants, so experiments are expensive. Prefer
one build that separates several hypotheses to a sequence of guesses.

Two probes exist and are worth reusing, in
`/private/tmp/claude-501/-Users-abhishektigga-Documents-claude/5a23ba11-61a3-493f-b07c-2e5632c99937/scratchpad/`:
`mictest.swift` (a standalone `AVAudioEngine` that captured 48000 frames on
the same device at the same moment Sayline captured 0) and
`sayline-sample.txt` (the full `sample` output quoted above).

Append to `review/LEDGER.md`. You may mark your own work `claimed-fixed`,
never `VERIFIED` — and this one especially needs a human to hold the key.
