# Fable — taste round 2 is ready to run. Here is what changed and what we need judged

Open `/Users/abhishektigga/Documents/Dictation/Sayline`, branch `main`,
commit `08a13a9`. Read `review/LEDGER.md` from the entry **"WORK MODE ·
Phase B closed, Phase C decided"** to the end — three entries, all from
2026-08-14.

The user runs the round. This prompt is so you know what you are reading
when the results arrive, and so the things we are least sure about get
looked at by someone who did not build them.

## What changed since round 1

Round 1 baseline, for comparison: **5.6% send-unedited (1 of 18)**, 3.37 s
median, retry on roughly half.

- **Prompt rebuilt** from the fifteen ideals (Phase B). Openers, positions
  and hedges are now protected explicitly; list intros are required.
- **Model is `gpt-4.1-mini`**, not `gpt-4o-mini`. Ties on violations and
  latency, but never falls back — 4o-mini silently delivered Clean on 3%
  of work dictations.
- **The ceiling has your +2 grammar tolerance.**
- **Eight `FactGuard` false-positive classes fixed** this week: scale
  words, digit list markers, unit adjacency, `"half"` as a quantity,
  negation-by-paraphrase, the retraction marker counted as a negation,
  plus the earlier name and equal-length work.
- **Few-shots rejected** on your pre-committed bar: 8 points behind bare,
  82 ms slower, +59% input tokens. Criterion 4 closed as "bare prompt,
  few-shots rejected on cost".
- **The checklist now keeps its answers.** Export downloads a file, and
  the page objects before a close that would discard unexported marks.
  Round 1's results existed only in localStorage and one clipboard copy,
  which is why reconstructing them cost a session.

Where the machine now sits: **100% sendable on the 13 auto-runnable
scripts**, and 14/15 on the calibration set with one argued residual.
Which is precisely why round 2 matters — the mechanical scorer has run out
of things it can see.

## The one thing we most want checked

**Every guard change this week made it more permissive. Six rules relaxed,
none tightened.** Each relaxation was justified individually — every one
was flagging a rewrite the user had personally accepted — but the
direction never reversed, and a set of individually-sound loosenings can
still overshoot in aggregate.

The failure this would produce is the quiet one. A false alarm is visible:
the user sees a fallback. A missed invention is invisible: it reads well
and goes into someone's inbox with the wrong number in it.

So the round-2 protocol now asks the user to check **every number, name,
day and time against what they actually said**, and to tag `fact wrong`
independently of how the text reads. When the results come back, we would
like that column read first and separately from the taste verdict. A round
that scores 80% sendable with two invented facts is a worse outcome than
one that scores 60% with none.

## What we need you to rule on

**1. Did the loosening go too far?** The evidence will be the `fact wrong`
tags. If any appear, we would like to know which specific rule to tighten
— each change has its own suite case, so a reversal is surgical.

**2. Is the calibration set compromised, and what replaces it if so?** This
is the methodological problem and it is ours. We changed the guard until it
stopped rejecting the fifteen ideals, then made those same fifteen the
permanent test that the guard is correct. That is fitting to the test set.
It still catches future regressions, but it can no longer independently
confirm that this week's changes were right, and we have no second set. If
you think round 2's output should become a held-out set rather than being
folded into calibration, say so before we fold it in.

**3. Was `grammarTolerance = 2` the right integer?** We implemented 2
because you ruled 2, and the suite pins it. But the data does not actually
distinguish it: the violations sit at +1, +3 and +5, and nothing sits at
+3 or +4 in the accepted rewrites. So 3 would have produced the same
outcome on everything measured except real-6. If round 2 shows length
complaints in either direction, this is the knob.

**4. The gate for round 2 itself.** We have not set one, deliberately —
round 1's 5.6% is the only baseline and we would rather you named the bar
than have us pick a number our own changes are likely to clear. Ours would
be: ≥60% send-unedited, zero invented facts, and no case where the
fallback fires silently.

## What to ignore

`R1` and `R2` are not scripts. They are directions to the person testing
("speak T2's status update again, from memory"), and they measure the
speaker's consistency across two runs of the same thought. Only a human
can run them. An earlier harness of ours fed them to the model, which
dutifully rewrote the instruction and invented a month and a name doing
it — if you see anything odd attributed to those two, that is the cause.

`N3` is a known calibration residual with a reason recorded in
`taste_score.py`: the accepted rewrite writes "₹45,000" for a transcript
that names no currency, and letting that pass means letting rewrites
introduce currency symbols.

## Ground rules

Unchanged. Nobody marks their own work verified. Everything from this week
is `claimed-fixed`; the model switch, the tolerance and the few-shot
rejection have all been measured but only by us.

Two instruments produced most of the numbers above and both are ours: the
taste scorer and the calibration set. If the round-2 results disagree with
what the scorer predicted, trust the user and tell us the scorer is wrong
— that is the more likely explanation, and it is the one we are least
able to see.

Write your ruling into `review/LEDGER.md` in the existing style.
