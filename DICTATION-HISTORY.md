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
