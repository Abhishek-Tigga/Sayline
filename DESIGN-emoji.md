# Emoji in dictation — agreed design

Settled in a grilling session on 2026-08-13, four decisions, one at a
time, each chosen from worked examples. Recorded with the rejected
alternatives, per house convention. Builds on `DESIGN-work-mode.md`
(modes, context-as-seasoning, the fact guard) — read that first; this
document does not restate it.

Nothing here is built yet.

## The feature in one paragraph

Two ways to get an emoji while dictating. **Named**: say the emoji's
name plus the word "emoji" — "fire emoji", "thumbs up emoji" — anywhere
in a sentence, in either mode, and the named emoji appears in place:
deterministic table lookup, no AI, zero latency. **Delegated**: end a
dictation with the bare word "emoji" and the app picks one that fits
what was said — riding the cleanup call that already runs, so also zero
added latency. Explicit always obeys; delegated is allowed taste: in a
formal register the best-suited emoji can be *none*, the trigger word is
consumed either way, and the pick is capped at exactly one.

## The four decisions

**1 · Both forms, built table-first.** Named is a lookup ("fire" → 🔥)
— the house style: when we know the answer, don't ask a model. It
covers most real use (people want the same ten emojis) and works
identically every time. Delegated is the delight feature and the
original ask; it can be wrong, so decisions 3 and 4 bound it. Rejected:
named-only (misses the ask), delegated-only (makes the reliable
majority case guessy for no reason).

**2 · Placement follows risk.** *Named works anywhere* in the sentence
— "great job fire emoji, let's ship" → "Great job 🔥, let's ship" —
because it is near-unambiguous, and even talking *about* an emoji
("the fire emoji is my favorite" → "the 🔥 is my favorite") reads
fine. *Bare "emoji" fires only as the final word* of the dictation —
which is also how the feature was described ("append"). Mid-sentence
bare "emoji" always stays text, which automatically protects literal
uses ("other apps reject emoji when you dictate"). *The plural never
triggers*: "I love emojis" is always text, and since people talking
about emojis usually use the plural, this one rule removes most
collisions. Accepted residual risk, logged rather than engineered
away: a sentence that genuinely *ends* with the literal singular
("kids these days love emoji") will misfire and get a pick appended —
rare, visible immediately, fixed by redictating. Rejected: an escape
phrase ("the word emoji") nobody would discover.

**3 · Explicit obeys everywhere; delegated respects the room.** Named
emoji works in Clean and Work mode alike, in any app — same principle
as double-tap-wins: when the user is explicit, context never vetoes.
The bare-form pick is a delegation, and a good delegate knows when to
decline: in a formal register (Work mode's email seasoning), "no
emoji" is a valid answer — the trigger word is dropped and nothing is
inserted. The same sentence gets ✅ in Slack and nothing in a client
email; whoever wants the ✅ in the email says "check mark emoji" and
gets it. Verbatim situations (single press in code windows, the
exact-words toggle) run no cleanup at all, so triggers never fire
there — settled by prior decisions, not reopened. Rejected:
always-pick (an emoji in the user's name, in a room where the register
says it doesn't belong).

**4 · Unsure means silence, and one is the cap.** When the bare form
gives the model nothing to work with ("send me the file when you get a
chance, emoji"), the trigger word is dropped and no emoji is inserted
— a clean sentence, not a stranded word that reads as a typo. The
invocation was unambiguous, so consuming the word is honest; the
missing emoji is decision 3's "best pick is none" doing its job. And a
bare trigger yields at most **one** emoji, hard-capped in code — one is
seasoning, four is a costume, and models decorate when allowed.
Whoever wants 🔥🔥🔥 says "fire emoji" three times; named always
obeys, including in multiples.

## Architecture

The key trick: **the two forms live at different pipeline stages, and
only one needs a guard change.**

- **`EmojiCatalog.swift`** (pure, Foundation-only — the checkable-file
  rule). The alias table: ~100 spoken names → emoji, multi-word names
  included ("thumbs up", "check mark", "rolling on the floor
  laughing"), matched longest-name-first against the words preceding
  "emoji". Default skin tone; no tone variants in v1. Plus the
  placement rules from decision 2: `substituteNamed(in:)` and
  `endsWithBareTrigger(_:)`.
- **Named substitution runs on the raw transcript, before cleanup** —
  the same slot where voice-command detection already runs. Because the
  emoji is in the text *before* the LLM sees it, the cleanup model
  treats it as something the user said, and — the important part —
  **`TranscriptCleanupValidator` needs no carve-out for named emoji at
  all**: the emoji is part of the baseline it diffs against.
- **The bare-form pick rides the existing cleanup call.** When
  `endsWithBareTrigger` is true, the trigger word is stripped from the
  raw text, and the prompt (Clean's, or Work mode's) gains one
  instruction: append at most one fitting emoji, or none if the
  register says so, never anything else. The validator (Clean) and
  `FactGuard` (Work) each get one narrow allowance: **a single
  trailing emoji character is a permitted addition when — and only
  when — the raw transcript ended with the bare trigger.** Any other
  added emoji, or more than one, is stripped like any other invented
  content. The allowance is a flag computed deterministically from the
  raw text, not something the model can claim.
- **No new latency anywhere**: named is a table hit; bare is a prompt
  line on a call that already happens. Nothing about decision 7 of the
  work-mode design (the +1s budget) is touched.
- **History and logging**: entries record when an emoji was inserted
  and by which form; bare-form declines ("best pick was none") are
  logged so the decline rate is a lookup, not a debate.

## Testing, by layer

- **`eval/emoji-checks`** (new suite, pure): named substitution in
  place, multi-word names, longest-match ("check mark" before
  "check"), plural never fires, mid-sentence bare "emoji" never fires,
  end-position bare trigger detected, the literal-collision sentences
  from decision 2 pass through untouched, cap logic.
- **Validator/guard cases**: the existing cleanup-validator behaviour
  and `FactGuard` each gain cases for the narrow allowance — a
  permitted single trailing emoji survives; a model that emits two, or
  an emoji without the trigger flag, gets stripped. (Noting honestly:
  the cleanup validator still has no suite at all — F6, parked. These
  cases land wherever that suite lands, and this feature is one more
  reason to build it.)
- **Model-side quality** (does the pick *fit*): a handful of cases in
  the work-mode model eval — celebratory, commiserating, neutral-
  formal-should-decline — scored on "is the emoji from the right
  emotional family / correctly absent", the one place mechanical
  scoring is loose here. Small set, run with the work-mode eval, not
  its own harness.
- **Manual checklist**: the real-dictation feel — trailing "emoji"
  after natural speech, a named emoji mid-ramble, the formal-email
  decline.

## Out of scope for v1, deliberately

- Skin-tone preferences (default tone only; a Settings item someday).
- An escape phrase for the literal word ("the word emoji").
- Custom user-defined emoji names or mappings.
- Emoji in agent commands or follow-up answers (nothing to decorate).
- Multiple delegated emojis, ever (the cap is a decision, not a v1
  limit).

## Open details, small and named

Two tune-by-feel items not put to the user, flagged rather than
smuggled: punctuation adjacency for the bare-form append ("let's ship
🔥" vs "let's ship. 🔥" — likely register-dependent, chat drops the
period, email keeps it), and the exact table size/contents at launch
(~100 aliases is the target; the log's miss rate — named lookups that
matched nothing — tells us what to add).
