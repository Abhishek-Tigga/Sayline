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
