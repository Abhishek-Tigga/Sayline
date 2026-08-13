# Fable — everything since your stage-6 review. Nine commits, one still-open freeze.

Open `/Users/abhishektigga/Documents/Dictation/Sayline`.

Your last review answered `review/FABLE-PROMPT-workmode-complete.md`, at
commit `ee61cce`, before any human had used work mode. Since then it has
been used, six live failures were found and fixed, the rewriting model was
changed on eval evidence, and the build's signing identity changed.

Everything below `ee61cce` in `git log` is unreviewed:

```
24177b4  Fix the freeze the circuit breaker caused, and swap double-tap for a chord
86639ec  Record the unexplained tap-disable as an open problem
d1e976d  Fix the Settings crash: stop the hosting view fighting a fixed window
523fadb  Fix the dictated-list and history-badge fails; instrument the settings flip
477690a  Voice 2: enforce it mechanically, and change model because of it
fe32e48  Keep the sentence that introduces a bulleted list
b22cad7  Correct the model doc comment, which still named the old model
f3f568d  Heal the stale keychain entry, and record that the freeze outlived its fix
c15915c  Sign the build with a stable identity so rebuilds stop resetting grants
```

Read `review/LEDGER.md` from `## 2026-08-13 — Fable's stage-6 items built`
(line ~3366) to the end. It is in build order and records what was claimed
versus what was verified.

## 1. The one that matters most: the keyboard still freezes

The user's whole keyboard locks up mid-session. This outranks everything
else in this document — it is the only bug that makes the machine unusable
rather than the app.

**What was fixed, and it genuinely was.** The circuit breaker called
`tapEnable(false)` from inside the event-tap callback, re-entering itself
24,884 times. It is now idempotent (`guard !tappedOut`). Evidence from one
log: the 24,884-iteration storm sits at 21:57, before the fix; after it, at
23:43, there are **two** disables twenty seconds apart, each followed by a
clean `event tap re-enabled`, breaker never tripped.

**The keyboard froze anyway.** So the loop was an amplifier, not the cause.

**The one new fact, which points away from the previous theory:**

| incident | disable code | meaning | main thread |
|---|---|---|---|
| 21:57 | 4294967295 | `kCGEventTapDisabledByUserInput` | `main ok 0.0s` |
| 23:43 | 4294967294 | `kCGEventTapDisabledByTimeout` | `main ok 0.0s` / `0.7s` |

Two different disable codes, two incidents, same day, healthy main thread
both times. Whatever removes this tap can do it two ways.

What we want from you: a **mechanism**, not a mitigation. We can already
re-enable the tap; that is not the problem. The questions are what disables
it, why a timeout fires when the main thread is provably not stalled, and
whether a tap on a dedicated thread with our callback shape can be starved
in a way our `main ok` heartbeat cannot see. If you think the heartbeat is
measuring the wrong thread, say so — that would mean our evidence is
worthless and we would rather know.

Relevant: `Sources/Sayline/HotkeyManager.swift`, and the OPEN entry
`## 2026-08-13 — freeze recurred; the loop fix held, the cause did not`.

## 2. The model change — please attack the evidence, not the conclusion

`WorkModeCleaner` moved from `llama-3.3-70b-versatile` to `gpt-4o-mini`.
The reasoning is in the file's doc comment and in the ledger. Short version:
Voice 2 added a hard length ceiling, and under it the 70B rescued **0 of 7**
of its own violations, against 83% under the earlier free-rewrite prompt.

This decision costs 631 ms per dictation and moves work mode off Groq onto
OpenAI. It was made on 31 transcripts, ten of them real. We think that is
thin. Specifically we would like you to check:

- Whether "cut, don't pad" plus a hard ceiling is a prompt failure we
  mistook for a model failure — i.e. whether the 70B recovers under a
  differently-worded ceiling.
- Whether `FactGuard.longerThanSpeech` (`ceiling = spokenWords < 10 ?
  spokenWords : spokenWords - 1`) is even the right rule. It is the rule
  that produced the 0-of-7, so if the rule is wrong the model change was
  wrong too.
- Six of the 31 cases are Voice-2-style transcripts we wrote, not dictated.
  The ledger labels them as such. Say if that invalidates the comparison.

Files: `Sources/Sayline/WorkModeCleaner.swift`, `Sources/Sayline/FactGuard.swift`
(~102 cases in `eval/factguard-checks/main.swift`), `eval/work-mode/run.py`.

## 3. The prompt fought the guard twice — is the architecture wrong?

Twice now, a rewrite was blocked because the prompt and the guard disagreed
about the same words: "first/second/third" pinned as numbers, then "second"
pinned as a time unit. The second was our implementation error — your rule
was "pin the unit token adjacent to each number", and bare set membership
had been implemented instead.

But two of the same class of bug suggests the split itself may be the
problem: a probabilistic rewriter and a deterministic verifier that each
hold their own idea of what a fact is. Is there a shape that cannot drift
like this, or is this the cost of the design and we should just expect it?

## 4. Voice processing is parked — confirm the exit was right

`setVoiceProcessingEnabled` was going to isolate the user's voice from
playing music. It ducked all system audio by ~43×, and `duckingLevel: .min`
did not stop it. It is parked (`voiceProcessingWanted = false`) per your
pre-written exit criterion.

The user's standing instruction is: **"We should not modify the user's
system in order to fit our purpose."** If there is an approach that isolates
the mic without touching what the user hears, we want it. If there is not,
say so plainly and we will stop looking.

`Sources/Sayline/AudioRecorder.swift`.

## 5. Code quality and simplification — a standing request

The user's words: *"I want to keep things simple in the code base level."*
They are a PM learning to code hands-on, so complexity they cannot read is a
real cost, not a stylistic one.

Please flag: duplicated logic, files doing more than one job, anything a
newcomer would misread, and anything that has grown past the point where its
comments still describe it. Concrete "delete this, merge these two" beats
general advice.

## 6. Anything that can make dictation fail

Standing instruction from the user, repeated across reviews: **if any
feature can cause a dictation to fail, name it and rate the severity.** We
will remove a feature over losing a dictation. Say which ones you would cut.

## What is NOT verified — do not assume it works

Honesty about our own state, so you spend attention in the right place:

- **The signing fix is unproven.** `c15915c` stops ad-hoc signing, so
  rebuilds should stop resetting Accessibility, Microphone and the Keychain.
  The requirement no longer contains the cdhash — that much is verified. That
  the grants actually survive a rebuild is **not**; the test has not been run.
- **These live checks are still owed:** C1 (Slack register), D1/D2 (code
  window), E6 (fallback flash), F3 (follow-up ignores chord), G1/G2 (speed,
  cold start), and re-tests of A6 (settings flip), B2 (bullets), H1 (history
  badges).
- **A6 is not fixed**, only instrumented.
- The six Voice 2 worked examples never made it out of your session; the
  ledger substitutes six real transcripts and labels them as substitutes.

## Ground rules

Same as before. Nobody marks their own work verified — including us, which is
why the list above exists. If a ledger entry claims something is fixed and
the code does not support it, say so and quote both. If you think an earlier
decision of yours was wrong given what the live sessions showed, say that
too; four of the six live failures came from decisions that read fine on
paper.

Write your review into `review/LEDGER.md` in the existing style.
