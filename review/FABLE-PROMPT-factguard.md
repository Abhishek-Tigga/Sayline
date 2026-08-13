# Fable — review FactGuard, and settle one open question

Open `/Users/abhishektigga/Documents/Dictation/Sayline`.

Stage 1 of work mode is built: `FactGuard`, the deterministic guard that
is the entire safety contract for a mode that rewrites the user's words.
Nothing after it has started — no prompt, no model call, no hotkey work —
so this is the cheapest moment to be told it is wrong.

Read `DESIGN-work-mode.md` first (decision 2 is the contract this
implements), then `Sources/Sayline/FactGuard.swift` and
`eval/factguard-checks/main.swift`. The ledger entries for 2026-08-13
record what was claimed.

## The question I actually want answered

Whisper frequently returns lowercase text. `FactGuard` finds names by
capitalization. So for this real transcript, dictated by the user today:

```
so quick recap from the stand up um ankit is taking the payment flow
changes sneha got the dashboard redesign and the analytic migration thing
someone should pick up this week
```

**no names are pinned at all.** A rewrite could swap Ankit's and Sneha's
tasks, or drop a person entirely, and the guard would not notice. This is
not an extractor bug — the signal is absent from the input.

Two options, and I want your call rather than mine:

- **A · Accept it.** Names in lowercase transcripts are unprotected;
  numbers, days and negations still are. Simple, honest, and the mode's
  promise gets a documented hole.
- **B · Also check the inverse.** A capitalized name in the *rewrite* that
  appears nowhere in the raw is an invention — flag it. Cheap, and it
  catches the more dangerous half (the model inventing a person), while
  still not catching a swap between two lowercase names.

My lean is B, on the grounds that inventing a person is worse than
dropping one. But B protects a different failure than the one I found,
which is a weak reason to feel solved. There may be a C I have not seen —
for example, using the *cleaned* transcript (which is capitalized) as the
extraction source rather than the raw one, which would change what the
prompt pins and needs thinking about.

## Review the work itself

**Three judgement calls**, each made to fix a failing case, each
challengeable:

1. **Proper nouns ignore sentence position.** Excluding the first word of
   a sentence rejects "The" correctly and "Sarah" wrongly, and names begin
   sentences constantly. The stopword list does the work. Cost: a
   sentence-initial capitalized verb ("Ship on Tuesday") can read as a
   name.
2. **Verification checks presence, not capitalization** — which is what
   makes (1) safe, since "Ship on Tuesday" rewritten as "…we ship on
   Tuesday" is faithful and a genuinely dropped name is absent in any
   case.
3. **Negations are counted, not matched.** "I don't think we should" and
   "I think we shouldn't" are both faithful; losing one entirely is not.
   A count is crude — it would miss a rewrite that drops one negation and
   adds another elsewhere. Is that acceptable?

**The stopword list is now doing a lot of load-bearing work** and it grew
by inspection rather than principle. `notNames` holds contractions,
sentence-openers, months, days and common verbs. Ask whether that is a
maintainable shape or a list that will quietly rot.

**The test set.** 34 cases. The user dictated ten real work messages
rather than letting me invent the set, explicitly so the exam was not
written by the feature's author. It found four bugs the 26 invented cases
missed inside a minute:

- contractions pinned as names ("Doesn't", "Can", "Yeah")
- `45,000` split by the thousands comma into 45 and 0
- ordinal deadlines (`the 30th`) invisible entirely
- times as bare digits already worked

Frozen transcripts: `eval/work-mode/transcripts.json`. Current extraction
over them:

```
real-1: days[friday,wednesday] names[rohan] neg=2
real-2: nums[60] neg=1
real-3: nums[25,99] neg=3
real-4: nums[2] neg=0          <- the lowercase-names case above
real-5: days[monday,thursday] neg=1
real-6: nums[70] neg=2
real-7: neg=2
real-8: nums[1,30,45000] neg=0
real-9: nums[3] neg=0
real-10: nums[1,2,245,430] names[karen,miras] neg=1
```

Worth your attention: `real-5` is the user's own speech containing the
**documented false positive** — "Can we do the demo on Thursday? Actually,
wait, no. Thursday is the all hands. Let's do Monday." A good rewrite
drops Thursday and the guard will fire. The suite asserts this fires, so
the limit is recorded rather than rediscovered. Is asserting a known
false positive the right way to hold that, or does it entrench a defect?

`real-7` and `real-2` pin **only a negation count** — "I really don't want
to remove the free tier… I don't agree" is a strong opinion whose entire
meaning is the negation. Is a count enough protection for that?

## What I want back

1. **A, B, or something better**, with the reason.
2. **Whether any of the three judgement calls is wrong**, and which
   failing case your alternative would break.
3. **Gaps in the test set** — what a rewrite could break that 34 cases
   would not catch. This is the one that matters most; the suite is the
   only thing standing between a rewrite and the user's meaning.
4. **Anything in the guard that will rot**, especially the stopword list.

## Rules

Append to `review/LEDGER.md`. You may mark your own work `claimed-fixed`,
never `VERIFIED`.

Do not propose adding an LLM to the guard path — decision 2 rejects it
explicitly, and the guard being dumb code is the property being bought.
If you think that decision is wrong, argue against its stated reason and
flag it for the user rather than designing around it.

Stage 2 (the model eval) has not started and no model has been called, so
nothing downstream is committed to this shape yet.
