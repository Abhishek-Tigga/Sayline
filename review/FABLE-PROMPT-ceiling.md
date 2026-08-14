# Fable — rule on the length ceiling. Two independent lines say it is ~2 words too tight

Open `/Users/abhishektigga/Documents/Dictation/Sayline`, branch `main`,
commit `2c6cde2`. Read `review/LEDGER.md`, the entry **"WORK MODE · Phase B
closed, Phase C decided, and two guard bugs the ideals found"**.

This is one decision, and it is yours because the ceiling is your Phase A
call and a suite case pins it deliberately. We did not touch it.

## What landed, so you are not re-checking it

- **Two `FactGuard` bugs**, both found by scoring the user's fifteen
  accepted rewrites against our own rules. Scale words ("forty five
  thousand" → "45,000" scored as the number both lost and invented) and
  digit list markers ("1. / 2. / 3." as invented numbers). Ten new suite
  cases. **One of these had already cost a decision of yours**: Phase C
  measured gpt-4.1-mini at 19% and rejected it. The real number was 10%.
- **Few-shots measured and rejected.** 30% sendable against 69% bare, no
  latency saved, +59% input tokens. Detail below, because it is coupled
  to your ruling.
- **Model switched to gpt-4.1-mini.** 10% broke, 100% rescued, 0%
  fallback, 1092 ms — against 4o-mini's 10% / 67% / 3% / 1087 ms.
- 7/7 deterministic suites green.

## The evidence

### 1. The rule rejects the target

Four of the fifteen rewrites the user accepted exceed the ceiling, taking
the **shorter** variant where they gave two. All four are Slack:

```
N1  said 53  ideal 54   +1
T2  said 44  ideal 46   +2
N2  said 34  ideal 36   +2
E2  said 39  ideal 53   +2 over the 51 the +12 email allowance gives
```

### 2. It is now the only class left

After the guard fixes, **every remaining violation across the 31
transcripts, on both candidate models, is `longer-than-speech`.** Nothing
else fires. Three cases, quoted in full because the ruling turns on what
they actually did:

```
made-13   said 23 → wrote 24   (+1)
  said : ...feels like a lot of meetings for not much
  wrote: ...It feels like a lot of meetings for not much.

real-6    said 37 → wrote 40   (+3)
  said : So realistically end of next week not this week
  wrote: Realistically, it will be done by the end of next week, not this week.

made-11   said 32 → wrote 37   (+5)
  said : the front end is maybe two more days
  wrote: The front end will take maybe two more days
```

**All three are the same edit: a spoken fragment becoming a grammatical
sentence.** made-13's entire violation is the word "It". Speech is
elliptical and writing is not, so closing the ellipsis costs words — and
closing it is the job. The register already says context may decide
"whether sentences are complete", which means the prompt asks for the very
thing the ceiling charges for.

### 3. The prompt mandates an increase the ceiling then penalises

real-6's transcript contains `70%` — one word. The prompt says:

> Leave figures alone when they are data: "70 percent", "47,500", "11am".

`70 percent` is two words, and it is the prompt's own worked example. So
on this transcript the prompt requires +1 word and the ceiling counts it
as padding. That is not a judgement call about taste; the two rules
contradict mechanically.

### 4. What a tolerance would cost

Sweep over both datasets. Ideals are the fifteen accepted rewrites
(shorter variant, +12 email allowance applied); transcripts are the 31 as
rewritten by gpt-4.1-mini:

```
tolerance        ideals over   transcripts over
none (today)        4/15            4/31
+1 word             3/15            2/31
+2 words            0/15            2/31
+3 words            0/15            1/31
5%                  2/15            2/31
10%                 0/15            1/31
20%                 0/15            0/31
```

Caveat on that column: the sweep counts whitespace words, the guard
tokenises slightly differently, so it reads 4/31 where the guard fires 3.
It over-counts, never under-counts — the shape holds, the last digit
should not be quoted.

**+2 words clears every accepted rewrite** and leaves the two genuinely
longer transcript cases still flagged. 10% does the same with one fewer.
20% clears everything, which is probably too much — made-11's +5 is the
one case where "is maybe two more days" → "will take maybe two more days"
starts to look like prose rather than grammar.

## The decision we want

**Which, and why:**

1. **A small fixed tolerance (+2 words), Slack and email alike.** Our
   preference. It is the smallest change that stops rejecting the target,
   it keeps the rule mechanical and explainable, and it still catches the
   +5 case. Fixed rather than percentage because the failures are
   grammatical repairs, which cost roughly a constant, not a proportion.
2. **A percentage (10%).** Scales with utterance length. Harder to explain
   in a comment, and on a 12-word Slack line 10% is one word, which is
   where the repairs actually happen.
3. **Leave it.** Defensible: the ceiling exists because Voice 2 padded,
   and 3/31 is a low false-positive rate to buy that protection with. If
   this is the ruling, we would like the ideals' 4/15 explicitly accepted
   as tolerable, since it means the guard rejects text the user approved.
4. **Something else** — in particular, if you think the right fix is to
   exempt grammatical completion rather than to loosen the count, we have
   not found a mechanical way to detect it and would want your shape.

**If (1) or (2), one consequence to rule on at the same time.** The
few-shots were rejected *for* teaching length: every extra failure in that
arm was `longer-than-speech`, from examples drawn from ideals that
themselves exceed the ceiling. If the ceiling moves, that result is no
longer sound. Do you want `taste_run.py --shots` re-run under the new
ceiling before few-shots are treated as settled, or does the +59% token
cost close it regardless of score?

**And one that is not ours.** `eval/factguard-checks/main.swift` asserts
`"one word longer still is padding"`. That case is deliberate and it
encodes your Phase A decision. Any tolerance means rewriting it. We have
not, and will not without your ruling.

## Ground rules

Unchanged. Nobody marks their own work verified. The guard fixes and the
model switch are `claimed-fixed`; the ceiling is recorded as `disputed`
rather than quietly loosened.

Two things worth your scepticism specifically. The taste scorer
(`eval/work-mode/taste_score.py`) is ours and it is the instrument
producing half the numbers above — it checks stated rules, not whether the
user would send the text, and it calibrates at 11/15 against the ideals
themselves, so 100% is not the top of its scale. And we rejected few-shots
on a single 13-case comparison; if you think that is too thin a basis to
close Phase B's fourth criterion, say so.

Write your ruling into `review/LEDGER.md` in the existing style.
