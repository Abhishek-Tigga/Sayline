# Fable — the user has ruled; two things are still yours

**Decision, by the user, 2026-08-14: keep self-correction. Option 1.**
The three corrections resolve; A3's lost comma is accepted. Nothing is
deleted by it — the validator restores the words — so the cost is
untidiness, not data loss, and the user judged that trade worth taking.

That closes the question this document was written to ask. The evidence
below stands as the record of what it cost, and **two things are still
open for you**: the tripwire process point at the end, and whether the
70B is worth revisiting now that it is the plausible fix for A3 as well
as the loser of a latency race by 52 ms. Neither blocks anything.

---

# Original ask, kept as the record: is self-correction worth what it costs A3

Open `/Users/abhishektigga/Documents/Dictation/Sayline`, branch `main`,
commit `9983d82`. Read `review/LEDGER.md` from **"CLEAN MODE ·
Improvement round built"** to the end — three entries, all 2026-08-14.

We are asking for a ruling instead of a round. Clean round 2 would put
eighteen cases in front of the user to answer one open question, and the
other seventeen are already measured. If you would rather see the round
first, say so and it runs.

## What landed, so you are not re-checking it

- **The punctuation diagnosis was wrong.** Round 1 read it as small-model
  behaviour and made a model A/B the headline. It was `smooth()` in
  `TranscriptCleanupValidator`, deleting every comma and semicolon before
  a lowercase word — which is where commas live. Fed the user's own
  expected output, the validator stripped the commas back out.
- **The A/B ran and inverts.** 8B scores 7/8 on punctuation at 203 ms
  median; 70B scores 6/8 at 327 ms with **p90 552 ms**, over the 500 ms
  lock. 8B stays.
- **Grammar policy is code, after validation.** Every FIX deletes a word,
  so the validator was reverting them — observed live, "inform both
  teams" restored to "inform the both teams". `SpeechPatterns` runs on
  the validated string, so the never-lose-a-word contract is untouched.
- **Clock times and "Finance" ruled in by the user** since.
- **Scoped self-correction is built**, reusing `FactGuard`'s marker gate.
  All five frozen C-outcomes land; both added safety controls hold.

Per workstream, against the user's expected outputs:

```
punctuation        2/7  ->  6/7
grammar policy     2/7  ->  7/7
numbers + times    3/5  ->  5/5
self-correction    5/7  ->  7/7
TOTAL             12/26 -> 25/26
```

9/9 suites green, work-mode calibration 14/15 unchanged, speed lock at
283 ms median / 411 ms p90.

## The one open thing

The resolution instruction makes the 8B **delete "No rush"** from A3:

```
raw      : did you get a chance to look at the PR I pushed last night
           no rush just checking
model    : Did you get a chance to look at the PR I pushed last night?
           Just checking.
validated: Did you get a chance to look at the PR I pushed last night?
           no rush just checking.
round 1  : Did you get a chance to look at the PR I pushed last night?
           No rush, just checking.
```

**Nothing is lost** — the validator catches the over-deletion and restores
the words. The cost is that they come back without the capital and the
comma, so a sentence that was correct at baseline is now untidy. One case
class: phrases opening with a bare "no".

## The evidence, one variable at a time, temperature 0

```
prompt variant                          A3        C1        C3
full, as built                          DROPS     ok        ok
minus the two reason-judgment lines     DROPS     ok        ok     <- your retreat
minus the whole self-correction block   KEEPS     n/a       n/a
narrower "same kind" formulation        DROPS     BREAKS    ok
```

Three things follow, and the second is the one we most want you to see.

1. **The cause is the resolution instruction, not the reason judgment.**
2. **The pre-agreed retreat is ineffective.** "Delete the two
   reason-judgment prompt lines and collapse to minimal intensity" was
   the one-line, no-debate exit. Measured, it changes nothing about A3.
   The only variant that restores A3 removes the feature entirely.
3. **A prompt fix was tried and failed.** The marker list was tightened
   to exact phrases and told, in those words, that "no rush", "no
   problem" and "no worries" are ordinary and must stay. The model
   dropped "No rush" anyway. The narrower formulation then broke C1.

So: the 8B does not hold "resolve self-corrections" and "do not touch
phrases starting with no" at the same time, across four attempts.

## Why we did not retreat

Your tripwire's conditions are C1 and C3 wobbling at temperature 0, or a
live round producing a wrongly-dropped reason. Neither has fired: C1 and
C3 are stable on the shipped configuration, this is not a live round, and
"No rush" is a softener, not a reason clause. Pulling a pre-agreed trigger
on a condition that has not fired, using a mechanism now measured not to
work, seemed worse than recording it and asking.

If you read the tripwire as already met in spirit, say so and it goes.

## The decision we want

**Which, and why:** — *answered by the user: 1.*

1. **Keep it, accept the A3 cost.** ← **CHOSEN** C1/C2/C3 resolve, which is the
   feature the user approved over seven worked examples; the price is one
   sentence class landing untidy, with nothing lost. Our lean, weakly.
2. **Remove self-correction.** The only measured fix. Costs the whole
   feature to buy back one comma, but it is the honest reading of "this
   change made something worse than baseline".
3. **Revisit the latency lock so the 70B can take it.** The 70B lost the
   A/B on p90 (552 ms against 500 ms) and nothing else. It is now also
   the plausible fix here, which makes this a second independent reason
   to look at that trade rather than a settled matter. We have not tested
   the 70B against A3 — say the word and we will, before you rule.
4. **Something else.**

**A process point worth your attention regardless.** This is the first
pre-agreed tripwire in this project measured to be ineffective. It was
written naming a specific mechanism ("delete the two lines") rather than a
specific outcome ("A3 must keep No rush"), and the mechanism turned out
not to reach the cause. Whether future tripwires should be written as
outcomes with the mechanism left open is your call, but it seems like the
kind of thing that only shows up once and then never again if it is
written down.

## Ground rules

Unchanged. Nobody marks their own work verified. Everything above is
`claimed-fixed` and measured only by us. Two instruments produced most of
the numbers and both are ours: `eval/clean-mode/run.py` and the
per-workstream scoring against `round1-baseline.json`.

Also out of scope and untouched, so you are not looking for them:
paragraph breaks (D2 still unrun), emoji, Whisper vocabulary biasing —
whose evidence pile now includes D1, confirmed from the raw log as a
mishear rather than a cleanup mangle.

Write your ruling into `review/LEDGER.md` in the existing style.
