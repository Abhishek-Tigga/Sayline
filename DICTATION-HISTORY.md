# Dictation health log

Everything that has broken the path from **holding the hotkey** to **text
appearing**: the microphone, the audio engine, voice processing, the event
tap, permissions, transcription.

This is a history, not a diagnosis. When dictation breaks again the cause
may be entirely new — but the same few mechanisms keep reappearing under
different symptoms, and the entries below have twice contained the answer
to a later problem. Read it for cues, not conclusions.

## How to use it

Start at **Recurring mechanisms**. If the symptom matches one, check that
first. If nothing matches, add a new entry rather than forcing the fit.

Every entry records: what the user saw, what the log said, the actual
cause, the fix, and **what was working immediately before** — the last
question is usually the fastest route to the answer.

## What the 2026-08-13 session taught

Six failures in one day, on the one path the product exists for. Every fix
was correct about the layer it touched and wrong about the layer beneath:
latency, then engine start, then device binding, then file format, then
channel mapping. These are the rules that came out of it.

**Verify the contract, not the delta.** Each fix was checked against the
symptom it was meant to remove, and the invariant went unwatched: *a hold
of N seconds yields ≈N seconds of audible audio, starting fast, on the
fifth hold as well as the first.* Every regression was visible in the very
log that shipped with its fix — the `+1134 ms` line was printed by the
change that caused it.

**Assert on the payload, not the envelope.** A recording had the right
duration, sample rate, channel count and file size, and contained pure
silence. Duration, bytes and format are the envelope. Peak amplitude is
the payload. A check that never looks inside will pass while the feature
is dead.

**Which prompt did *not* appear is evidence.** The user located a failure
faster than the instrumentation did by noticing the missing password
prompt — the Keychain unlocking the API key. Its absence proved
transcription was never reached, placing the fault downstream of capture.
Absent side effects narrow the search as well as present ones.

**Write guards against induced failures, not expected ones.** "Fails open"
covered `setVoiceProcessingEnabled` *throwing*. It succeeded and broke the
engine one call later, and nothing caught it. If a guard has never been
seen to fire, it has not been tested.

**A harness with a lifecycle bug lies.** Three probes gave false answers
before one worked — writing from a tap whose file had gone, and blocking
the main thread while results were delivered *on* the main thread (which
reported "0.00s recorded" from a 719 KB file). Prove the harness on a
known-good case before trusting it on a broken one.

**Run the capture self-test after any `AudioRecorder` change. Not
optional.**

```bash
Sayline --selftest-capture 3 5
```

Five holds on one recorder, asserting start latency, duration on disk and
peak amplitude. Every failure below would have been caught by it.

## Recurring mechanisms

Ranked by how often they have turned out to be the cause.

**1 · A rebuild silently revokes permissions.** Ad-hoc signing changes the
app's fingerprint on every build, so macOS treats it as a new app.
Accessibility, Microphone and the Keychain entry all reset. Symptom: the
hotkey does nothing, or records silence, with no dialog explaining why —
a *denied* permission never re-prompts.

```bash
tccutil reset Accessibility com.abhishektigga.sayline
```

**2 · The engine starts and captures nothing.** `frames: 0` with the tap
never firing. Almost always a device problem rather than a permission one,
and the log line to read is which device it opened. `unknown (id 0)` means
no device at all.

**3 · This Mac's audio device list is unstable.** A duplicated Bluetooth
device, a Continuity iPhone microphone, a BenQ monitor and a Microsoft
Teams virtual driver are all present. macOS churns that list, and several
failures have traced back to it rather than to Sayline.

**4 · The main thread must never touch the audio engine.** Doing so has
frozen the whole app, and probably the keyboard with it.

## Entries, newest first

### 2026-08-13 · Sayline quietened the entire Mac

**Seen:** all system audio playing at minimum however high the volume was
set. Resolved on killing Sayline. The user asked whether we turn their
volume down, and said the thing worth keeping: *"We should not modify the
user's system in order to fit our purpose."*

**Not the volume setting** — that read 100 throughout, and `setVolume` runs
only from an explicit command.

**Cause:** voice processing does two things, and we only ever wanted one.
It subtracts the speaker signal from the microphone (the 97% bleed fix),
**and** it turns every other app down, because macOS assumes a
voice-processing unit means a call. Enabled at launch, it ducked the
system for the app's whole life.

**Measured**, fixed tone through the speakers, three repetitions per state:

```
Sayline not running        1.59  1.45  1.59
running, never held        0.035 0.035 0.035   <- 43x quieter
after one hold             0.072 0.072 0.035
killed again               1.48  1.65  1.60
```

**Two attempted fixes, both measured, both insufficient:**
`voiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking:
false, duckingLevel: .min)` — `.min` is the smallest duck, not "none".
Re-applying it on every start — no better. The only way not to duck while
idle is not to have voice processing enabled while idle, and enabling it
per hold costs ~700ms of the user's first words.

**Resolution: voice processing parked** behind
`AudioRecorder.voiceProcessingWanted`, off. The exit criterion had been
written in advance by Fable — *if ducking survives both fixes, VP is
removed* — so this was a rule applied, not a judgement made under
pressure. Verified after: A ≈ B ≈ C (1.5 / 1.5 / 2.0), and five holds
capture cleanly.

**Also fixed regardless:** `SoundEffectPlayer` started an `AVAudioEngine`
in `init()` and never stopped it, so the process never went audio-quiet.
It now starts for a chime and stops after.

**Cost accepted:** speaker audio can again bleed into a transcript when
dictating with music playing on the built-in speakers.

**Working until:** voice processing was introduced the previous day.

### 2026-08-13 · Recordings full of silence, and no password prompt

**Seen:** dictation produced nothing. The user's key observation was the
useful one: *"I usually am asked for a permission, I enter my password —
only then does dictation work. Now it's not asking."*

That prompt is the **Keychain** unlocking the API key after a rebuild
changed the app's signature. Its absence meant transcription was never
reached — not that a permission had been refused.

**Log:**
```
frames: 41465, file 84 KB, wrote 16000Hz 1ch     ← writing works
audio peak 0.0 over 2.69s -> silent, skipping    ← contains nothing
```

**Cause:** the 16 kHz downmix. Voice processing presents a **9-channel**
input here, and `AVAudioConverter`'s default `channelMap` for 9→1 is
`[-1]` — "fill the output with silence". It did. Recordings had the right
length, sample rate and file size, and no sound. Measured: every one of the
nine channels carried the same signal at peak 0.3857, so there was never a
shortage of audio to take.

The map was visible in an earlier probe of mine (`channelMap: [-1]`) and I
did not react to it.

**Fix:** `converter.channelMap = [0]` whenever downmixing to mono.

**The deeper miss:** `--selftest-capture` passed throughout, because it
asserted duration, sample rate and file size — never that the audio
contained sound. The check now measures peak amplitude and plays a sound
source so silence cannot pass. Same blind spot as the code, one layer up.

**Working until:** the 16 kHz conversion added earlier the same day.

### 2026-08-13 · Recordings truncated to a fraction of the hold

**Seen:** "not capturing properly" — the first dictation of a session fine,
later ones capturing little or nothing. Asked whether a dB or gain change
caused it; no level or threshold was ever touched.

**Log:**
```
14:32:54.398  hotkey DOWN
14:32:54.830  voice processing turned off      (+432ms)
14:32:55.532  voice processing enabled        (+1134ms)
14:32:55.579  recording started               (+1181ms)
14:32:56.046  hotkey UP
              duration: 0.4777s  frames: 19200  tap fired 4 time(s)
```

**Cause:** the previous entry's fix toggles voice processing off and on to
set the input device safely — and that toggle costs about 1.1 seconds, on
**every hold**. The microphone is not listening while the user is talking.
Capture itself is healthy: the tap fires, frames arrive, `audio peak
0.917 -> has speech`.

**Status: open.** Handed to Fable for a plan rather than patched a fourth
time. The open question is whether voice processing should be enabled once
at launch instead of per hold, or reverted entirely — it has now caused
three distinct failures of the core feature in one day.

**Also seen, undiagnosed:** `transcription failed -> The request timed
out.` twice at 14:33.

**Working until:** the device-ordering fix earlier the same day.

### 2026-08-13 · Zero frames after the first two holds, `-10851`

**Seen:** first dictation transcribed fine, every later hold captured
nothing and wrote nothing. Asked whether a dB or gain change caused it — it
did not; no level or threshold was touched.

**Log:**
```
14:26:22  tap fired 20 time(s), frames 96000 -> "Hello"       ✓
14:26:35  failed to set preferred input device -> status -10851
          recording started on unknown (id 0)
          tap fired 0 time(s), frames 0                        ✗
```

**Cause:** enabling voice processing binds the input node to a private
aggregate device (`CADefaultDeviceAggregate-68355-0`, visible in the log
one hold earlier). Setting `kAudioOutputUnitProperty_CurrentDevice` on that
aggregate fails with -10851 **and leaves the unit with no device**, which
then starts cleanly and records silence. Two holds worked because voice
processing had not yet created the aggregate.

Contributing: the pinned microphone in Settings was `BuiltInMicrophoneDevice`
— already the system default — so the call that broke everything was
fighting for something it would have got for free.

**Fix:** device selection now happens on a plain unit (voice processing off
first, device set, then re-enabled); it is skipped entirely when the chosen
device is already the default; and a failed set falls back to the default
instead of leaving the unit pointing at nothing.

**Working until:** the voice-processing change earlier the same day.

### 2026-08-13 · Dictation completely dead, no permission prompt

**Seen:** granted access, held the key, nothing recorded. The usual
first-run permission prompts never appeared.

**Log:** `format 48000.0Hz 9ch, inputNode format 0.0Hz`, then
`failed to start audio engine: Code=-10875, PerformCommand(*outputNode,
kAUInitialize)`.

**Cause:** `setVoiceProcessingEnabled(true)` succeeded and then the engine
refused to start, from the *output* node — voice processing couples input
to output, and the output device at that moment presented a layout it could
not initialise. No engine meant no audio was ever requested, which is why
no permission dialog appeared.

**Fix:** voice processing is an attempt, not a setting. If the engine will
not start with it, the attempt is torn down and retried without it, and a
failure is remembered for the session.

**Working until:** the voice-processing change, hours earlier.

### 2026-08-12 · Whole app frozen — menu bar and hotkey dead

**Seen:** icon unresponsive, hotkey dead, no recovery for minutes.

**Cause:** `outputFormat(forBus:)` is a `dispatch_sync` onto AVFAudio's
internal queue. That queue was servicing a hardware-property listener stuck
in a mach round trip to `coreaudiod`, and the **main thread** waited on it
forever. Captured in a `sample` stack.

**Very likely the long-standing freeze** — four incidents, three disproven
theories (tap starvation, panel leak, Secure Input). A wedged main thread
stops the app servicing its event tap, macOS disables the tap with
`kCGEventTapDisabledByTimeout`, and the keyboard dies until Sayline is
killed.

**Fix:** all engine work moved to a private serial queue; `start`/`stop`
take completions that fire on main.

### 2026-08-12 · Dictation transcribed YouTube lyrics

**Cause:** built-in speakers reach the built-in microphone; Whisper cannot
tell a lyric from a sentence.

**First fix, rejected:** pausing audible media for the length of each hold.
It worked and was hated — *"this experience is very bad."*

**Actual fix:** `setVoiceProcessingEnabled` — echo cancellation. Measured
peak 0.8085 → 0.0230, a 97% reduction, music untouched. Note this fix is
also the cause of the two 2026-08-13 entries above; it was worth keeping,
but it needed the guards it now has.

### 2026-08-12 · `frames: 0`, blamed on the input device

**Seen:** every recording silent, message said "check the input device".

**Two wrong theories** worth not repeating: the rebuild had revoked the
microphone grant (disproved — the log printed `mic authorized: true`), and
the device was at fault (disproved — a standalone `AVAudioEngine` in
another process captured 48000 frames on the same device at the same
moment).

**Real cause:** the main-thread deadlock above, in its milder form.

**Left behind:** `beginRecording` used to call `start()` without ever
checking the authorization flag that launch had stored. Now checked live on
every hold, because a launch-time answer is stale the moment anything
changes.

## Diagnostics that have earned their place

- `[mic]` lines: engine state before start, both node formats, whether the
  tap fired **at all**, and the first buffer's frames and peak. A tap that
  never fires and a tap firing silence are different bugs.
- `StallWatchdog`: `MAIN THREAD STALLED` next to any audio line points at
  the deadlock class.
- `sample <pid>` while the app is hung. Do this **before** killing it —
  that stack is what solved the freeze.
- A standalone `AVAudioEngine` in another process, to tell "Sayline is
  broken" from "this Mac is broken":
  `scratchpad/mictest.swift`.

### 2026-08-13 · Keyboard frozen — the circuit breaker fed itself

**Seen:** hotkey unresponsive, then the whole keyboard froze on any
keypress. A notice from Sayline saying macOS was rejecting it.

**Log:** `/tmp/sayline.log` reached **10 MB in one session**:

```
24,872 ×  indicator shown -> message("Sayline")
24,884 ×  "the system disabled the event tap N times in two minutes —
           giving up rather than fighting for the keyboard."
          event tap was disabled by the system (4294967295) — main ok 0.8s
```

**Cause: ours, not macOS.** `noteDisable()` called
`CGEvent.tapEnable(enable: false)` **from inside the tap callback**, and
disabling a tap that way delivers another `tapDisabled` event, which
re-entered the same function. Nothing checked whether the breaker had
already tripped, so every pass logged again and fired the user-facing
notice again — ~25,000 pill redraws is what actually consumed the
machine.

`main ok 0.8s` throughout: **this is not the CoreAudio deadlock.** The
main thread was healthy and being flooded with UI work from a spinning
callback. A different failure with the same symptom.

The comment above the callback said "let the thread loop decide, rather
than fighting the window server from inside the callback". The function
below it did exactly what that forbade.

**Fix:** `noteDisable` returns immediately once `tappedOut`, so it logs
and notifies exactly once. Every `tapEnable` call now happens in
`reenableTapIfSafe` on the tap thread — one owner, so a disable can never
re-enter the callback that requested it.

**Note the disable code:** `4294967295` is
`kCGEventTapDisabledByUserInput`, **not** the `...ByTimeout` (4294967294)
that three earlier investigations chased. Why the system disabled it
remains unexplained; what is fixed is that our response no longer harms
the machine.

**Working until:** unknown — the breaker has been present since
2026-08-11 and this is the first time it has been seen to trip.
