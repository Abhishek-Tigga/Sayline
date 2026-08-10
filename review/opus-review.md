# Architecture review — Sayline

Written 2026-08-11 by Claude Opus 5, reviewing code it largely wrote itself
in the preceding week. That is the main thing to hold against it: I will be
softer on decisions I made than a stranger would be, and the failures I
talked myself into are exactly the ones I am least likely to see. Read this
alongside an independent review, not instead of one.

Scope: 6,635 lines, 39 Swift files, plus the eval harness. Evidence is from
running the code and reading the live system, not from memory.

---

## Part 1 — What this product is judged on

Accuracy and latency are the two named pillars. They are necessary and they
are not sufficient. Four more decide whether this sells, and three of them
currently have no owner in the codebase.

### 1. Trust — does it work every single time

The pillar above accuracy. A tool that is 98% accurate but fails visibly
once a day gets uninstalled; one that is 94% accurate and never surprises
you gets used forever. Dictation is muscle memory, and muscle memory cannot
survive "did that work?"

The specific enemy is **silent failure**. Every serious bug this week was
one: audio recorded to an empty file, a due date parsed to nil, a question
shown on a window nobody could see. In each case the app believed it had
succeeded.

*How you'd know it's healthy:* every failure path produces something the
user can see and something the log can explain. We are partway there.

### 2. Privacy — this app hears everything

A dictation tool has microphone access and sees every password field,
medical note and salary conversation its user speaks near. That is the most
sensitive permission on the machine, and it is the first thing a serious
buyer will ask about.

This is currently the weakest pillar. See findings 1 and 2 — they are not
theoretical.

### 3. Activation — surviving the permission gauntlet

macOS asks for Accessibility, Microphone, Reminders and soon Calendar. Each
prompt is a place someone quits. Nobody churns louder than a user who never
got the thing working once.

There is no onboarding flow, no permission status screen, and no way for a
user to see which permissions are missing and why they matter. The
first-run experience is currently "it silently does nothing".

### 4. Unit economics — what one user costs

Every dictation is a Whisper call; every agent command is a Whisper call
plus a router call at ~2,350 prompt tokens. That is a real per-user cost,
and it determines what you can charge.

Nothing in the codebase measures it. There is no counter, no logging of
token spend, no way to answer "what does a heavy user cost per month"
without guessing. You will need that number before you price anything.

### 5. Fix velocity — how fast a mistake stops hurting

Everything is compiled in: the site catalog, the personal-page URLs, the
settings panes. When LinkedIn moves a URL, the fix is a source change, a
release, App Store review, and waiting for users to update.

Competitors solving this with server-delivered config can fix the same
break in an afternoon. This is a structural disadvantage, and it grows with
every hardcoded table added.

### 6. Host stability — never break the user's Mac

The freeze. Still unexplained after two disproven theories. An app that
freezes the machine gets a one-star review that mentions freezing, and no
amount of accuracy recovers from that.

This deserves to be treated as existential rather than as a bug.

---

## Part 2 — Findings

Ranked by how much more expensive each becomes if left until after meetings
ships. Not by severity in the abstract.

### 1. Every recording ever made is still on disk — 514 MB, unencrypted

`AudioRecorder.start()` writes to `FileManager.default.temporaryDirectory`
and **nothing ever deletes it**. There is no `removeItem` call anywhere in
the codebase.

Measured on this machine right now:

```
383 files    514 MB    oldest Aug 9, newest Aug 11
```

Two days of use. Every word spoken into this app, as raw audio, sitting in
a directory that is not encrypted beyond the disk itself and is readable by
any process running as the user.

This is the single worst thing in the codebase. It is also a ten-line fix,
which is why it ranks first: the cost of fixing it is trivial and the cost
of shipping it is a headline.

**Fix:** delete the file when transcription completes, successfully or not.
Add a sweep at launch for orphans left by a crash. Consider whether the
file needs to touch disk at all — `AVAudioFile` is convenient, but an
in-memory buffer never leaks.

### 2. Transcript history is stored in plain UserDefaults

```
"com.abhishektigga.sayline.history" = {length = 4632, ...}
```

That is an unencrypted plist in the user's Library. Everything they have
dictated, in plaintext, readable by any process running as them and
included in unencrypted backups.

For a personal note-taking app that would be sloppy. For a tool people
dictate private things into, it is a defect.

**Fix:** Keychain for the payload, or an encrypted file, or a documented
retention limit with an off switch. The right answer depends on a product
decision nobody has made yet: does history exist for convenience or for
audit? If convenience, the honest option is to store much less.

### 3. There is no test target

The checks I added this week — `catalog-checks`, `consent-checks`,
`timestamp-checks` — are standalone `main.swift` files compiled by hand
with `swiftc`. They are real tests with real assertions and they have
caught real bugs, but:

- Nothing runs them automatically
- They are not in the Xcode project, so a refactor can break them silently
- Each recompiles its dependency from source, so they only work on files
  with few dependencies. That is why `LocalTimestamp` had to be split out
  of `AgentRouter` — not for design reasons, but so a test could compile.

That last point is the tell: **the test setup is already deforming the
architecture.** That gets worse with every file.

**Fix:** a real XCTest target in `project.yml`. The assertions already
exist; they need a home.

### 4. Prompt injection is about to become real, and meetings is the door

Today the router only ever sees the user's own speech. That is a closed
loop and the risk is low.

Meetings breaks it. Calendar events contain text written by other people —
titles, notes, invite descriptions — and the design has us reading the
notes field to find a join link. The moment any of that reaches the model,
untrusted text is in a loop that can open apps, open URLs and delete
reminders.

A calendar invite is trivially attacker-controlled: anyone who can send you
an invite can put text in it.

**Fix, before meetings ships:** event content is data, never instructions.
Extract the link with a regex, never hand raw notes to the model. If the
model must see event text, it must not be able to trigger a tool call from
the same turn. Decide this before writing the code, because retrofitting a
trust boundary is much harder than drawing one.

This is the finding I would most want a second opinion on, and the one most
likely to be missed by a reviewer looking only at what exists today.

### 5. `AppDelegate` is becoming the place things go when they have no home

499 lines, and it owns: hotkey wiring, recording lifecycle, transcription
orchestration, cleanup, AX insertion, agent dispatch, a debug menu harness,
and two window controllers. Thirteen stored properties.

The specific smell is in the dispatch loop — a chain of six `if case`
special cases that run before the generic executor:

```swift
if case .createReminder(...)  { ...; continue }
if case .cancelReminder(...)  { ...; continue }
if case .openedSiteButCouldNotSearch(...) { ...; continue }
if case .unknownWebsite(...)  { ...; continue }
if case .openSystemSettingsFallback(...) { ...; continue }
if case .answerQuery(...)     { ...; continue }
if !AgentExecutor.execute(action) { anyFailed = true }
```

I added two of those this week without noticing the pattern. The generic
executor handles the actions that need nothing; everything that needs a
message, a follow-up or async work jumps the queue. **The abstraction is
wrong** — `AgentExecutor.execute` returning `Bool` cannot express "this
action talks to the user" or "this action takes time".

Every new capability adds another `if case`. Meetings adds at least two.

**Fix:** let an action's handler own its outcome — result type instead of
`Bool`, async by default, and one dispatch path instead of two. This is the
cheapest to do now and the most annoying to do after meetings, because
meetings will add cases on both sides of the split.

### 6. `FloatingIndicatorWindow` now does four jobs

323 lines owning: `NSPanel` lifecycle, the follow-up state machine
(question, retry, single-fire guard, timeout), the notice state with its
own separate timeout, and mouse-event toggling.

The evidence that this is already a problem is the bug I fixed today: a
brief hotkey tap called `hide()`, which cleared a pending question, which
made the next hold silently become dictation. The fix was a guard inside
`hide()` — correct, but the reason it was needed is that **window
visibility and conversation state are tangled in one object**.

There are now two message systems that overlap: `flashMessage` puts text in
the pill, `showNotice` puts text in the box. Nothing says which to use. I
migrated the reminder flow from one to the other today and left every other
caller on the old one, so the codebase currently disagrees with itself.

**Fix:** pull the conversation state machine out of the window. The window
should render what it is told; something else should decide what is being
asked and for how long.

### 7. The eval harness reads Swift by concatenating source files

`run_eval.py` builds a temporary Swift program from a hand-maintained list
of files so it can print the real prompt and tools. Reading from source
rather than keeping a copy is the right instinct — a duplicated prompt
would drift immediately.

But the file list is manual, and it broke **twice today**: once when
`WebsiteCatalog` was needed, once when `LocalTimestamp` lived in a file the
harness did not compile. Both failed loudly, which is the saving grace, but
both cost a cycle.

**Fix:** compile the whole `Sources/Sayline` directory, or better, add a
tiny `--dump-config` flag to the app itself so the harness asks the real
binary rather than reconstructing it.

### 8. Two execution paths with no rule

Most actions run synchronously in `AgentExecutor`. Reminders run in
`ReminderCoordinator`, which is `@MainActor`, async, and owns its own UI.
`AgentExecutor` even has a branch for reminder cases whose only job is to
log that they should never arrive.

There is no stated rule for which an action uses. Meetings will have to
pick, and whoever writes it will pick by looking at whichever example they
happen to open first.

**Fix:** state the rule — actions that need permission, async work or a
conversation go one way, everything else the other — or unify them. Either
is fine. The current state, where the split exists but is undocumented, is
the worst of both.

### 9. Nothing measures what a user costs

No token counter, no request counter, no cost estimate. `PRODUCT.md` has a
cost model from 2026-08-04 that predates agent mode entirely and is now
wrong by a large factor: the router adds ~2,350 prompt tokens to every
agent command, which the old model does not account for.

You cannot price a product whose unit cost you cannot measure.

**Fix:** log tokens and estimated cost per request behind a debug flag, and
aggregate. Cheap to add now, and it turns pricing from an argument into
arithmetic.

### 10. Failure handling is inconsistent, and some of it is silent

13 uses of `try?` and 17 `catch` blocks, with no consistent policy about
which failures reach the user. Some paths flash a message, some only
`NSLog`, some do neither.

The pattern that works — established this week and worth generalising — is
*fail open, and say what happened*. It is applied in `AudioRecorder` and in
`verifiedPage`, and nowhere else deliberately.

**Fix:** a single convention for user-visible failure, applied everywhere,
so the answer to "what does the user see when this breaks" is never "it
depends who wrote it".

---

## Part 3 — What should not be changed

A review that only lists problems is misleading about where the risk is.

**The eval harness is the best thing here.** It reads the real prompt, it
mirrors production's URL checking, it refuses to record runs where too many
cases errored, and `results.md` carries the mistakes rather than hiding
them. It has repeatedly disproven my own confident guesses. Do not let a
refactor break it.

**Deterministic rules over prompt engineering.** Every routing fix by
rewording the prompt failed or regressed something else; every fix that
held was code. That pattern is written into `CLAUDE.md` and is worth
defending.

**The comments explain rejected alternatives, not just behaviour.** Several
of them prevented me from re-making a mistake later in the same week. They
are long, and they earn it.

**Fail open.** A silence gate that failed closed ate real dictation; a page
check that treated 503 as missing threw away correct URLs. Both were fixed
by letting the uncertain case through.

---

## If only three things get done

1. **Delete the audio files.** Ten lines, and it is the difference between
   a privacy story and a privacy incident.
2. **Draw the trust boundary before meetings.** Calendar text is written by
   other people; decide now that it is data and never instructions.
3. **Fix the dispatch abstraction.** It is the cheapest it will ever be
   today, and meetings will double the mess.
