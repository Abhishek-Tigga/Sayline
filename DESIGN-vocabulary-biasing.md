# Vocabulary biasing — agreed design

Settled 2026-08-14: a grilling session, three user decisions (Q1–Q3),
the rest self-answered by Fable and confirmed. The guardrail section
exists because the user asked "what guardrail metric have we set?" and
the honest answer was "none yet" — decision 9 is his catch. Recorded
because the reasoning is the part that gets lost.

Nothing here is built yet. The measurement that justifies the feature
is in `eval/results.md` (2026-08-14): same clips, same model, the only
change a vocabulary hint — WER 16.6% → 11.9%, key terms 61% → 70%,
**every name error fixed**, +36 ms. That run measures the upper bound:
the win when the list contains the right words. This document is the
design of the thing that builds the list.

## The model in one paragraph

Whisper accepts a short prompt (~224 tokens, roughly 150 words) that
biases its hearing toward the vocabulary in it. Sayline assembles that
list per user, on their machine, from what the Mac already knows:
their own typed words, their contacts, their installed apps — ranked
by what they actually say, capped by a fixed ladder, phrased as a
glossary, and sent along with the audio on every transcription. No
server builds it, no history of it is kept anywhere, and if it cannot
be built the dictation goes out without it.

## The decisions

**1 · Three sources, nothing learned silently (user, Q1).** The list
is built from the Settings "my words" box, Contacts first names, and
installed app names. Rejected: history-learning that auto-adds
frequently dictated words — a silent feedback loop where one early
mishear slips into history and gets reinforced, and an invisible list
to debug ("why does it keep writing X?"). Parked, unparks when the
three sources' misses show a pattern the box doesn't catch. Rejected:
box-only — wastes the two sources that come free.

**2 · Budget overflow is resolved by a fixed ladder, unusual words
first (user, Q2).** Priority: the "my words" box always enters (typed
= highest intent), then contact first names, then app names — and
within apps, words Whisper already knows are skipped. "Safari" and
"Notes" need no help; "Figma", "Arc", "Obsidian" do. A slot spent on
a dictionary word is a slot wasted. Rejected: equal thirds (empty
slots when a source is small); context-dependent lists per app (the
same sentence would transcribe differently in different apps — every
mishear report starts with "which app were you in?", a debugging tax
forever). Parked, unparks if the ladder's misses cluster by app
context.

**3 · Contacts are ranked by the user's own dictation history (user,
Q3).** macOS does not expose "recently contacted" — that lives in
Messages/Mail private data, corrected mid-design after Q2 assumed
otherwise. The signal that exists locally: names that appear in past
dictations outrank the 300 contacts never mentioned. This does not
reopen decision 1: history *ranks* verified contacts, it never *adds*
words — a misheard "Pria" matches no contact and therefore ranks
nothing, so the reinforcement loop cannot form. Rejected: alphabetical
("Aarav" beats your best friend "Zoya" forever, for no reason a user
would accept); ranking by WhatsApp-share usage (cold-start-dead for
weeks — though it folds in free later, since a share is itself a
dictation and history captures it).

**4 · One list, applied everywhere.** Dictation in every mode and
context, and agent commands — which may benefit most, since "send
this to Priya" and "open Figma" route on exactly the words biasing
protects. Code context stays included: `.swift` → `.shift` came from
code dictation. Rejected: mode-specific lists (decision 2's rejection,
same reasoning).

**5 · Rebuilt at launch and when inputs change, never mid-dictation.**
Inputs: the box edited, Contacts changed, an app installed. The list a
recording started with is the list it is scored with. Rejected:
per-dictation rebuilds (Contacts enumeration on the hot path for a
list that changes weekly).

**6 · The "my words" box is one plain comma-separated text field.**
First-come-first-in under the ladder, with a note that roughly 150
words fit. Rejected: management UI with categories and counts —
machinery for a list most users will put five words in.

**7 · Phrased as a glossary, one fixed template.** Sent as
`Glossary: Priya, Kunal, Figma, …` — Whisper treats its prompt as
style precedent as well as vocabulary, so a bare word dump can subtly
shift punctuation. The template is part of the eval'd surface: it
lives in the app, `--dump-config` exposes it, and the harness reads it
from there — no second copy to drift.

**8 · The list travels with the audio and is stored nowhere else.**
The transcriber already receives the user's voice saying these very
words; the hint adds no new party and no new retention. It still gets
one sentence in the privacy copy — "we send your contact names with
your audio" deserves to be said out loud, not discovered. Rejected:
treating it as too small to mention.

**9 · The guardrails, set before the build (user's catch).** The
danger: a hint list doesn't just help the model hear those words — it
tempts it to hear them where they weren't said. The current clips all
*contain* the key terms, so the eval as it stands can only see
biasing's wins, never its cheating. Four guardrails, the first three
outcome-numbers per the tripwire rule (a rerun passes or fails, no
judgment):

1. **Overall WER, biased ≤ baseline, full clip set, every run.** The
   whole sentence must not pay for the names. (2026-08-14: 11.9% vs
   16.6% — passes.)
2. **Zero injections on control clips.** New clips whose scripts
   contain *none* of the bias words, including near-sounding traps
   ("the *sigma* of the dataset"). Pass = no bias-list word appears
   in their transcripts, ever. Same discipline as fastroute's
   negative cases: the false match is the silent killer. **These
   clips do not exist yet — the user records them before the build
   is accepted.**
3. **Median latency delta ≤ 50 ms.** Measured +36; the bound makes
   creep visible.
4. **Fail open, and say so.** List construction fails (Contacts
   denied, anything) → the request goes out with no hint, the
   dictation is never blocked, and the log records that biasing was
   skipped. A biasing failure must never cost a dictation.

   **Amended 2026-08-14, hours after shipping.** Guardrail 2 as
   written tested the wrong distribution: control clips are *clear
   speech* with trap words, but the echo fires on *marginal audio* —
   observed live the same evening, when Whisper recited the glossary
   back as the transcript and agent mode executed it (seven apps
   opened, one visit to vodka.com). Loudness is no defense: the
   echoed holds peaked at 0.08 and 1.0. The fix is a fifth guardrail:

5. **The echo guard.** `VocabularyBias.looksLikeEcho` — deterministic,
   structural, no audio signal: a transcript dominated by the
   template's own word ("Glossary" twice, or opening the transcript
   beside an entry) or reciting ≥3 list-consecutive entries in order
   is Whisper reading the hint back, and is discarded at both
   choke points (dictation and agent) with a visible "Didn't catch
   that". Suite-covered with both live echoes as fixtures; an
   `echoprobe-silence` clip in the transcription eval documents the
   model-side behavior each run, unscored.

## Out of scope, written down

- **The numbers problem.** "Two forty five" heard as "4:45" survives
  every downstream guard and biasing cannot touch it — vocabulary
  hints don't help numerals. Its fix (whatever it is) is its own
  future design; recorded in `BACKLOG.md` so it isn't forgotten
  under this feature's umbrella.
- **Context-dependent lists** (decision 2) and **share-usage
  ranking** (decision 3) — parked with their unpark conditions.
- **History-learning** (decision 1) — parked, unpark condition above.

## Verification plan

- **Acceptance = the measurement, reproduced with the production
  list.** `eval/transcription/run.py --bias` reruns reading the real
  assembled list via `--dump-config` (build first, always) instead of
  the simulated one. The win must reproduce and guardrails 1–3 must
  pass on the same run.
- **Deterministic suite** for the ladder: budget overflow order,
  unusual-word filtering, history ranking, glossary templating,
  fail-open on missing sources. CLAUDE.md line in the same commit as
  the suite.
- **By hand**: a real dictation with a box word, a contact name, and
  an unusual app name; Contacts permission revoked mid-session →
  dictation still works and the log shows biasing skipped.
