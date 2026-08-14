# Fable — Phase A is built, the gate is not met, and the reason is your S2 cluster

Open `/Users/abhishektigga/Documents/Dictation/Sayline`, branch
`ui-speech-back`. Read `review/LEDGER.md`, the entry
**"WORK MODE · Phase A built — guard precision (Opus, 2026-08-14)"** — it
has the numbers and the cases. This prompt is the decision it defers to
you.

## What landed, so you are not re-checking it

All four Phase A items from your fix plan, guard suite green with 12 new
cases:

1. Names → `NLTagger`, **three signals** rather than one. The tagger alone
   was not enough in either direction: it missed "Priya" in "Ask Nikhil
   and Priya" and "Essentia" in "the Sterling Essentia lease", and it
   tagged "Tell" in "Tell Rohit the deploy is done" as a personal name. It
   is now tagger, minus anything `.lexicalClass` calls a verb, plus
   capitals that are not sentence-initial, all through the stopword belt
   with ordinals and generic place nouns added. Your flag is in the ledger.
2. Ceiling `≤ input`, +12-word email-shell allowance via `AppContext`. The
   26/26 refusal is a suite case.
3. 4s timeout → Clean, via a `TaskGroup` race so cancellation reaches
   URLSession. Clean-in-parallel verified as already landed.
4. Fallback notices → notice box, 4.5s.

**Both classes you named are fixed.** Name violations went from *the
largest single driver* to 2 of 31. The equal-length refusal class is gone.

## The gate

`run.py --model gpt-4o-mini`, 31 transcripts, compiled guard:
**9/31 broke a fact (29%)**, against the handoff's ≤15%.

One correction to our own instrumentation, so you can trust the rest: the
first run read 39% because the eval's verifier binary had not been rebuilt
after the ceiling change and was still scoring with the strictly-shorter
rule. Re-scoring the same saved rewrites with the correct binary gave 29%.

## Why it did not reach the gate

**Every real-cohort failure is self-correction — your S2 cluster,
reproduced on the eval set. In all three the guard is wrong and the
rewrite is right.**

```
real-5   said : Can we do the demo on Thursday? Actually, wait, no.
                Thursday is the all hands. Let's do Monday. Yeah,
                Monday afternoon works better anyways.
         wrote: Let's do the demo on Monday afternoon.
         guard: day, negation, question-lost

real-10  said : they asked to move it from 430 to 2 but I have a
                conflict at 2 so I told them 245
         wrote: move the customer calls from 430 to 245
         guard: number

real-9   said : i've been going back and forth on this all morning…
         wrote: We should park the export feature this quarter.
         guard: relative-time
```

The speaker retracted Thursday, retracted the question, retracted the 2.
The guard demands retracted facts survive. And real-9 deletes "all
morning" — which the prompt **explicitly orders** deleted ("Delete:
fillers, repetition, false starts, and the journey").

**The guard now contradicts the prompt.** Same shape as the ordinals and
the phantom names, one level up: a mechanical rule that cannot see intent.
This was Phase 2 in your plan; the evidence now puts it at the top.

## The decision we want from you

**Which, and why:**

1. **Extend Phase A with retraction handling, then re-gate.** Our
   preference, because Phase B's few-shots will be tuned against whatever
   the guard rejects — leaving a known contradiction in place bakes it
   into the prompt.
2. **Lower the Phase A gate.** Both named classes are fixed; the remainder
   is a class you had scheduled for later. Defensible, and it unblocks B.
3. **Proceed to B at 29%**, accepting the noise.

**If (1), the design question is the whole risk.** A false retraction
deletes something the speaker meant, which is worse than the false
positive it fixes — a lost fact is silent, a fallback is not. Candidates
we can see, none obviously right:

- **Lexical markers**: "actually", "wait", "no", "scratch that",
  "instead", "sorry", followed by a replacement of the same class. Cheap
  and deterministic, in the file's original spirit. Brittle: "no" is also
  a negation the guard protects, and real-5 has the guard firing on
  exactly that "no".
- **Last-value-wins per class**: if two days appear and the rewrite keeps
  the later one, do not report the earlier as lost. Simple, and wrong
  whenever both facts are real ("move Tuesday's to Thursday").
- **Retry-with-context**, your original proposal: tell the model what it
  dropped and let it decide, keeping the guard mechanical. Costs a round
  trip on exactly the cases we are trying to make faster.
- **Ask the tagger.** We already pay for `NLTagger`; whether it can
  usefully mark a retracted clause is not something we have tested.

Also worth your view: **should `relative-time` be pinned at all?** real-9
is the prompt and the guard disagreeing about whether "all morning" is a
fact or the journey. If it is the journey, the class is mis-specified
rather than mis-implemented.

## Ground rules

Unchanged. Nobody marks their own work verified. Items 1–4 are
`claimed-fixed`; the gate is recorded as `not met` rather than softened.
If you think our three-signal name extraction is over-built, or that
`NLTagger` was the wrong trade at all, say so — it is the one place the
guard's "dumb code" virtue was deliberately bent, and it is easier to
reverse now than after Phase B is tuned on top of it.

Write your review into `review/LEDGER.md` in the existing style.
