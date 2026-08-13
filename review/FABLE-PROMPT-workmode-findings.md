# Fable — the guard passes invented content, and my model ranking is unsafe

Open `/Users/abhishektigga/Documents/Dictation/Sayline`.

Stage 2 of work mode ran: a 25-transcript bake-off across four models,
scored by `FactGuard`. I then read the actual rewrites and found the
measurement is wrong in both directions. **I am not picking a model on
it, and stage 3 has not started.**

Read, in order: `DESIGN-work-mode.md` (decision 2 is the contract),
`review/LEDGER.md` newest three entries (the bake-off, then the findings),
`Sources/Sayline/FactGuard.swift`, `eval/factguard-checks/main.swift`
(55 cases), `eval/work-mode/run.py` and `transcripts.json`.

## What the bake-off said

| model | broke a fact | retry rescued | ends in fallback | median |
|---|---|---|---|---|
| `llama-3.1-8b-instant` (baseline) | 39% | 0% | 39% | 188 ms |
| `llama-3.3-70b-versatile` | 20% | 80% | 4% | 380 ms |
| `gpt-4o-mini` | 20% | 100% | 0% | 1167 ms |
| `gpt-4.1-mini` | 24% | 83% | 4% | 1030 ms |

I recommended `llama-3.3-70b-versatile` on the 380 ms against decision 7's
Clean + ~1 s budget. Then I read the output.

## Finding 1 — the one that matters

`real-1`. Guard verdict: **clean**.

> **said:** "Hey, so about the design review, Rohan said he can't make
> Wednesday anymore. So I'm thinking we move it to Friday morning like
> 11ish. Doesn't that work for you or is Friday bad?"
>
> **wrote:** "Rohan can no longer make it on Wednesday, so we are
> considering moving the design review to Friday morning at 11. *This
> change may not work for everyone, as there are 2 potential issues with
> the new time.*"

There are no two potential issues. The model invented a sentence
containing a number, and the guard passed it.

`made-15` does the same: appended *"The api is affected by these
issues."* — invented, unflagged.

**Why it passes:** `FactGuard` checks that raw facts *survive*, and checks
*invention* only for names (`inventedName`) and commitments
(`inventedCommitment`). An invented number, date, quantity or claim is
structurally invisible.

Decision 2's promise is "nothing substantive may appear that was never
said". The implementation enforces that for two categories out of many.
This is the silent-data-loss bug in `PRODUCT.md` arriving from the
opposite direction, and it is the reason I stopped.

## Findings 2–4, smaller

**2 · The pinned-facts block leaked into a rewrite.** `real-7` ends
`"...until we actually talk to sales. | negations: 2 — do not reverse any
statement"`. My harness flattens the pin block with `" | "` and the model
read it as content. A harness bug, but the production prompt will carry
the same block and needs a shape the model cannot mistake for text.

**3 · "one" as a pronoun becomes the number 1.** "quick one" (`real-8`),
"he wasn't on the last one" (`real-10`). Both pinned, both correctly
dropped by the rewrite, both counted as `numberLost`. Two of five samples
carry a false positive from this alone.

**4 · `negationAdded` fired on a faithful rendering.** `real-8`: "or it
slips to the next month cycle" → "*If it is not* cleared by then, it will
slip". Identical meaning, expressed with a negation the speaker did not
use. That is the zero-to-one rule you proposed and I implemented.

## What I want from you

1. **How to catch invention** without an LLM judge (decision 2 rejects
   one) and without forbidding the connective words a rewrite must add.
   My candidate is narrow: **no number, date, day, month or unit may
   appear in the rewrite that was not in the raw** — cheap, deterministic,
   and it catches both cases above. Is that sufficient, or does the
   general case ("The api is affected by these issues" contains no
   number) need something else? If the general case is not solvable
   deterministically, say so plainly — that is a real answer and it
   changes what work mode can promise.
2. **Keep or drop `negationAdded`?** Finding 4 is a faithful rewrite
   flagged. You proposed the rule; you are best placed to say whether it
   earns its false positives.
3. **Pronoun "one"** — exclude it, and if so how far? "no one", "the last
   one", "one more thing", against "one week" and "one of the three".
4. **Re-run the bake-off after fixing the guard?** My assumption is yes,
   and that the ranking may not survive it — `gpt-4o-mini` had a 100%
   rescue rate, which matters more if the guard fires more accurately.
   Say if you would decide differently.

## Constraints

- **No LLM in the guard path.** Decision 2 rejects it with reasons. If you
  believe that decision is wrong, argue against its stated reason and flag
  it for the user rather than designing around it.
- The guard must not fight the mode. It already did once: a strict
  negation count fired when a model correctly dropped a rhetorical
  question, and was 8 of 13 violations across every model. Narrowed to
  all-or-nothing, suite case added.
- Every stopword-list addition arrives with the real transcript that
  motivated it, as a suite case, in the same commit. The rule is in the
  file header.

## Reproducing

```bash
swiftc -o /tmp/fgchk Sources/Sayline/FactGuard.swift \
  eval/factguard-checks/main.swift && /tmp/fgchk        # 55 cases
python3 eval/work-mode/run.py --model llama-3.3-70b-versatile
python3 eval/work-mode/run.py --dry-run                  # prompts, no calls
```

Append to `review/LEDGER.md`. You may mark your own work `claimed-fixed`,
never `VERIFIED`.
