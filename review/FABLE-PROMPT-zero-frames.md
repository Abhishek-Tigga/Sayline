# Fable — the microphone captures zero frames

Open `/Users/abhishektigga/Documents/Dictation/Sayline`.

Dictation is completely dead. Every recording captures `frames: 0`. This
blocks all live testing of everything else, so it is the only thing that
matters right now.

I have been wrong about the cause twice. Treat my reasoning below as
evidence to check, not as a starting point to build on.

## What is measured

**Sayline captures nothing.** Every hold:

```
recording started on MacBook Air Microphone at 16000 Hz -> /var/.../sayline-*.wav
recording stopped -> ... duration: 1.46s frames: 0
no audio captured from MacBook Air Microphone over 1.46s — mic authorized: true
```

**The microphone works.** A standalone `AVAudioEngine` in a *different*
process, on the same machine, at the same moment, on the same device:

```
input format: 16000.0 Hz, 1 ch
frames captured : 48000
peak amplitude  : 0.021846812
```

Same 16 kHz mono format Sayline reports. That probe is at
`/private/tmp/claude-501/-Users-abhishektigga-Documents-claude/5a23ba11-61a3-493f-b07c-2e5632c99937/scratchpad/mictest.swift`.
It does the minimum: `engine.inputNode`, `installTap`, `engine.start()`.

**It is not permission.** `AVCaptureDevice.authorizationStatus(for: .audio)`
returns `.authorized`, logged on the failing line itself. The user has
granted Microphone in System Settings. My first theory was that the
rebuild had lost the grant — wrong, and the log now disproves it.

**It is not the hardware.** `system_profiler` lists MacBook Air Microphone
normally, and the standalone probe records through it.

**It is not a recent code change to the recording path.** `git diff
c5ae98c..HEAD -- Sources/Sayline/AudioRecorder.swift` is one read-only
computed property. Dictation demonstrably worked on build `c5ae98c` at
20:13 today (transcripts in the log). The only *code* commit between that
and the first zero-frame recording at 22:22 is `7dcd0e5` (media control),
which adds `NowPlaying.swift` and `MediaControl.swift`. Neither is called
at launch, and no media command ever ran successfully — but `NowPlaying`
does use CoreAudio (`kAudioHardwarePropertyProcessObjectList`), so it is
not automatically innocent. Worth checking whether merely linking or
touching that API can affect the process's audio state.

## Possibly relevant, possibly a red herring

While probing media control I ran several audio experiments on this
machine with Sayline running: `afplay`, QuickTime, a `WKWebView` playing
video, and repeated enumeration of CoreAudio process objects. One earlier
Sayline recording used a device named `CADefaultDeviceAggregate-61109-0`,
which is macOS creating an aggregate device — not something Sayline asks
for. Restarting Sayline has not cleared the condition. A wedged per-client
coreaudiod state is a candidate, but that should not survive a process
restart, which argues against it.

## What to look at

`Sources/Sayline/AudioRecorder.swift`, `start()` and `stop()`. The shape:

- one long-lived `AVAudioEngine` property, reused across every recording
- `discardLastRecording()`, then `engine.inputNode`
- optional `setInputDevice(deviceID, on: input)` when a preferred device
  UID is stored — note `preferredInputDeviceUID` comes from user defaults
  and may be pinning a device that no longer exists (an iPhone microphone
  is listed in `system_profiler` on this Mac)
- `installTap(onBus: 0, bufferSize: 1024, format:)`
- `try engine.start()`
- `stop()` does `removeTap` then `engine.stop()`

Candidate mechanisms I have not ruled out, in no order: the engine being
left in a state where `start()` is a silent no-op; a tap installed on a
bus that already has one; `outputFormat(forBus: 0)` disagreeing with
`inputFormat(forBus: 0)` after a device change; the input node never being
pulled because nothing is connected in the graph; `setInputDevice` pinning
a dead device while `currentInputDeviceName()` reports the default.

## Diagnostics already in the build

Commit `HEAD` adds temporary `[mic]` logging, and a build with it is
running now. It records the engine's running state before `start()`, both
node formats, whether the tap fires **at all**, and the first buffer's
frame count and peak. The user has been asked to hold the hotkey.

If those lines are in `/tmp/sayline.log` or
`~/Library/Logs/Sayline/sayline.log` by the time you read this, they
answer the central question — tap firing with silent buffers is a
completely different bug from a tap that never fires — so read them before
theorising.

## Rules

Every rebuild changes the ad-hoc signature and costs the user their
Accessibility **and** Microphone grants, so experiments are expensive to
them. Prefer a single build that distinguishes several hypotheses over a
sequence of one-shot guesses.

Append to `review/LEDGER.md`. You may mark your own work `claimed-fixed`,
never `VERIFIED`.
