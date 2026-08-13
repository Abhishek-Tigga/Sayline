# Fable — work mode is built, six stages. Review before it is used.

Open `/Users/abhishektigga/Documents/Dictation/Sayline`.

All six stages of the work-mode build order are complete and committed.
**Nothing has been used by a human yet** — the double-tap has never been
pressed, and no rewrite has reached a text field. This is the review
before that happens, not after.

Read in order:

1. `DESIGN-work-mode.md` — the eight decisions, **including the amended
   decision 2** (accepted by the user 2026-08-13: quantifiable inventions
   caught mechanically, qualitative ones bounded not eliminated).
2. `review/LEDGER.md`, entries from "work mode stage 1" onward — the
   claim/verify record, in build order.
3. `Sources/Sayline/FactGuard.swift` and `eval/factguard-checks/main.swift`
   (73 cases).
4. `Sources/Sayline/WorkModeCleaner.swift`.
5. `Sources/Sayline/HotkeyManager.swift` (double-tap) and
   `AppDelegate.swift` (`isWorkModeThisRecording`, the work branch,
   `finishDictation`).

## The one you were asked to fix

The user's instruction was explicit: flag it, keep building, let Fable
propose the fix at this review. It is in the ledger under
**"OPEN FOR FABLE · The rhetorical-question invention"** with
reproduction, and it is the highest-value item here.

Work mode turns a rhetorical question into a self-contradictory claim,
and the guard passes it because the invented sentence carries no number
or date:

```
said : "...move it to Friday morning like 11ish.
        Doesn't that work for you or is Friday bad?"

chat : "...Friday morning at 11 won't work if you have a conflict,
        but it's an option."                            [guard: clean]
email: "Friday is not confirmed as a suitable alternative, as it is
        not known if it works or if Friday is bad."     [guard: clean]
```

Two starting points are recorded in that entry, including that the
rejected sentence-novelty gate deserves reconsidering — it was rejected
for having no positive control, and these two sentences **are** that
control. Take them or discard them.

## What to review, beyond that

**The guard.** 73 cases. What can a rewrite still break that they do not
catch? That question found four real bugs last time and is the one worth
your time.

**The double-tap, which touches the product's spine.** The recording path
broke six times in one day (see `DICTATION-HISTORY.md`). The design:
`onWorkModeHold` fires *after* `onHotkeyDown`, never instead, so the
first press starts recording instantly and nothing waits to learn whether
a second tap is coming. Check the state machine for holds that could
strand `isWorkModeThisRecording` — the flag is captured into a local
before the async work so a later hold cannot change an in-flight one, but
I would rather you tried to break it than take my word.

**Work runs after Clean, not instead of it**, because Clean's output is
the fallback the guard falls back *to*. That means a work dictation pays
both round trips. Is that the right shape, or should the fallback be
computed lazily only when needed?

**The 350 ms window** is the design's starting value, untuned by feel
because nobody has pressed it yet.

**Latency has a real gap, recorded not designed around:** first work
rewrite of a session measured 5913 ms (connection setup), then 191–607 ms
warm. Decision 7's budget is Clean + ~1 s, which the warm path meets and
the first dictation of a session does not.

## What is verified and what is not

Verified: all eight check suites green; the five-hold capture smoke test
passes (238/89/95/91/118 ms, full window, real audio); `git diff` over
`TranscriptCleaner.swift` and `TranscriptCleanupValidator.swift` is
**empty**, so Clean is byte-identical; an old `HistoryEntry` still
decodes without the new `mode` field.

Not verified by its author: no human has pressed the double-tap, seen the
pill chip, flipped the Settings default, or read a work rewrite in a real
text field. No judgement of rewrite *quality* beyond five samples.

One thing worth knowing about how these numbers were obtained: the smoke
test failed first at `hold 1: 1696 ms` against a 214 ms baseline, and
three re-measurements gave 255/255/238 ms. Recorded as an outlier rather
than explained away — challenge that call if you think it was too quick.

## Constraints, unchanged

No LLM in the guard path. Every stopword or lexicon addition arrives with
the real transcript that motivated it, as a suite case, in the same
commit. Append to `review/LEDGER.md`; `claimed-fixed` only.

## Reproducing

```bash
swiftc -o /tmp/fgchk Sources/Sayline/FactGuard.swift \
  eval/factguard-checks/main.swift && /tmp/fgchk         # 73 cases
Sayline --work-rewrite "<transcript>" --context chat|email|code|general
Sayline --selftest-capture 3 5                            # capture contract
python3 eval/work-mode/run.py                             # the bake-off
```
