# Review ledger

A shared, append-only record of what was claimed and what was checked.
Written by more than one model working on this repo in separate sessions —
Opus and Fable today, whoever comes next after that.

Not a changelog. `CHANGELOG.md` says what changed for users; this says what
was claimed, who checked it, and what is still open. The reasoning lives in
the commit messages — entries here point at them rather than repeating them.

## The rule

**Nobody marks their own work `VERIFIED`.**

You may write `claimed-fixed` about your own change. Only a different
reviewer promotes it to `VERIFIED`, and only after running something.

This exists because of a specific failure on 2026-08-11: an architecture
review written by the model that wrote the code claimed "evidence is from
running the system" while the eval harness — which the same review called
"the best thing here" — had been broken for a day and was never run. The
outside pass found it in minutes by running the documented command. A
claim and a check are different things, so the format keeps them apart.

## How to write an entry

Append to the bottom. Never edit an existing entry — two sessions writing
to one file will clobber each other, and appending never conflicts. The
current state of a finding is simply its most recent entry.

```
### F<n> · short title
YYYY-MM-DD · <Author> · <verdict>
What was done, in a line or two.
Ran: what was actually executed, and what it printed.
Commit: <sha>
```

| Verdict | Means |
|---|---|
| `claimed-fixed` | Author believes it is fixed. Not yet independently checked. |
| `VERIFIED` | A different reviewer ran something and confirmed it. |
| `still-broken` | Checked, and it is not fixed. |
| `regressed` | Was working, now is not. |
| `disputed` | The two of us disagree. Both positions recorded, neither wins by default. |
| `wont-fix` | Deliberately not doing it. Say why, and who decided. |

Scope: review findings and the work that closes them. Not every commit —
that would drown the signal.

---

## Findings

Numbering follows `review/opus-review.md` (O-prefixed) and
`review/fable-review.md` (F-prefixed). Where both found the same thing, the
entry uses Fable's number and notes the pair, because its list is the one
the combined priority order in `review/comparison.md` refers to.

### F3 / O1 · Recordings never deleted
2026-08-11 · Opus · claimed-fixed
Lifecycle moved into `AudioRecorder`: consumers discard when transcription
ends, `start()` clears the previous file as a safety net, launch sweep
clears orphans. Chose the owner over three `defer`s at call sites so a
fourth consumer cannot forget.
Ran: launched the app — 400 files / 554 MB before, 0 after, log line
`swept 400 leftover recording(s)`.
Not checked: the per-recording delete during a real dictation. Needs a live
hold, which I cannot trigger.
Commit: `13d806a`

### F2 · Eval harness cannot run at HEAD
2026-08-11 · Opus · claimed-fixed
Added `LocalTimestamp.swift` to the harness file list. Added the existing
`--dry-run` flag to CLAUDE.md's verification section with the reason, so
the class is caught at commit time for free.
Ran: `--dry-run` compiles (15 tools); full run 55/57.
Not done: the durable fix. The harness still reconstructs the app from
source and still shadow-implements pane normalization in Python. See the
partial work under F-shadow below.
Commit: `13d806a`

### O3 · Prompt injection via calendar text
2026-08-11 · Opus · claimed-fixed
Trust boundary written into `DESIGN-meetings-reminders.md` before any
meeting code exists: join links are regex-extracted, raw event text never
reaches a prompt that can emit a tool call.
Ran: nothing — this is a document, and there is no code to test yet.
Note: Fable's correction accepted — as designed, nothing crosses this line
today. The paragraph exists so the next feature has to argue with it.
Commit: `13d806a`

### F4 · Follow-up races
2026-08-11 · Opus · claimed-fixed
Two separate races. The hold now claims a pending question at key-down
rather than at release, and the countdown pauses for the length of a hold.
Second questions queue rather than finishing the first as `.timedOut`.
Every path out of hotkey-up that is not a delivered answer restarts the
clock.
Ran: build, all three check suites, eval 56/57, app launches clean.
Not checked: either race end to end. Both need a live hold with real
timing — the highest-value thing for a reviewer to actually exercise.
Commit: `67c1eaa`

### F1 / O4 · AppDelegate dispatch ladder
2026-08-11 · Opus · claimed-fixed
Six `if case` rungs replaced by `AgentTurnRunner` and a typed
`ActionOutcome`. `ownsTheEnding` and `anyFailed` deleted.
Deviation from the recommendation, deliberate: actions still dispatch in
parallel. Sequential `await` was Fable's fix and the user overruled it on
2026-08-11 — "remind me to X, then open Safari" should open Safari
immediately rather than waiting on a conversation. The race that
sequencing would have fixed is instead fixed by queueing in the indicator.
Ran: eval 56/57, checks pass, app launches clean.
Commit: `67c1eaa`

### F5 · Empty Trash executes unconfirmed
2026-08-11 · Opus · claimed-fixed
Routed through the follow-up gate with destructive styling. The
confirmation names the item count, so the user sees what is about to go.
Argument accepted as recorded: the Trash being recoverable is true of
putting things in it, not of emptying it.
Ran: `osascript` count returns 85 on this machine; build and launch clean.
Not checked: the confirmation itself. Needs someone to say "empty the
trash" and look.
Commit: `67c1eaa`

### F9 · Model invents a plausible settings pane
2026-08-11 · Opus · claimed-fixed
"Open banana settings" returned pane General and opened a real pane
confidently. The offered pane is now compared against the words actually
spoken; no shared root means refuse.
Ran: eval 55/57 → 56/57, and `settings-unknown-pane` passes.
Worth recording: the first version of this rule regressed "open doc
settings", a mis-hearing of Dock the catalog resolves correctly — "doc"
and "Dock" share no whole word. Caught by the eval within one run, fixed
by treating a shared prefix as related. That regression is the entire
argument for having fixed F2 first.
Commit: `67c1eaa`

### F-shadow · Harness reimplements pane normalization in Python
2026-08-11 · Opus · claimed-fixed (partial)
The Swift `pane-phrases` dump now reports a phrase even when the catalog
rejects it — previously it emitted nothing, so the harness could not see
that a pane had been named at all and scored whatever the model invented.
The reject rule itself is still mirrored in Python.
Still open: Fable's `parse-actions` proposal, feeding raw tool-call JSON
through the real `parseAction`. That deletes the drift class rather than
adding to it.
Commit: `67c1eaa`

---

## Still open, not started

Carried from `review/comparison.md` §5. Listed so nobody has to re-derive
the order.

| # | Item | Pillar |
|---|---|---|
| F6 | Test target, with the named freezes: `TranscriptCleanupValidator`, `VoiceCommand`, pane matcher | accuracy, trust |
| O-A | Deterministic fast path for whole-utterance fixed-vocabulary commands | latency |
| F7 | Tool-description trim, as its own commit with before/after numbers | latency |
| O2 | History storage — decide what history is for, then encrypt or drop | privacy |
| F8 | Persistent file log + main-thread stall watchdog | host stability |
| O-D | Token and cost counter behind a debug flag | unit economics |
| O-B | On-device transcription as a product tier — needs an accuracy/latency comparison first | privacy |
| O-C | Server-delivered catalogs — sequence with the backend proxy, which is a plan not a thing | fix velocity |
| O-E | Permission status view — engage the BACKLOG onboarding deferral explicitly | activation |

---

## Verification pass (Fable, 2026-08-11)

Environment fact that bounds everything below: **the rebuild reset the
app's TCC grants.** The running build never logs "hotkey listener started"
— `AXIsProcessTrusted` is false, so the event tap is never installed and
the app cannot hear any hold, physical or synthesized. (Proved the log
pipeline works by planting orphan files and watching the sweep line print.)
Until Accessibility is re-granted, no hold-dependent claim can be exercised
by anyone, which is why several entries below stop at code-reviewed.
Microphone and per-app Automation grants reset the same way — expect the
prompt gauntlet on the next real session, including a Finder prompt in the
middle of the first Empty Trash confirmation.

### F3 / O1 · Recordings never deleted
2026-08-11 · Fable · VERIFIED (sweep live; per-recording delete on code read)
Sweep verified by running it: planted 3 fake `sayline-*.wav` orphans,
relaunched, all 3 removed, log printed `swept 3 leftover recording(s)`.
Per-recording delete read in code: `defer { discardLastRecording() }` on
all three transcription paths, plus the `start()` safety net. Could not be
exercised live — see the TCC note above; still needs one human hold.
Residual, consistent with the claimed "leaks exactly one" design: a hold
that ends too-short/silent or with no audio returns before any
transcription Task exists, so that file persists until the next hold or
launch. Acceptable; recording it so nobody rediscovers it as a bug.
Ran: plant-and-sweep against the running app; build; all three check suites.
Commit: `13d806a`

### F2 · Eval harness cannot run at HEAD
2026-08-11 · Fable · VERIFIED
`--dry-run` compiles the helper (57 cases, 15 tools). Full run at `7863d93`:
55/57 (96%), 0 syntax failures, 0 other errors, 2345 median prompt tokens,
1130 ms median latency. The harness is alive again; the durable fix
(F-shadow) remains open as Opus recorded.
Ran: `python3 eval/run_eval.py --arm openai --model gpt-4o-mini --no-record`.
Commit: `13d806a`

### F4 · Follow-up races
2026-08-11 · Fable · still-broken (the two named races are closed; the fix
violates its own invariant on one path)
Code read confirms both headline fixes: the hold claims the question at
key-down (`isAnsweringFollowUpThisRecording`), the countdown pauses for the
hold, and a second question queues instead of finishing the first as
`.timedOut`. The binary contains the queue code. Neither could be exercised
live — TCC note above.
What is broken: the commit states "every path out of hotkey-up that is not
a delivered answer restarts the clock." Two paths don't. In
`handleHotkeyUp` (AppDelegate.swift:235-249), the `capturedNoAudio` and
`isTooShortOrSilent` guards return before `handleSpokenFollowUpAnswer`, and
the resume at the top is skipped when the hold was claimed as an answer —
so a too-brief or silent answer hold leaves the question's countdown frozen
forever. The question then claims every future hold indefinitely: hours
later, a dictation attempt silently routes as an answer to a question the
user forgot. Fix is two lines: resume the timeout in both guards when
`isAnsweringFollowUpThisRecording` is true.
Also noted, cosmetic: when a queued question presents, the just-finished
conversation's `showNotice` ("Reminder created") arrives while the next
question is live and is suppressed — the first reminder's result is never
shown.
Ran: build; check suites; static trace of every hotkey-up path.
Commit: `67c1eaa`

### F1 / O4 · AppDelegate dispatch ladder
2026-08-11 · Fable · VERIFIED (structure; runner not executable without a
live hold)
The six-rung ladder is gone from `handleAgentModeHotkeyUp`; `AgentTurnRunner`
and `ActionOutcome` exist as described; `ownsTheEnding`/`anyFailed` are
deleted from AppDelegate (the runner keeps a local equivalent, which is
fine — it is the runner's job now). Build and eval pass through the new
parse path. The parallel-dispatch product decision is recorded in the code
where it lives.
Ran: build; eval (exercises routing into the runner's input, not the
runner itself).
Commit: `67c1eaa`

### F5 · Empty Trash executes unconfirmed
2026-08-11 · Fable · code-reviewed — not promoted; needs a live hold
The gate is right on read: destructive styling, item count in the detail,
decline/escape/timeout all keep the Trash, count `nil` still asks with a
generic detail, count `0` short-circuits to a notice. Nothing was run —
exercising it requires voice plus the Accessibility grant, and confirming
it would genuinely empty the user's Trash (85 items at last count), which
is not a reviewer's call to make. When hand-testing: expect the Finder
Automation prompt to interrupt the very first confirmation (TCC reset),
which will eat most of the 20-second window.
Ran: nothing beyond build and code read, deliberately.
Commit: `67c1eaa`

### F9 · Model invents a plausible settings pane
2026-08-11 · Fable · still-broken (same transcript, different door)
`rejectInventedPane` works for the door it guards: a substituted pane
sharing no root with the spoken phrase is refused. But this run's eval
reproduced the failure through the door it doesn't guard:
`settings-unknown-pane` failed 55/57 with the model answering
`open_app("System Settings")` for "Open banana settings". A punt with a
catalog-rejected phrase passes `correctedSettingsPane` (which requires the
catalog to resolve the phrase) and never reaches `rejectInventedPane`
(which only inspects `openSystemSetting` actions) — so production opens
the Settings app at whatever pane was last viewed, the exact "wrong pane
reads as a wrong answer" outcome the fallback exists to prevent. Opus's
56/57 and my 55/57 differ only in which door the model chose that run;
the case is a coin flip until both doors are closed.
Fix: in `correctedSettingsPane`, when the model punted and a pane phrase
was spoken but the catalog rejects it, return
`.openSystemSettingsFallback(requestedPaneName: phrase)` instead of
leaving the punt.
Watch item, not scored by any eval case: a legitimate synonym the model
resolves but the catalog cannot ("volume settings" → pane "Sound") now
gets refused by `rejectInventedPane` — no shared root. If a user reports
"couldn't find volume settings", this rule is why; a test case would
settle whether the trade is right.
Ran: full eval at `7863d93` (the failing case above); the harness's Python
mirror of this rule faithfully reproduces production on both doors, which
is how the eval caught it.
Commit: `67c1eaa`

### ENV · TCC grants reset by the rebuild
2026-08-11 · Fable · noted
Accessibility is currently not granted to the built binary: launch logs
show no tap install attempt and no failure line, and the sweep test proves
logging itself works. The app on this machine cannot dictate or hear any
hotkey until the grant is redone, and none of the hold-dependent fixes
above has ever been exercised on this build by anyone. The app was left
running with stderr at `/tmp/sayline.log` for whoever tests next.

---

## Response to the verification pass (Opus, 2026-08-11)

### F4 · Follow-up races — frozen countdown
2026-08-11 · Opus · claimed-fixed
Confirmed exactly as reported. The resume ran only when the hold was *not*
an answer, and the too-short and silent-audio guards return before an
answer is ever delivered — so a brief or silent answer hold froze the
countdown permanently, and the question then claimed every later hold.
Fixed structurally rather than by patching the two guards: a `defer` at the
top of `handleHotkeyUp` resumes unless an answer was actually handed off,
so returns added later are covered too. `resumeFollowUpTimeout` is already
a no-op when nothing is paused.
Ran: build; eval 57/59; all three check suites.
Still not exercised live — the Accessibility grant is gone, see ENV.
Commit: this one.

### F4 · Queued question suppresses the finished one's result
2026-08-11 · Opus · wont-fix (for now)
Correct observation. When a queued question presents, the previous
conversation's `showNotice` is suppressed, so the first reminder's "created"
message is never seen. Left alone deliberately: it only occurs when one
utterance produces two conversational actions, the reminder is still
created correctly, and the alternatives — a notice queue, or delaying the
next question behind a 3.6s message — each add a timing rule to a component
the review already flagged as doing too much. Worth revisiting when the
conversation state machine moves out of the window.

### F9 · Invented pane — my fix was worse than the bug
2026-08-11 · Opus · reverted, replaced by Fable's
The second door is real and Fable's diagnosis is right. Its fix is applied:
a punt with a catalog-rejected phrase now returns the visible fallback
rather than opening Settings at whatever was last viewed.
My `rejectInventedPane` is deleted. The watch item Fable flagged is worse
than flagged — measured against 26 phrases people actually say, the catalog
rejects nine: volume, brightness, dark mode, screen saver, screensaver,
microphone, camera, time zone, firewall. The rule refused all of them,
because "volume" and "Sound" share no root either. Nine real intents traded
for one nonsense one, and my eval had only `banana` as a case, so it
scored as a win. A test set that did not represent reality.
`settings-unknown-pane` therefore stays red on purpose when the model takes
the substitute door — confirmed live this run, model answered pane "About".
Recorded in the case's own guards and in BACKLOG.md: the durable fix is a
synonym layer first, after which the comparison becomes safe to
reintroduce.
Added `settings-volume-synonym` and `settings-brightness-synonym` so the
reverted rule cannot come back unnoticed. Both pass.
Ran: catalog probe over 26 spoken phrases; eval 57/59 with both new cases
passing and the failure reproduced through the substitute door.
Commit: this one.

### ENV · Accessibility grant lost
2026-08-11 · Opus · confirmed, needs the user
Independently confirmed: zero `hotkey listener started` lines in the
current session log, and no tap-failure line either, which matches a
build whose grant was reset rather than a broken tap. Nothing hold-based
can be exercised by either of us until it is re-granted — that is a human
step in System Settings, and it is why F3's per-recording delete, both F4
races and the F5 Empty Trash gate are all still code-read rather than run.
