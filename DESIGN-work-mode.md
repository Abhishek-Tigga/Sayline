# Work mode and context-aware dictation — agreed design

Settled in a grilling session on 2026-08-13, eight decisions, one at a
time, each chosen from worked examples rather than descriptions. Recorded
because the reasoning is the part that gets lost — the decisions will be
obvious from the code, the rejected alternatives will not.

Nothing here is built yet.

## The model in one paragraph

Two modes the user chooses, one seasoning the app applies. A single
press-hold is **Clean**: *what you said*, tidied — fillers gone,
punctuation fixed, your sentences and structure intact. A double-tap-hold
is **Work**: *what you meant*, restructured — conclusion first, five
rambling sentences become two clear ones, protected by a deterministic
fact guard. **Context** (which app the text lands in) is not a third
mode: it never changes how much the words are transformed, only how they
dress — a Work rewrite comes out crisp and casual in Slack, composed and
formal in Gmail, and neutral-professional anywhere the detector cannot
classify. Depth is always the user's choice; register is always the
app's.

## The eight decisions

**1 · Work mode is a clarity rewrite, plus bullets only for dictated
lists.** Restructuring is allowed and expected: reordering, merging,
deleting thinking-out-loud. Bullets appear only when the speaker
dictated an actual list ("three reasons: first… second…"). Rejected:
register-only polish (indistinguishable from Clean+context, nothing to
pay for) and full format-aware scaffolding — invented headers, bullet
skeletons, "Thoughts?" sign-offs. The model must never author content in
the user's name; that line was paid for once already (see the cleanup
data-loss bug in PRODUCT.md).

**2 · The safety contract is the layered guard, "(b+)".** Clean mode's
contract ("never lose a word") cannot apply to a rewrite, so Work mode
gets its own:

1. *Pin the facts in the prompt.* Code extracts numbers, day-names,
   proper nouns and negation phrases from the raw transcript before the
   model call, and lists them in the prompt as must-appear-verbatim.
   The same extraction feeds the check afterwards, so prompt and guard
   cannot drift apart.
2. *The strongest model that fits the latency budget, at temperature 0,
   chosen by measurement* — see decision 7 and the eval section.
3. *The fact guard*: deterministic code, no second LLM. Every number
   (spoken forms normalized — "fifteen" = 15), day-name, name and
   negation from the raw words must survive intact; nothing substantive
   may appear that was never said. Structure is completely free.
4. *One corrective retry.* A violation sends one follow-up naming the
   broken fact; the retry is re-checked. Pass → insert, ~a second late.
   Fail → fall back.
5. *Visible fallback.* The Clean version inserts instead, and the pill
   flashes what happened ("Kept your exact words — the rewrite changed
   a day"). Never silent, never nothing.
6. *Everything logged* with the violation class, so "does the guard
   fire too often on good rewrites" becomes a lookup, and the
   preview-on-suspicion upgrade (rejected for v1 as new UI for a rare
   case) can be built on evidence if the log ever justifies it.

Rejected: trust-the-model (how the original silent-data-loss bug
happened), preview-every-insert (a ~2s tax on every work dictation that
users stop reading within a week), and LLM-as-judge (adds a round trip
and its own hallucinations; the guard being dumb code is its virtue).

**3 · Context is seasoning, never a mode.** It adjusts register on top
of whichever mode the user chose: cosmetics only in Clean (contractions,
dashes), tone in Work (Slack crisp, email composed). Unknown context —
an unclassifiable browser tab, a documented detector limit — gets
neutral-professional: safe in any room. Rejected: the Wispr shape, where
the focused window decides rewrite depth automatically. A wrong guess
there rewrites a quick note into a memo without the user asking; depth
is too consequential to infer from a window title, register too trivial
to bother the user with.

**4 · The hotkey is the style control; the picker retires.** Verbatim /
Clean / Concise goes away. Concise is absorbed by Work, which does its
job better and guarded. Verbatim survives in exactly two places: forced
automatically in Code context (single press, unchanged), and a Settings
toggle ("always insert my exact words") for whoever wants raw output
everywhere. Migration: a stored Verbatim preference turns the toggle on;
a stored Concise preference maps to Clean. Rejected: keeping both
surfaces (3 styles × 2 modes = six combinations to explain, and "Concise
selected + double-tap" has no right answer) and picker-as-default (kept
alive as a fallback idea if Settings-buried Verbatim draws real
complaints — that complaint would arrive with data attached).

**5 · In code windows, the double-tap wins.** Single press in a code
editor or terminal stays forced-verbatim, exactly as today. An explicit
double-tap gets Work mode even there — a terminal is where commit
messages and PR descriptions live, and the locked model says context
never vetoes the user's explicit depth choice. The fumble risk (an
accidental double-tap rewriting something exact) is bounded: it is one
utterance, the mode is visible on the pill mid-hold, and the guard still
freezes names and numbers. This reverses the reviewer's own first
recommendation, on the grounds that the Q3 model made it inconsistent.

**6 · The mode is visible before you finish speaking, and flippable in
Settings.** The pill shows the mode the instant the hold registers —
Work gets its own label and accent, the same lesson as the agent-mode
styling fix. A Settings option ("Default mode: Clean / Work") flips the
gestures for users whose whole day is email: single press = Work,
double-tap = Clean. Rejected: a spoken mode prefix ("work mode: hi
team…") — a parsing gamble on the one path that must never gamble, and a
third door to be confused about.

**7 · Work mode may cost up to ~one extra second; Clean's speed never
changes.** You let go, text lands in ~2s instead of ~1s. The model is
chosen by measurement against that budget, and the number is written
down. Rejected: matching Clean's speed (forces the weakest model,
maximizes guard fallbacks — the feature would disappoint) and
quality-at-any-cost (3–4s of staring at a pill reads as broken in a
dictation app).

**8 · Dictation only.** Agent commands (hold+Space) and spoken follow-up
answers ignore the double-tap entirely — treated as a single press, no
error, no message. There is no text to professionalize in "remind me to
call the bank at 4", and touching it could only hurt.

## Architecture

New files, one rule inherited from the meetings build: **anything that
decides must compile without frameworks so a check suite can hold it.**

- **`FactGuard.swift`** (pure, no imports beyond Foundation). Owns:
  `extract(from raw: String) -> FactSet` (numbers with spoken-form
  normalization, day-names, capitalized proper nouns, negation spans)
  and `verify(raw: FactSet, rewrite: String) -> [Violation]`. Used
  twice per dictation: once to build the pinned-facts prompt block, once
  to check the result. Gets `eval/factguard-checks` on day one — the
  Tuesday/Monday swap, the invented "I'll", the 15→50, the negation
  flip, the resolved self-correction (a documented false positive, in
  the suite as a *known* limitation so nobody rediscovers it as a bug).
- **`WorkModeCleaner.swift`** (or a mode on `TranscriptCleaner` — the
  builder's call; separate file preferred so Clean's prompt and
  validator stay byte-identical to today). Owns the Work prompt, the
  per-context register fragments (email / chat / neutral-professional),
  the temperature-0 call to the measured model, the single retry with
  the violation named, and the fallback decision. Never touches the
  router; work mode is entirely on the dictation path.
- **`HotkeyManager`** gains double-tap detection: a hold that begins
  within ~350 ms of a previous hold ending, where that previous hold
  itself lasted under ~350 ms, is a Work hold. The first tap's fragment
  is already discarded by the existing 0.4 s mis-tap rule, so normal
  dictation start stays instant — nothing waits to see whether a second
  tap is coming. The window value is a starting point, tuned by hand
  once it is feelable.
- **`AppDelegate` / pipeline**: `isWorkModeThisRecording`, set per-hold
  like agent mode; routed only on the plain-dictation branch (decision
  8). Clean path unchanged. `TranscriptCleanupValidator` continues to
  gate Clean exactly as today and is **not** applied to Work output —
  the fact guard is Work's validator.
- **`RecordingIndicatorView`**: style row removed; mode chip added;
  fallback flash strings from decision 2.
- **Settings**: the default-mode flip and the always-verbatim toggle;
  migration of the old style preference.
- **History**: entries record which mode produced them — one field, and
  it makes the usage telemetry question ("does anyone use work mode?")
  answerable from data.

## The eval, before the implementation

House rule: write the test set first. A frozen set of ~25 real rambling
transcripts (drawn from actual dictation history, mishearings included)
with per-case expected facts. Scoring is mechanical: `FactGuard.verify`
against each candidate model's output — hallucination rate, fallback
rate, retry-rescue rate, and wall-clock latency. The model that wins
does so inside the +1 s budget, and the run lands in `eval/results.md`
like every other measured decision. Candidates should include the
current 8B (as the baseline that presumably fails), and the mid-tier
options already used elsewhere in the app.

What each layer can and cannot see, stated because it keeps catching us:
the router eval is blind to all of this (work mode never touches the
router); `factguard-checks` covers extraction and verification but not
model behaviour; the model eval covers behaviour but costs money and
needs a key; the pill display, the double-tap feel, the Settings flip
and the code-window cases are manual-checklist items only. The
`--selftest-capture` lesson applies: assert the *content* (facts
survive), not the artifact (a rewrite came back).

## Out of scope for v1, deliberately

- The preview-on-suspicion UI (decision 2's upgrade path — needs log
  evidence first).
- Any automatic depth selection from context (rejected outright, not
  deferred).
- Invented formatting: headers, sign-offs, bullet skeletons from prose.
- Work mode for agent commands or follow-up answers.
- A spoken mode-switch command.
- Custom vocabulary — separate feature, compounds this one later.

## Open details, small and named

Two implementation details were not put to the user and are flagged
rather than smuggled: the exact double-tap window (350 ms starting
value), and whether the Work hold gets a distinct chime (proposed: yes,
a two-tone variant — an audible mode confirmation for free — but it is
a taste call and cheap to change). Both are tune-by-feel items for the
first live session.
