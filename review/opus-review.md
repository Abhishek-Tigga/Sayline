# Architecture review — Sayline

Written 2026-08-11 by Claude Opus 5, reviewing code it largely wrote itself
in the preceding week. That is the main thing to hold against it: I will be
softer on decisions I made than a stranger would be, and the things I talked
myself into are exactly the ones I cannot see. Read this alongside an
independent review, not instead of one.

Scope: 6,635 lines, 39 Swift files, plus the eval harness. Evidence is from
running the system, not from memory.

Two disclosures about this document specifically. Its first draft was all
defects and no opportunities — the two largest items in Part 3 were missing
entirely, including one that serves the top-named pillar. And it did not tag
findings by pillar or state cost now-versus-later, both of which I had asked
the other reviewer to do. Fixed here; worth knowing the first pass failed its
own standard.

---

## Part 1 — What this product is judged on

Accuracy and latency are the two named pillars. Necessary, not sufficient.
Six more decide whether this sells, and three have no owner in the code.

### 1. Trust — does it work every single time

The pillar above accuracy. A tool that is 98% accurate but fails visibly once
a day gets uninstalled; one that is 94% accurate and never surprises you gets
used forever. Dictation is muscle memory, and muscle memory cannot survive
"did that work?"

The enemy is **silent failure**. Every serious bug this week was one: audio
recorded to an empty file, a due date parsed to nil, a question drawn on a
window nobody could see. In each case the app believed it had succeeded.

*Owner in code:* partial. Failures are increasingly visible, but there is no
policy — see finding 6.

### 2. Privacy — this app hears everything

A dictation tool holds microphone access and sees every password field,
medical note and salary conversation its user speaks near. It is the most
sensitive permission on the machine and the first thing a serious buyer asks
about.

*Owner in code:* none, and actively negative. See findings 1 and 2.

### 3. Activation — surviving the permission gauntlet

Accessibility, Microphone, Reminders, soon Calendar. Each prompt is a place
someone quits, and nobody churns louder than a user who never got it working
once.

*Owner in code:* none. No onboarding, no permission status view, no way to
see what is missing or why it matters. First run is "it silently does
nothing".

### 4. Unit economics — what one user costs

Every dictation is a Whisper call; every agent command is Whisper plus a
router call at ~2,350 prompt tokens. That determines what you can charge.

*Owner in code:* none. No counter, no token logging. `PRODUCT.md`'s cost
model predates agent mode and is now wrong by a large factor.

### 5. Fix velocity — how fast a mistake stops hurting

Site catalog, personal-page URLs, settings panes: all compiled in. When
LinkedIn moves a URL the fix is a release and an App Store review.
Competitors shipping server-side config fix the same break in an afternoon.

*Owner in code:* none, and it worsens with every hardcoded table.

### 6. Host stability — never break the user's Mac

The freeze, still unexplained after two disproven theories. An app that
freezes the machine earns a one-star review that says "freezes", and accuracy
does not recover from that.

*Owner in code:* one leak probe, left in place. Treat as existential.

---

## Part 2 — Defects

Ranked by how much more expensive each gets if left until after meetings
ships.

### 1. Every recording ever made is still on disk — 514 MB, unencrypted
**Pillar: privacy.** Cost now: ~10 lines. Cost later: unchanged, but the
exposure compounds daily.

`AudioRecorder.start()` writes to `FileManager.default.temporaryDirectory`
and **nothing ever deletes it**. There is no `removeItem` call anywhere in
the codebase.

```
383 files    514 MB    oldest Aug 9, newest Aug 11
```

Two days. Every word spoken into this app, as raw audio, readable by any
process running as the user and swept into unencrypted backups.

*Commercially:* this is the difference between a privacy page and a privacy
incident. It is also the single cheapest fix in this document, which is why
it ranks first.

*Do this:* delete the file in a `defer` at the end of every transcription
path, success or failure. Sweep `sayline-*.wav` at launch for orphans left by
a crash. Then ask whether it needs to touch disk at all — `AVAudioFile` is
convenient, but a file that is never written cannot leak.

### 2. Transcript history is stored in plain UserDefaults
**Pillar: privacy.** Cost now: half a day. Cost later: the same, plus every
user who accumulated history under the old scheme.

```
"com.abhishektigga.sayline.history" = {length = 4632, ...}
```

An unencrypted plist of everything the user has dictated.

*Commercially:* "where is my dictation stored" is a question you will be
asked by anyone evaluating this for work. Right now the honest answer is bad.

*Do this:* decide first what history is *for*. If convenience, keep 20
entries, encrypt at rest, and add a clear-history control. If audit, that is
a different feature with different storage. The current state is the default
that nobody chose.

### 3. Prompt injection becomes real the moment meetings ships
**Pillar: trust, privacy.** Cost now: a design decision. Cost later: a
retrofit of a trust boundary, which is the expensive kind.

Today the router only sees the user's own speech — a closed loop, low risk.

Meetings breaks it. Calendar events carry text written by other people, and
the design has us reading the notes field for a join link. Anyone who can
send you an invite can put words in it, and those words would reach a loop
that opens apps, opens URLs and deletes reminders.

*Do this, before writing meeting code:* extract links with a regex; never
hand raw event text to the model. If the model must see event text, it must
not be able to emit a tool call in the same turn. Write the rule into
`DESIGN-meetings-reminders.md` now, while it costs a paragraph.

This is the finding I most want a second opinion on — it is about code that
does not exist yet, so a reviewer reading only what is there will miss it.

### 4. `AppDelegate` is where things go when they have no home
**Pillar: trust (indirectly — this is where silent bugs breed).** Cost now:
a day. Cost later: meetings adds cases on both sides of the split, so
roughly double.

499 lines owning hotkey wiring, recording lifecycle, transcription,
cleanup, AX insertion, agent dispatch, a debug harness and two window
controllers. Thirteen stored properties.

The smell is concrete — six `if case` special cases before the generic
executor:

```swift
if case .createReminder(...)  { ...; continue }
if case .cancelReminder(...)  { ...; continue }
if case .openedSiteButCouldNotSearch(...) { ...; continue }
if case .unknownWebsite(...)  { ...; continue }
if case .openSystemSettingsFallback(...) { ...; continue }
if case .answerQuery(...)     { ...; continue }
if !AgentExecutor.execute(action) { anyFailed = true }
```

I added two of those this week without noticing the pattern. The generic path
handles actions that need nothing; anything needing a message, a follow-up or
async work jumps the queue. **The abstraction is wrong**: `execute -> Bool`
cannot express "this talks to the user" or "this takes time".

*Do this:*

```swift
enum ActionOutcome {
    case done                    // silent success, caller may hide
    case reported                // handler already showed the user something
    case awaitingAnswer          // a question is up; do not touch the pill
    case failed(String)          // message for the user
}

protocol ActionHandler {
    func run(_ action: AgentAction) async -> ActionOutcome
}
```

One dispatch path, async by default, outcome decided by the handler. The
`if case` chain disappears; `ownsTheEnding` — a flag I added today to paper
over exactly this — disappears with it.

### 5. `FloatingIndicatorWindow` does four jobs
**Pillar: trust.** Cost now: half a day. Cost later: meetings adds a third
message type.

323 lines owning `NSPanel` lifecycle, the follow-up state machine (question,
retry, single-fire guard, timeout), the notice state with its own separate
timeout, and mouse-event toggling.

The proof it is already a problem is today's bug: a brief hotkey tap called
`hide()`, which cleared a pending question, which made the next hold silently
become dictation. The fix was a guard inside `hide()` — correct, but needed
only because **window visibility and conversation state live in one object**.

There are now two overlapping message systems. `flashMessage` writes to the
pill, `showNotice` writes to the box, and nothing says which to use. I
migrated the reminder flow to the second one today and left every other
caller on the first, so the codebase currently disagrees with itself.

*Do this:* extract a `ConversationController` owning pending question,
retry count, timeouts and the single-fire guard. The window drops to one
entry point — `render(_ state: IndicatorState)` — and holds no policy. Then
delete `flashMessage`, or define in one sentence when each is correct.

### 6. Failure handling has no policy
**Pillar: trust.** Cost now: a day. Cost later: proportional to how many more
handlers exist.

13 `try?` and 17 `catch` blocks, with no rule about which failures reach the
user. Some flash a message, some only `NSLog`, some do neither.

*Do this:* one convention, applied everywhere, so "what does the user see
when this breaks" is never "depends who wrote it". The pattern that works is
already here — *fail open, and say what happened* — it just is not general.

### 7. There is no test target
**Pillar: trust.** Cost now: two hours. Cost later: the same, plus everything
that broke unnoticed meanwhile.

`catalog-checks`, `consent-checks` and `timestamp-checks` are standalone
`main.swift` files compiled by hand. Real assertions that caught real bugs,
but nothing runs them automatically and they are not in the project, so a
refactor breaks them silently.

The tell that this already costs something: each compiles its dependency from
source, so they only work on files with few dependencies — which is why
`LocalTimestamp` had to be split out of `AgentRouter`. Not a design decision.
**The test setup is already deforming the architecture.**

*Do this:* an XCTest target in `project.yml`. The assertions exist; they need
a home.

### 8. The eval harness reconstructs the app instead of asking it
**Pillar: accuracy.** Cost now: an hour. Cost later: another broken cycle
each time a file moves.

`run_eval.py` concatenates a hand-maintained list of Swift files to print the
real prompt and tools. Reading from source is the right instinct — a copied
prompt would drift immediately — but the list is manual and broke **twice
today**.

*Do this:* add a `--dump-config` flag to the app itself and have the harness
run the real binary. Removes the file list, and guarantees the eval sees
exactly what production sends.

### 9. Two execution paths with no stated rule
**Pillar: trust.** Cost now: an hour to document, a day to unify. Cost later:
meetings picks one by coin flip.

Most actions run synchronously in `AgentExecutor`; reminders run in
`@MainActor` `ReminderCoordinator`. `AgentExecutor` even carries a branch for
reminder cases whose only job is to log that they should never arrive.

Finding 4 dissolves this. If it is not done, write the rule down instead.

---

## Part 3 — Opportunities

Not defects. Nothing here is broken; each would move a pillar. My first draft
had none of these, and the first two are the largest items in this document.

### A. Skip the router for commands we can already recognise
**Pillar: latency — the top named one.** Cost now: a day. Value: immediate.

Every agent command pays a round trip to OpenAI. Measured median **1,220–
1,352 ms**, and that is the floor, not the tail.

But **18 of 57 test cases are fixed-vocabulary commands**: "Open Safari",
"Close Finder", "Lock screen", "What's my battery". These need no
intelligence. The app already owns the vocabulary — the installed app list,
`SettingsPaneCatalog`, `WebsiteCatalog` — and matches against it *after* the
model answers.

*Do this:* try a deterministic match first, and only call the router when it
misses. "Open Safari" becomes roughly instant; anything ambiguous is
unaffected because it falls through unchanged.

The eval already makes this safe to attempt: run it before and after, and any
case the fast path steals incorrectly shows up as a regression. **This is the
single largest latency win available, and it costs nothing per request** —
the opposite of every other latency lever, which trade accuracy or money.

Do it before meetings. Afterwards there are two more command families to
teach it.

### B. On-device transcription is 80% built and hidden
**Pillar: privacy, and unit economics.** Cost now: mostly product work, the
engine exists.

`WhisperKitTranscriber.swift` is real, integrated, and behind an opt-in
toggle almost nobody will find. "Your audio never leaves your Mac" is the
strongest possible answer to the privacy question — and it is already
written.

*Commercially:* it is a tier. Local for the privacy-conscious and for
enterprise buyers who cannot send audio anywhere; cloud for speed. It also
removes the per-dictation Whisper cost for those users, which changes the
unit economics of your cheapest plan.

*Do this:* measure local accuracy and latency against cloud on the same
audio — that comparison does not exist today and everything else depends on
it. Then surface the choice as a product decision rather than a settings
checkbox.

The risk of leaving it buried is real: a competitor ships "fully local
dictation" as a headline and you are left explaining that you had it all
along.

### C. Move the catalogs to server-delivered config
**Pillar: fix velocity.** Cost now: a day, plus a static file. Cost later:
grows with every hardcoded table added.

Discussed and agreed as the right eventual shape. The app fetches a JSON
catalog on launch, caches it, and falls back to its built-in copy if the
fetch fails. LinkedIn moves a URL, you edit one file, everyone is fixed
within a day — no release, no review.

You are already building backend infrastructure, so the marginal cost is one
endpoint. This is most of VoiceOS's plugin advantage without a plugin system
or its security surface.

*Caveat worth stating:* it makes the app depend on your server for good
behaviour, and a bad file breaks everyone at once. Keeping the built-in copy
as fallback covers that, and a version check covers rollback.

### D. Measure what a user costs
**Pillar: unit economics.** Cost now: two hours.

Log tokens and estimated cost per request behind a debug flag, and aggregate.
Turns pricing from an argument into arithmetic. You will need the number
before you can pick a plan price, and it is much easier to add now than to
backfill from logs that never recorded it.

### E. Give activation an owner
**Pillar: activation.** Cost now: a few days. Cost later: the same, but every
user acquired meanwhile hit the current experience.

There is no first-run flow. A user who denies Accessibility gets an app that
silently does nothing, with no indication why. Meetings will add a fourth
prompt to a gauntlet that already has three.

*Do this:* a permission status view — what is granted, what is missing, what
each unlocks, and a button that opens the right pane. The deep links are
already proven working for Reminders and Calendar. This is the cheapest
retention work available, because it is entirely about users who wanted the
product and could not reach it.

---

## Part 4 — What should not be changed

A review listing only problems misleads about where the risk is.

**The eval harness is the best thing here.** It reads the real prompt,
mirrors production's URL checking, refuses to record runs where too many
cases errored, and `results.md` carries the mistakes rather than hiding them.
It has repeatedly disproven my own confident guesses. Finding 8 improves it —
nothing should break it.

**Deterministic rules over prompt engineering.** Every routing fix by
rewording the prompt failed or regressed something else; every fix that held
was code.

**Comments that record rejected alternatives.** Several stopped me re-making
a mistake later in the same week. They are long and they earn it.

**Fail open.** A silence gate that failed closed ate real dictation; a page
check treating 503 as missing threw away correct URLs.

---

## If only four things get done

1. **Delete the audio files.** *(privacy)* Ten lines between a privacy page
   and a privacy incident.
2. **Draw the trust boundary before meetings.** *(trust)* Calendar text is
   written by other people. A paragraph now, a retrofit later.
3. **Fix the dispatch abstraction.** *(trust)* Cheapest it will ever be;
   meetings doubles the mess.
4. **Build the deterministic fast path.** *(latency)* The largest win on the
   top-named pillar, and it costs nothing per request.
