# Sayline — independent architecture review (Fable)

Written 2026-08-11, before reading `review/opus-review.md`, per the ground
rules. Everything below was checked by running, not just reading:

- All three deterministic check suites: **pass** (catalog, consent, timestamp).
- Full build via xcodegen + xcodebuild: **succeeds**.
- Router eval, 57 cases against live `gpt-4o-mini`: **55/57 (96%), 0 syntax
  failures, 2345 median prompt tokens, 1296 ms median latency** — consistent
  with the recorded baseline. But the harness **would not start as checked
  in**; see finding 2. I ran a patched copy from a scratch directory.
- URL health: 74 alive, 0 dead, 2 auth-gated CHECK rows (documented
  behaviour), Jira timeout.
- Counted **390 `sayline-*.wav` files in the temp directory** of this
  machine. See finding 3.

---

## 1a. The pillars

The team names two: **accuracy** and **latency**. For a tool that holds a
microphone permission, runs all day with an event tap in the input path, and
acts on the user's behalf, three more decide whether anyone pays for it.

### 1. Accuracy — owned

Commercially: a dictation tool that types the wrong words or an agent that
does the wrong thing is returned within the trial period. This is the
best-owned pillar in the repo: the router eval, the four deterministic check
suites, the cleanup validator, the "deterministic rules beat prompt
engineering" convention. The ownership gaps that remain are listed under
findings 2 and 6 — the eval can't currently run, and several deterministic
guards have no tests — but the *pillar* has a clear owner and a culture.

### 2. Latency — half-owned

Commercially: the pitch of a native app over Electron is feel. Every
hold-to-talk interaction has a human standing there waiting; 2 seconds feels
like a broken product even when it isn't.

Owned in the eval (median latency per router call, token budget in the
design doc). **Unowned in production**: the app never measures its own
end-to-end time from hotkey-up to action. Nobody can say what a real user's
p90 is, whether the transcription leg or the routing leg dominates, or
whether last week's features moved it. The 10% prompt-growth ceiling exists
on paper while measured prompt tokens grew **1518 → 2353 (+55%)** between
2026-08-08 and 2026-08-10 (`eval/results.md`). Each step was individually
measured, which is better than most teams do — but nobody owns the
cumulative number. See finding 7.

### 3. Trust — the app acts on your behalf, and a wrong action is worse than no action

Commercially: this is the pillar that produces one-star reviews with
screenshots. A dictation error wastes ten seconds; an agent error deletes
something or sends something. Wispr Flow's competitors don't empty your
Trash; Sayline can.

Partially owned, and the owned parts are genuinely good: the follow-up
primitive, confirm-before-delete for reminders, "never guess yes", the
consent parser tested against traps like "yes, but not now". But there is
**no single danger model** — each action's safety level was decided at the
moment it shipped, so the levels are inconsistent (finding 5: `empty_trash`
executes unconfirmed while a reminder delete needs a click), and follow-up
ownership has races that can paste a spoken "yes, delete it" into a
document (finding 4).

### 4. Privacy — nobody's job today, and it's the sales pitch

Commercially: BACKLOG.md itself argues against a Location permission because
"an app whose whole pitch is dictation privacy" cannot afford it. That pitch
is currently untrue on disk: every recording ever made sits unencrypted in
the temp directory (390 on this machine), and the last 20 transcripts sit in
plaintext in UserDefaults. Nothing in the code owns the question "where does
spoken audio go, and when does it die?" For a commercial product this is
also a legal-exposure question (GDPR data-at-rest, corporate customers with
DLP scanners that will find these files). Finding 3.

### 5. Reliability + observability — the app must run all day, and today it's a black box

Commercially: a menu-bar utility gets one chance. The user whose hotkey goes
dead mid-meeting, or whose Mac freezes (a real, open, unexplained problem in
this repo), doesn't file a bug — they uninstall. The reliability *reflexes*
are good: tap re-enable on timeout, disposable panels, fail-open silence
checks, the dedicated tap thread. What's missing is any way to *know*:
`NSLog` output reaches a human only when the app is launched from a terminal
with a stderr redirect, which no real user will ever do. There is no
persistent log, no crash reporting, no watchdog. The freeze investigation
stalled partly because when it happens, there is no evidence. Finding 8.

---

## 1b. Findings, ranked by how much more expensive they get after meetings ships

### 1. The agent turn has no owner — AppDelegate is becoming the place every feature must be threaded through

**What / pillar:** Trust and accuracy. `AppDelegate.handleAgentModeHotkeyUp`
(AppDelegate.swift:316-422) executes the routed actions with a growing
ladder of `if case` special cases: `.answerQuery`, `.createReminder`,
`.cancelReminder`, `.openedSiteButCouldNotSearch`, `.unknownWebsite`,
`.openSystemSettingsFallback` — six already, each carrying its own
`ownsTheEnding = true` and its own flash message, wrapped around a
synchronous `Bool`-returning executor for everything else. Async actions are
fired as unstructured `Task { await self.reminders.create(...) }` inside a
loop that continues immediately.

**Why it matters commercially:** Meetings adds at least `join_meeting` and
`next_meeting`, both async, both permission-gated, both message-producing —
two more rungs on the ladder, plus a `MeetingCoordinator` racing
`ReminderCoordinator` for the one shared pill. Two concrete bugs already
live in the current shape:

- *Multi-action ordering is broken for async actions.* "Remind me to call
  mom, then open Safari" opens Safari while the reminder flow is still
  asking its question — and the executor's loop result (`anyFailed` /
  `ownsTheEnding`) has already been decided before the reminder finished.
- *Two conversational actions in one utterance destroy each other.* "Remind
  me to call mom and remind me to email John": the loop spawns two Tasks;
  the second `askFollowUp` fires `finishFollowUp(.timedOut)` on the first
  (FloatingIndicatorWindow.swift:193), whose `.timedOut` fallback **silently
  creates the first reminder undated**. The user watched one question, and
  got a reminder they never confirmed with no time on it.

**What to do:** Make executing an agent turn a real component with a typed
outcome, before meetings adds to it. Sketch:

```swift
enum ActionOutcome {
    case done                       // silent success
    case failed(message: String)    // flash + counts against the turn
    case answered(String)           // display, long duration
    case conversation               // a coordinator owns the pill from here
}

@MainActor
final class AgentTurnRunner {
    // takes [AgentAction], runs them *sequentially*, awaiting each,
    // returns when the turn's ending is decided
    func run(_ actions: [AgentAction]) async
}
```

- Every action — including reminders, including future meetings — returns an
  `ActionOutcome` from one `async` path. `AgentExecutor.execute`'s sync Bool
  stays as the leaf for simple actions; the runner wraps it.
- Actions run **sequentially with await**, so "X then Y" happens in order
  and a conversational action holds the turn until its conversation ends.
  That fixes both bugs above as a side effect: the second reminder's
  question simply waits for the first.
- AppDelegate's ladder collapses to: transcribe → route → `runner.run()`.

**Cost:** Now: ~half a day, one new file plus deleting most of the ladder;
the eval doesn't touch this code so it can't regress routing. After
meetings: every meetings behaviour will have been written *into* the ladder
and has to be unpicked from it, and the coordinator-vs-coordinator races
will exist in the wild. This is the single highest-leverage change before
meetings.

### 2. The eval harness cannot run at HEAD — the accuracy pillar's main instrument is broken and nothing says so

**What / pillar:** Accuracy (and the meetings latency plan, which depends on
it). `eval/run_eval.py`'s `swift_helper` concatenates a hand-maintained list
of AgentRouter's dependencies (run_eval.py:138-146). AgentRouter gained
`LocalTimestamp` when reminders shipped; the list didn't. Result:
`python3 eval/run_eval.py --arm openai --model gpt-4o-mini` — the exact
command CLAUDE.md gives as the first verification layer — dies with a
compile error before making a single API call. It has been broken since the
reminders commit and nothing noticed, because the eval only runs when a
human runs it.

**Why it matters commercially:** The meetings design commits to "net zero
prompt growth, proven by the eval." That promise is currently unfalsifiable.
Worse, the failure mode generalizes: the comment in the harness itself says
"this list has to grow whenever the router gains a dependency" — a rule
recorded in exactly the place nobody reads while adding a dependency.

**What to do (three parts, all cheap):**

1. Add `(SRC / "LocalTimestamp.swift").read_text(),` to the parts list —
   the one-line fix. (Verified: with this line the harness runs and scores
   55/57.)
2. Add a smoke line to CLAUDE.md's verification section:
   `python3 eval/run_eval.py --arm openai --dry-run` — compiles the Swift
   helper, costs nothing, catches this class at commit time.
3. Longer term, kill the class: the harness reimplements
   `AgentRouter.parseAction`'s normalization in Python
   (`normalize()`, run_eval.py:399-446 — pane resolution, page-check,
   settings correction). That's a shadow implementation that must be
   hand-synced, and it will grow again when meetings adds tools. Move it
   into the Swift helper: add a `parse-actions` mode that feeds raw
   tool-call JSON through the *real* `parseAction` and prints the resulting
   `AgentAction`s; Python then only scores. One drift class deleted
   permanently.

**Cost:** Now: fix is one line, smoke check one line, the Swift-side
normalization maybe two hours. After meetings: the meetings token/accuracy
comparison gets run against a harness that silently diverges from
production parsing — the "measures the wrong thing while looking perfectly
healthy" failure the harness's own docstring warns about.

### 3. Recordings are never deleted — 390 audio files of everything ever dictated, on disk, unencrypted

**What / pillar:** Privacy. `AudioRecorder.start` writes each hold to
`FileManager.default.temporaryDirectory/sayline-<UUID>.wav`
(AudioRecorder.swift:59-60). No code path in the app deletes anything —
`grep -rn removeItem Sources/` returns nothing. This machine currently has
390 of them. macOS clears the temp directory only sporadically (typically on
reboot or after ~3 days untouched), so in practice this is a rolling archive
of the user's spoken words: passwords said aloud, medical notes, the lot.
The transcript history in UserDefaults (last 20, plaintext plist) is the
same category, smaller blast radius.

**Why it matters commercially:** The product's stated differentiation
includes privacy (BACKLOG.md turns down features over permission optics).
One Reddit post — "I found 400 recordings of myself in /tmp" — undoes all of
that positioning, and for corporate buyers it's a compliance non-starter.
This is also the cheapest finding in this review to fix.

**What to do:** Delete the file when the pipeline is done with it, in every
terminal path. Concretely: in `AppDelegate`, after `transcribe(fileURL:)`
returns (success or thrown error) the URL is dead weight — `try?
FileManager.default.removeItem(at: url)` in a `defer` inside each of the
three Tasks that consume a recording (dictation, agent, follow-up answer).
Keep exactly one: the `lastRecordingPath` debug affordance can keep the most
recent file and delete the previous one on the next recording, which
preserves the current debugging behaviour with a maximum of one file at
rest. Add a launch-time sweep (`sayline-*.wav` older than the last one) to
clean up the 390 already out there on upgrade.

**Cost:** Now: under an hour including the sweep. After meetings: identical
engineering cost, but every week of real usage grows the archive users will
eventually find, and "we fixed it in 1.2" reads very differently from never
having had it.

### 4. Follow-up ownership has races that end with spoken answers pasted into documents

**What / pillar:** Trust. Two related, both real in the current code:

- *Timeout mid-hold.* The claim "a pending question claims the next hold"
  is evaluated at hotkey-**up** (AppDelegate.swift:220), but the 20-second
  timer keeps running while the user holds and speaks. If the timer fires
  during the hold, `isAwaitingSpokenAnswer` is false at release, and the
  answer goes down the *dictation* path — "yes, delete it" is cleaned,
  historied, and typed into whatever app is focused. Meanwhile the question
  took its `.timedOut` fallback. The window is narrow (answering in the
  last seconds of the countdown) but the failure is exactly the one the
  design says must never happen ("someone answering 'yes' must not have
  the word typed into whatever they had focused").
- *Question replacement is silent.* `askFollowUp` finishes any live
  question as `.timedOut` (FloatingIndicatorWindow.swift:193). For the
  time-question, `.timedOut` **creates the reminder undated** — a fallback
  designed for "nobody answered", applied to "somebody asked something
  else". Combined with finding 1's unstructured Tasks, this is reachable
  from a single utterance today.

**What to do:** Claim the hold at hotkey-**down**: in `beginRecording`,
snapshot `isAnsweringFollowUp = indicatorWindow.isAwaitingSpokenAnswer` and
pause the follow-up timer for the duration of the hold (a hold is the
opposite of an absent user — the timeout exists for absence). Route on the
snapshot at hotkey-up. That closes the race in the direction that matters;
the reverse direction (question appears mid-hold) then safely stays
dictation, which is what the user intended when they started the hold.
Sequential execution from finding 1 removes the replacement case; if a
second conversational action can still arrive, make replacement take the
*declined* path, not `.timedOut`, so nothing is silently created.

**Cost:** Now: an hour, localized to AppDelegate + FloatingIndicatorWindow.
After meetings: meetings doubles the number of follow-up conversations
(join confirmation, permission offers, ambiguous-meeting questions), so the
same races get more chances to fire, in front of more users.

### 5. `empty_trash` is the one permanent action with no confirmation — the danger model is inconsistent

**What / pillar:** Trust. Deleting one reminder requires a destructive-styled
confirmation click. Emptying the Trash — potentially thousands of files,
genuinely unrecoverable — executes immediately from a voice transcript
(AgentExecutor.swift:400).

BACKLOG.md's stated reason for treating Empty Trash as safe is that it's
"recoverable, and the Trash's whole purpose." I'll argue with the reason as
recorded: *putting things in* the Trash is recoverable and is the Trash's
purpose; *emptying* it is the single irreversible step in that workflow —
it destroys the safety net rather than using it. The same paragraph rejects
voice file-delete because "a wrong 'delete that file' has no safety net";
a misheard phrase that empties the Trash deletes every file currently
relying on that net. The two decisions contradict each other.

The mitigating history: when `empty_trash` shipped (2026-08-04), the
follow-up primitive didn't exist, so confirmation would have been a real
design cost. It exists now, and the reminder flow proves it works.

**What to do:** Route `.emptyTrash` through the same confirm gate as a
reminder delete: `"Empty the Trash?"` / detail: item count and size (Finder
exposes both via the same AppleScript grant already held), destructive
styling, decline on timeout. ~20 lines in the finding-1 runner (or, today,
one more rung on the ladder — another reason to do finding 1 first).

**Cost:** Now: trivial. After meetings: the same trivial change, plus
whatever incident prompts it. The expected cost of deferral is entirely in
the tail: one misheard transcript on one user's machine.

### 6. The guardrails with the largest blast radius have no tests

**What / pillar:** Accuracy — specifically the "silent failure looks like
working software" class the review brief asks about. The eval's own README
draws the line correctly: the router eval scores what the model emits, the
`swiftc` suites cover what we do with it. But the suites cover three files,
and the *most* load-bearing deterministic logic isn't among them:

- **`TranscriptCleanupValidator` (357 lines, zero tests).** This is the
  named defense against the worst bug class in the product's history —
  the cleanup LLM silently deleting dictated content. It's a hand-rolled
  word-level diff with a compliance gate, false-start detection, casing
  smoothing — exactly the kind of code where an off-by-one *reintroduces
  silent data loss while every existing check stays green*, because no
  check looks at it. Its behaviour was validated by simulation in a chat
  session on 2026-08-08 and the cases were never frozen.
- **`VoiceCommand.detect` (zero tests)** — the word-count guard exists
  because "scratch that idea" scored 0.94 and would have deleted real
  work. That exact case is prose in PRODUCT.md instead of an executable
  check. Anyone tuning `matchThreshold` re-exposes the bug with no alarm.
- **`SettingsPaneCatalog.bundleID(forPaneName:)` (zero direct tests)** —
  the three-stage matcher with aliasing and singularization is only
  exercised through the paid, networked eval. Its pure logic (given a
  fixed pane list, which string matches what) is ideal `swiftc`-check
  material — including the regression recorded in results.md where alias
  changes made "banana settings" resolve to About.
- **`AgentRouter.panePhrase` and `WebsiteCatalog.spokenDomain`** — small,
  fiddly, history-of-bugs string code (spokenDomain's own doc comment
  lists two bugs found by testing), untested.

**What to do:** Three more check suites in the established pattern —
`cleanup-checks` (freeze the 2026-08-08 simulation cases: the answered
question, the mid-transcript "scratch the last sentence", the compliant
cleanups that must pass through), `command-checks` ("scratch that idea"
must not match; "scratch dat" must), `pane-match-checks` (feed a *fixed*
pane list so the suite doesn't depend on the host macOS). Add the three
lines to CLAUDE.md's verify section.

**Cost:** Now: the pattern exists, each suite is an afternoon at most, the
validator one somewhat more. After meetings: unchanged engineering cost,
but the validator and matcher get edited in the meantime (meetings' own
DESIGN promises tool-description trims and prompt work) with no net under
them.

### 7. Latency: production is unmeasured, and the token budget has no enforcement point

**What / pillar:** Latency. Two parts:

*Measurement.* The ~2s agent round trip is listed as an open problem, but
the app cannot say where those 2s go — transcription leg vs. routing leg
vs. HEAD-check vs. execution. Before optimizing anything (or accepting
meetings' additions), add per-stage wall-clock logging in the two pipeline
Tasks: hotkey-up → transcript, transcript → actions, actions → done, one
`NSLog` line per turn with all three numbers. It's ~15 lines, uses the
existing log-grep workflow, and turns "feels slow" into a diffable number.
The standing rule "a new feature must not make the system slower" is
currently enforceable only for prompt tokens; this makes it enforceable
end to end.

*Budget.* Median prompt tokens grew 1518 → 2353 in three days of feature
work — each step measured, the sum unremarked. Meetings' DESIGN already
commits to paying for its 335 new tokens by trimming the fat tools
(`close_app` 372, `find_file` 352, `open_folder` 306). Do the trim as its
own change *before* the meetings tools land, with the (fixed) eval proving
accuracy holds — that sequencing means when meetings ships, its eval diff
shows only meetings.

**Opportunity, not defect:** the transcription and routing legs are serial
today; they're inherently serial (routing needs the transcript), but the
HEAD verification of model-supplied URLs (up to 2.5s timeout,
AgentRouter.swift:459-501) sits inside the user-visible wait for *every*
action in the turn, even when the page-URL action is last. Resolving
playback/page checks concurrently with executing the earlier actions in
the turn is free latency back in exactly the multi-action case meetings
makes more common. Fits naturally into the finding-1 runner.

**Cost:** Now: logging ~15 lines; trim is already planned, just resequenced.
After meetings: the baseline is polluted — you can no longer tell meetings'
cost apart from the accumulated drift, which is how a 10% ceiling quietly
becomes 55%.

### 8. Reliability has reflexes but no eyes — nothing persists evidence, so the freeze stays unsolvable

**What / pillar:** Reliability. The open "Mac freezes during use" problem
has burned two investigations (event-tap starvation, panel leak — both
disproven). Each round stalls at the same wall: when it happens, there is
no record. `NSLog` goes to the unified system log and to stderr-if-
redirected; the documented workflow requires relaunching through a
redirect, which means the *one* session that freezes is usually a session
without logs.

**What to do:** Two small pieces, both worth having in the shipped product
anyway:

1. **Persistent file log.** A tiny append-only logger (or `Logger` with a
   file mirror) writing the same `Sayline:` lines to
   `~/Library/Logs/Sayline/sayline.log` with size-capped rotation. ~40
   lines, no dependency. Every future bug report — including the freeze —
   comes with history instead of anecdote.
2. **Stall watchdog.** The tap thread already exists; give it a heartbeat:
   main thread pings a timestamp every second (trivial timer); tap thread
   checks it each callback slice and logs — to the file — when the main
   thread has been unresponsive >2s, with the current state enum. If the
   freeze recurs, the log shows what the app was doing in the seconds
   before, which is precisely the evidence both previous theories lacked.

**Cost:** Now: half a day. After meetings: meetings adds EventKit calls
(new blocking IPC in the pipeline — the same class as the AX calls that
caused the last freeze theory) with no instrumentation watching, on more
users' machines.

### 9. Smaller items and opportunities

- **Same job, two ways — string normalization.** `AgentRouter.normalize`
  and `WebsiteCatalog.normalize` are byte-identical; `SettingsPaneCatalog`
  has a richer variant; `ReminderStore.tokens` and
  `SettingsPaneCatalog.tokens` are near-twins with different noise-word
  sets. Each is individually defensible; collectively they mean meetings'
  inevitable meeting-title matcher ("join the *design review*") becomes a
  sixth hand-rolled matcher. Opportunity: one `SpokenMatch` file offering
  `normalize`, `tokens(noiseWords:)`, and token-subset scoring; adopt it
  in new code (meetings) and fold old call sites in opportunistically.
  Cost now: an hour for the file. Not urgent; do it as the first meetings
  commit rather than as a refactor crusade.
- **The model can defeat fail-visibly by inventing a plausible pane.**
  Observed live this run: "Open banana settings" → model emits pane
  "General" → catalog maps it to About → the pane opens confidently
  wrong. The catalog itself correctly refuses "banana" (I probed it);
  the hole is the model substituting a real name. `correctedSettingsPane`
  deliberately doesn't second-guess confident picks — right call — but a
  cheap tightening exists: when `panePhrase(transcript)` yields a phrase
  the catalog *rejects*, and the model's pane differs wildly from that
  phrase (no token overlap), prefer the visible fallback over the model's
  guess. Small, deterministic, testable in the finding-6 suite.
- **`APIKeyProvider` statics are read from concurrent Tasks with no
  synchronization** (transcription and cleanup Tasks race the first
  resolve). Practically benign today (worst case: two Keychain reads);
  becomes a real prompt-storm risk again if a future path calls it
  off-main during the ad-hoc-signing era. A `static let` lazy or a lock is
  ten minutes; fine to batch with other work.
- **Two pasted API keys still need rotating** (already tracked in
  CLAUDE.md; repeating it because it's the only listed item with zero
  engineering cost and nonzero standing risk).
- **Duplicate line:** `indicatorWindow.updateHotkeySymbol` is called twice
  in `hotkeyOption.didSet` (AppDelegate.swift:37-38). Harmless; noting it
  only because it reads like a merge artifact and will confuse the next
  edit there.

---

## What's genuinely good (so it survives the refactors)

Worth saying explicitly, because several of these are unusual for a
one-developer, one-week agent surface and should be treated as load-bearing
conventions, not accidents:

- **The eval reads production's prompt and tools out of the real Swift.**
  Most teams copy the prompt into the harness and let it drift. Keep the
  principle; finding 2 just extends it to parsing.
- **Deterministic-beats-prompt is applied consistently** — the settings
  correction, the personal-pages table, `LocalTimestamp`, region fixes.
  This is the right architecture for a router: the LLM narrows, code
  decides.
- **Failure-mode writing.** The comments record disproven theories and
  live evidence with dates. CLAUDE.md + BACKLOG + DESIGN form an actual
  decision log. The cost of this review was halved by it.
- **The coordinator pattern (`ReminderCoordinator` / `ReminderStore`) is
  the right home for meetings** — `MeetingCoordinator` + a thin
  EventKit-only `CalendarStore` should mirror it exactly. The gap is
  above them (finding 1), not in them.
- **Fail open, visibly** is the right default for this product and is
  applied where it counts (silence gate, validator gate, page checks).

## Recommended order before starting meetings

1. Fix the eval harness (finding 2, parts 1–2) — everything else is
   measured through it.
2. Delete recordings (finding 3) — cheapest fix, worst optics.
3. Agent turn runner (finding 1) — meetings' foundation.
4. Follow-up claim-at-press + replacement semantics (finding 4).
5. Confirm `empty_trash` (finding 5) — trivial once 3's runner exists.
6. Check suites for validator / voice commands / pane matcher (finding 6).
7. Tool-description trim with before/after eval numbers (finding 7).
8. Persistent log + watchdog (finding 8) — before meetings adds EventKit
   IPC to the pipeline.

Items 1–5 are roughly two focused days. Everything on the list gets
strictly more expensive after meetings ships; nothing on it blocks
starting the meetings design work in parallel.
