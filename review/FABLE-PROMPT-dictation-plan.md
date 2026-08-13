# Fable — dictation is broken and my fixes keep breaking it differently

Open `/Users/abhishektigga/Documents/Dictation/Sayline`.

**Give a plan, not a patch.** Three consecutive fixes from me have each
resolved the reported symptom and introduced a new one, in under 24 hours,
on the single path this product exists for. The next change should be
chosen deliberately, and the first question to answer is whether to keep
the feature that started this at all.

Read `DICTATION-HISTORY.md` first. It is the running record of every
failure on the hotkey-to-text path, with causes and what was working
immediately before each one.

## The chain, in order

Each fix was verified before shipping and each one broke the next thing.

**1 · Dictation transcribed YouTube lyrics** (2026-08-12). Built-in
speakers reach the built-in microphone. First fix — pausing audible media
for the length of each hold — worked and was rejected by the user as a bad
experience. Replaced with `AVAudioInputNode.setVoiceProcessingEnabled(true)`,
Apple's echo cancellation. Measured: speaker bleed peak 0.8085 → 0.0230,
a 97% reduction, music untouched. That measurement is real and repeatable.

**2 · Dictation completely dead, no permission prompt** (2026-08-13
~14:21). `setVoiceProcessingEnabled(true)` *succeeded*, then
`engine.start()` failed with `-10875` from the **output** node —
`PerformCommand(*outputNode, kAUInitialize)`. Voice processing couples
input to output; the output device presented a layout it could not
initialise. No engine meant no audio was ever requested, hence no
microphone prompt. My "fails open" guard only covered
`setVoiceProcessingEnabled` *throwing*, which is not what happened.
Fixed by making it an attempt with a fallback to processing-off.

**3 · First hold worked, every later hold captured zero frames**
(~14:26). `failed to set preferred input device -> status -10851`, then
`recording started on unknown (id 0)`, `tap fired 0 time(s)`. Voice
processing binds the input node to a private aggregate device
(`CADefaultDeviceAggregate-68355-0`, visible in the log one hold earlier);
setting `kAudioOutputUnitProperty_CurrentDevice` on that aggregate fails
**and leaves the unit with no device**, which starts cleanly and records
silence. Fixed by setting the device on a plain unit — processing off,
device set, processing on — and skipping it entirely when the requested
device is already the system default.

**4 · Current symptom: recordings truncated to a fraction of the hold.**

```
14:32:54.398  hotkey DOWN
14:32:54.830  voice processing turned off        (+432ms)
14:32:55.532  voice processing enabled          (+1134ms)
14:32:55.579  recording started                 (+1181ms)
14:32:56.046  hotkey UP
              recording stopped ... duration: 0.4777s frames: 19200
              [mic] tap fired 4 time(s)
```

The device bug is genuinely fixed — the tap fires, frames are captured,
`audio peak 0.9171946 -> has speech`. But fix 3 toggles voice processing
off and back on **on every hold**, and that costs ~1.1 seconds. The user
speaks into a microphone that is not yet listening. Earlier holds produced
`duration: 0.006s` and `0.268s`.

**5 · Also present, probably unrelated:** `transcription failed -> The
request timed out.` twice in a row at 14:33. Groq, network, or a
consequence of tiny audio files. Not diagnosed. Say if it should be.

## The question I want answered first

**Should voice processing be reverted entirely?**

The case for keeping it: it is the only mechanism that solves speaker
bleed without pausing the user's music, and the 97% measurement holds.

The case against: it has now caused three distinct failures of the core
feature in one day — an engine that will not start, a node with no input
device, and a one-second startup cost. Each fix for it has been correct
and has exposed the next problem underneath. The bug it solves — lyrics
occasionally polluting a transcript — is far smaller than dictation not
working.

A middle path exists and I have not evaluated it: enable voice processing
**once** at launch, never toggle it per hold, and never pin an input
device while it is on. That removes the per-hold cost and the aggregate
conflict, at the price of a fixed setup that cannot adapt when devices
change mid-session.

I do not want my judgement on this to be the deciding one. Pick, and say
why.

## Constraints that shape the plan

- **This Mac's audio environment is unstable and is part of the story.** A
  duplicated Bluetooth device (`Bass Baggie` listed twice), a Continuity
  iPhone microphone, a BenQ monitor, and a `Microsoft Teams Audio` virtual
  driver. Several failures trace to device churn rather than to our code.
- **`AudioRecorder` runs all engine work on a private serial queue** since
  2026-08-12, when `outputFormat(forBus:)` on the main thread deadlocked
  the whole app — probably the long-standing freeze, four incidents, three
  disproven theories. **Do not propose moving engine work back to main.**
- **Every rebuild costs the user their Accessibility and Microphone
  grants** (ad-hoc signing changes the cdhash). Experiments are expensive
  to them. Prefer one build that separates several hypotheses.
- The pinned input device in Settings is `BuiltInMicrophoneDevice`, which
  is already the system default — so the device-pinning code was fighting
  for something it would have got for free. Consider whether per-device
  pinning earns its place at all.

## What I want back

1. **A decision on voice processing**: keep as-is, keep with the
   launch-once shape, or revert — with the reasoning.
2. **A sequenced plan** for the rest, ordered by what unblocks the user
   fastest, saying for each step what must be proven before the next.
3. **What to verify and how**, given experiments cost the user their
   permissions. Name the measurement, not just the intent.
4. **Where I went wrong as a process**, not just in the code. Three fixes,
   three new failures, each shipped with a verification that looked
   adequate. Something about how I am checking these is not working, and I
   would rather hear it plainly.

## Where things are

- `Sources/Sayline/AudioRecorder.swift` — the whole capture path
- `DICTATION-HISTORY.md` — every failure, cause, and prior state
- `review/LEDGER.md` — the running claim/verify record; append here, and
  you may mark your own work `claimed-fixed`, never `VERIFIED`
- `/tmp/sayline.log` and `~/Library/Logs/Sayline/sayline.log` — live logs,
  including the `[mic]` diagnostics quoted above
- `scratchpad/mictest.swift` — a standalone `AVAudioEngine` recorder, the
  control that proves whether a failure is Sayline's or the machine's
