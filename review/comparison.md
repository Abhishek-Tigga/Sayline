# Comparing the two reviews

Fable, 2026-08-11. Written after completing `fable-review.md` independently,
then reading `opus-review.md`. Where I checked a disputed claim, I say how.

The one-line verdict: the Opus review is better than self-review usually is
— its two best findings (prompt injection, the deterministic fast path) are
things I missed, and its disclosures are honest. But it shows exactly the
bias it warned about, in a specific and checkable form: **it stopped
auditing the code it had just fixed**, and it apparently never re-ran the
eval it praises — which is broken at HEAD.

---

## 1. What it found that I missed

**Prompt injection via calendar text (its finding 3).** My biggest miss. I
reviewed the meetings design for structure and latency and never asked whose
words enter the loop. Calendar notes are attacker-controlled text, and the
current tool set opens URLs and deletes reminders. I agree with the finding
and with the fix (extract join links with a regex; raw event text never
enters a prompt that can emit tool calls — write it into the DESIGN doc
now). One correction to its urgency framing: as *currently designed*,
meetings never feeds event text to the model at all — the router still sees
only the user's speech, and event text goes to the pill. So the boundary is
not being crossed by the design on the table; the paragraph exists to stop
the *next* feature ("summarize my meeting") from crossing it casually.
That's still worth a paragraph today. Verdict: real, cheap, do it — but
it's a fence for the future, not a hole in the plan.

**The deterministic fast path (its opportunity A).** The best single idea
in either document, and squarely on a named pillar. I proposed measuring
latency and trimming tokens; it proposed *removing the round trip* for
fixed-vocabulary commands, with the eval as the safety net. I agree, with
one design constraint it doesn't state: the fast path must be
whole-utterance-gated, exactly like `VoiceCommand` — "Open Safari" matches,
"Open Safari and check my battery" must fall through to the router, or the
fast path silently eats the second half of compound commands. The pattern
(word-count guard + fuzzy match) already exists in `VoiceCommand.swift`;
reuse it. With that gate, I'd rank this top-three.

**Unit economics and fix velocity as pillars.** I cut cost-per-user from my
pillar list and never considered release-gated catalog fixes at all. Both
are legitimate commercial pillars. On the server-config proposal I'd flag
one overstated cost claim: "you are already building backend
infrastructure" — per PRODUCT.md the backend proxy is a *plan*, not a
thing; the marginal cost of the first served file is standing up the first
server. Right destination, wrong price tag; sequence it with the proxy
work.

**History storage (its finding 2) as a full finding.** I noted plaintext
UserDefaults in a pillar aside; it made the sharper move of asking what
history is *for* before choosing storage. Its framing is better than mine.

**Activation (pillar 3 / opportunity E).** Fair pillar, and its permission
status view is a good, narrow proposal. But it re-opens ground the repo has
already ruled on without engaging the ruling: BACKLOG.md explicitly defers
onboarding to the end of V2. The brief for both reviews was to argue
against stated reasons, not around them. The honest version is: the
*status view* is narrower than the parked onboarding flow and arguably not
covered by the deferral — say that, then propose it.

## 2. What I found that it missed

**The eval harness cannot run at HEAD.** Its finding 8 says the file list
"broke twice today" — so it *hit* this — yet it neither says the checked-in
harness is dead right now (missing `LocalTimestamp` in the parts list) nor
lists the one-line fix, and CLAUDE.md's first verification command
currently exits with a compile error. I ran it, watched it fail, patched a
copy, and got a clean 55/57 baseline. Related tell: its review quotes
latency numbers from `results.md` history rather than a fresh run, while
claiming "evidence is from running the system." More on this in §4.

**Two concrete races in the follow-up mechanism it built this week:**

- *Timeout mid-hold:* the 20s timer keeps running while the user holds and
  speaks; if it fires before hotkey-up, the spoken "yes, delete it" goes
  down the dictation path and gets typed into the focused app — the exact
  outcome the design doc says must never happen. Fix: claim the hold at
  hotkey-*down* and pause the timer during a hold.
- *Question replacement is `.timedOut`:* a second `askFollowUp` finishes
  the first question as timed out, and the time-question's timeout fallback
  **silently creates the reminder undated**. Reachable today from one
  utterance ("remind me to X and remind me to Y") because actions are fired
  as unstructured Tasks.

Its finding 5 stands next to this code — it cites the `hide()` bug it fixed
there as proof of the design problem — and finds neither remaining race.

**Multi-action ordering.** Same neighborhood: "remind me to X, then open
Safari" opens Safari mid-conversation, and the turn's outcome flags are
decided before the reminder resolves. Its `ActionOutcome` proposal doesn't
mention sequencing; mine makes sequential `await` the core of the fix.

**`empty_trash` executes unconfirmed.** The one permanent, unconfirmable
action in the product, inconsistent with the reminder-delete flow, and
BACKLOG's stated justification ("recoverable") confuses filling the Trash
with emptying it. A trust-pillar review should have caught the trust
pillar's worst outlier.

**What is untested, by name.** Its finding 7 ("no test target") is correct
but generic. It never names `TranscriptCleanupValidator` — 357 untested
lines that are the sole defense against the worst historical bug class
(silent deletion of dictated content) — nor `VoiceCommand` (whose
word-count guard exists because of a specific near-miss that lives only as
prose), nor the pane matcher. Knowing *what* to freeze is most of the work.

**The freeze pillar gets no action.** It names host stability "existential"
and then proposes nothing for it. My persistent-log + stall-watchdog
finding is the missing owner: both prior investigations died for lack of
evidence at the moment of failure, and meetings is about to add EventKit
IPC — the same blocking-call class that caused the last freeze theory — to
the pipeline.

**Live finding: the model defeats fail-visibly by inventing a real pane.**
"Open banana settings" → model emits "General" → catalog obligingly opens
About. Only visible by running the eval, which it didn't.

**Cumulative token growth.** It quotes ~2,350 tokens; it doesn't note that
this is +55% over three days against a stated 10% ceiling, or that the
planned tool-trim should land *before* meetings so the meetings diff is
clean.

## 3. Shared findings — where we differ, and who's right

**AppDelegate dispatch (its 4 ≈ my 1).** Same diagnosis, nearly the same
enum. Differences: (a) it adds an `awaitingAnswer` outcome — good, take it;
(b) it proposes a per-action `ActionHandler` protocol — over-machinery at
39 files; one `AgentTurnRunner` with a switch is enough until a third
coordinator exists; (c) mine makes sequential execution explicit, which is
what actually fixes the observed bugs. Merge: my runner + its outcome
cases, skip the protocol.

**Audio files (its 1 = my 3).** Identical finding, independently counted
(383 files/514 MB vs my 390 — hours apart, same archive). It adds "ask
whether it needs to touch disk at all" — a genuinely better end state,
with one caveat: keep the temp file while the ad-hoc-signing era makes
crash-mid-transcription plausible, then revisit. It ranks this #1, I
ranked the eval fix #1. It's right for a commercial product: the eval fix
is ten minutes and can be done the same morning, but the audio archive is
the finding with a headline in it. Its ranking wins.

**Eval harness (its 8 vs my 2).** Its proposed fix — a dump mode in the
real app binary — is stronger than my "extend the concatenation list"
for prompt/tools, because it deletes the whole drift class. (Mechanical
note: the app is a menu-bar agent, so the dump path must run and exit
before `NSApplication` spins up — handle the flag at the top of `main`.)
But its fix covers only *config* dumping; the harness also shadow-
implements `parseAction`'s normalization in Python, which its review
doesn't mention and which will drift again when meetings adds tools. Final
shape: its dump mode for config, plus my `parse-actions` Swift mode for
normalization, plus the `--dry-run` smoke line in CLAUDE.md so breakage is
caught at commit time.

**Failure-handling policy (its 6).** Real observation, weakest write-up in
its document — "one convention, applied everywhere" is the "consider
refactoring" genre it was asked to avoid. The actionable subset is my
finding 8 (persist the logs so failures leave evidence) plus the
`ActionOutcome` refactor (which forces every handler to declare what the
user sees). I'd fold its finding into those rather than track it
separately.

**Tests (its 7 vs my 6).** It's right about the destination: an XCTest
target beats accumulating hand-compiled `main.swift` suites, and its
observation that the harness pattern is already shaping the architecture
(`LocalTimestamp` split out for compilability) is a sharp one. I'm right
about the contents: the target is only as valuable as what goes in it, and
the highest-value freezes (validator, voice commands, pane matcher) are
listed nowhere in its review. Do its structure with my inventory.

## 4. Where it went easy on itself

Its self-disclosures are real and to its credit — the first-draft
confession, "I added two of those this week without noticing", the
migrated-half-the-callers admission. But the bias it predicted shows up in
three checkable places:

1. **It verified least where it had worked most recently.** The follow-up
   mechanism (built over the last two days) contains two reachable
   trust-class races; its review cites the bug it *fixed* there as
   evidence for a refactor and misses the bugs still present. The pattern:
   once your fix lands, the area reads as "done" and scrutiny moves on.
   A stranger's eyes had no such marker.
2. **"Evidence is from running the system" is overstated.** The eval — the
   thing it calls "the best thing here" — does not run at HEAD, and its
   review both knows the file list broke twice and doesn't say the
   harness is currently dead or fix it. Every number it quotes for the
   router is from `results.md` history. I re-ran everything; that's how
   the banana-pane regression and the 55/57 confirmation surfaced.
3. **Its own recent design calls go unexamined.** `.timedOut` silently
   creating an undated reminder was its design (defensible for genuine
   timeouts); the replacement path reuses that fallback for a situation
   it was never designed for, and the review doesn't revisit it. Likewise
   the opportunities section leans toward *new* builds (fast path, server
   config, onboarding) over hardening the week's own output — new code is
   simply more attractive to its author than auditing what they wrote.

None of this makes the review untrustworthy — it makes it exactly what it
said it was: sharpest at a distance from its own recent work, and
correctly paired with an outside pass.

## 5. Combined priority list — before meetings, in order

Day-one items (1–3 are collectively about two hours):

1. **Delete recordings** — `defer` removal on every transcription path +
   launch sweep of orphans. *(privacy)*
2. **Un-break the eval**: add `LocalTimestamp.swift` to the harness list
   (one line), add `--dry-run` smoke to CLAUDE.md's checklist. The dump-
   mode/`parse-actions` rework can follow later. *(accuracy)*
3. **Write the trust boundary into DESIGN-meetings-reminders.md**: join
   links are regex-extracted; calendar-authored text never enters a prompt
   that can emit tool calls. *(trust, privacy)*

Core work:

4. **Agent turn runner** — `ActionOutcome` (with `awaitingAnswer`),
   sequential `await`, ladder deleted. *(trust)*
5. **Follow-up ownership** — claim the hold at hotkey-down, pause the
   timeout during a hold, replacement takes the declined path rather than
   `.timedOut`. *(trust)*
6. **Confirm `empty_trash`** through the existing follow-up gate — trivial
   once 4 exists. *(trust)*
7. **Deterministic fast path** for whole-utterance fixed-vocabulary
   commands, eval run before and after. *(latency)*
8. **Test target with the named freezes** — XCTest target in `project.yml`;
   migrate the three existing suites; add cleanup-validator, voice-command,
   and pane-matcher cases (including banana→General). *(accuracy, trust)*
9. **Tool-description trim** as its own commit with before/after eval
   numbers, so meetings starts from a clean baseline. *(latency)*
10. **History storage decision** — what is history for; encrypt or drop;
    add a clear control. *(privacy)*
11. **Persistent file log + main-thread stall watchdog** — before meetings
    adds EventKit IPC to the pipeline. *(host stability)*
12. **Token/cost counter** behind a debug flag. *(unit economics)*

After meetings, deliberately: permission status view *(activation — engage
the BACKLOG deferral explicitly)*, server-delivered catalogs *(fix
velocity — sequence with the backend proxy)*, eval dump-mode rework
*(accuracy)*, local-transcription positioning *(privacy — needs the
accuracy/latency comparison first)*.

Items 1–6 are the "meetings is blocked on these" set: each one is code the
meetings feature will sit directly on top of. 7–12 are strongly-before,
not blocking.
