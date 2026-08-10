# Meetings and reminders — agreed design

Settled in a grilling session on 2026-08-10, before any code. Twenty-one
decisions across five rounds. Recorded because the reasoning is the part
that gets lost — the decisions themselves will be obvious from the code,
but why we rejected the alternative will not.

Nothing here is built yet.

## Scope

Six commands.

| Say | Does |
|---|---|
| "Join my next meeting" | Opens the join link of the next meeting |
| "What's my next meeting" | Reads it back in the pill |
| "Remind me to X at Y" | Creates a dated reminder |
| "Remind me to X" | Asks for the time, then creates it |
| "Cancel that" | Deletes the reminder just made |
| "Cancel the X reminder" | Finds it by name and deletes it |

Deliberately out: creating calendar events, and "what are my reminders".
The first because a misheard word becomes a real event other people see.
The second because a list cannot fit in a 4.5-second flash — the same
reason the answer box is parked.

## Calendar

**Read only.** Reading unlocks most of the value. Writing is where a
transcription error becomes someone else's problem, and invites are not
recallable.

**All calendars count, but only events with a join link are joinable.** A
holiday has no Zoom link, so it cannot be the join target by definition.
This filters the noise with no configuration. If it proves wrong, a
calendar picker in settings is the fallback.

**"Next" means running now, or starting within 30 minutes.** Wide enough
to work when you are ten minutes late, narrow enough not to join
tomorrow's standup this afternoon.

**Two meetings in the window: soonest start wins.** Ties break toward the
one you have accepted over one you have not — EventKit exposes
participation status. The name is always said out loud when joining, so a
wrong pick is visible immediately rather than after you are in the call.

**No join link on the next event** is answered honestly: "Next: Design
review at 3:00 — no join link." Better than "no meetings found", which
would be false.

**The link lives in one of three fields.** EventKit exposes `url`,
`location` and `notes`. Zoom usually fills `url` and `location`; Google
Meet usually puts it in `notes`. Check all three in that order, and scan
`notes` for a known meeting-link pattern. Not a preference — just how the
providers differ.

**Meetings open in the browser.** No Zoom, Teams or Meet app is installed
on this machine, so an app-launch path would be dead code today.

## Reminders

**Apple Reminders, provisionally.** It already syncs to iPhone, already
fires notifications, and already has a UI. Building our own means
rebuilding three things Apple ships.

We drop it and build our own if either holds:

- The notification UI is not good enough.
- We want features it cannot do — the motivating example is asking to be
  reminded again when a reminder fires.

Named now, while we are honest. After building on it we will be attached
to it.

**Reminders go in the default list**, not a "Sayline" list. A separate
list means reminders made by voice sit somewhere you do not look, which
quietly defeats the point. Mixing with your own is correct, not a cost.

**The model turns "tomorrow at 3" into a timestamp; we validate it.** It
already handles messy phrasing, and every phrasing our own parser forgot
would be a bug. The current local time goes in the prompt, or "tomorrow"
means nothing. We check the result is sane — not in the past, not years
out — before acting.

**No time given: ask for it.** "Remind me to call the bank" gets "What
time?" rather than a silent undated reminder. If the answer is
unparseable, ask once more, then create it undated and say so. The
reminder is never lost — that is the whole reason for prompting.

**"Cancel that" is deliberately narrow:** only the last reminder Sayline
made, only within five minutes, only once. Past that, "that" is genuinely
ambiguous and a wrong guess deletes something real. Outside the window we
say what we think you meant instead of acting.

**"Cancel the X reminder" searches everything in the default list**, not
only what Sayline made. You will not remember which reminders came from
voice, so a tool that only cancelled its own would feel broken half the
time.

That reach is why matching is careful:

| Matches | Behaviour |
|---|---|
| Zero | Say so, do nothing |
| One | Delete it, say what was deleted |
| Several | Read back the closest, ask yes/no |

Asking beats guessing because there is no undo: EventKit deletion is
permanent, and "cancel that" covers the last thing *created*, not the
last thing deleted.

## Follow-up questions — a new primitive

Agent mode is one-shot today: speak, act, done. Two decisions above need
the agent to ask something and wait, which does not exist yet.

**Yes/no gets buttons in the pill. A value gets voice.** Reaching for a
hotkey to say "yes" is heavier than clicking, but a time is a real phrase
so it reuses hold-and-speak.

The rejected option was reopening the microphone automatically. It reads
better on paper, but it means Sayline starts listening without being
asked, and a dictation app should never do that quietly.

**A follow-up waits 20 seconds**, then takes the fallback: an undated
reminder, or a dismissed prompt. Long enough to think, short enough that
a forgotten pill is not left sitting there.

**The box and the pill are centred on one vertical axis**, symmetrically
one above the other, rather than both hanging off a left edge.

**The shape of a pill with buttons is not decided here.** It is an
*ungrillable* question — it cannot be settled by talking, only by looking
at it. A throwaway HTML prototype comes first, as it did for the pill
background.

## Permissions

**Asked on first use, never at launch.** Calendar access is requested the
first time someone says "join my meeting". People agree to a prompt they
asked for and refuse one that ambushes them. The cost is that the first
command is slower and needs a retry.

**Reminders needs full access, not write-only**, because cancel-by-name
has to read the list to find a match.

**On refusal, we say it once and offer to help:** "Sayline needs calendar
access — turn it on in System Settings. Open it for you?" and open it
only on a yes. Verified working:
`x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars`

Never re-prompt, never nag on later attempts. An app that keeps asking
after a no is the behaviour people uninstall over.

## Answers

**Answers flash in the pill for 4.5 seconds** using the existing
`flashMessage`. The Figma answer box stays parked.

Shipping the smaller thing first is deliberate. If the flash proves too
small — likely — that becomes the concrete reason to build the box, and
we will know exactly what it has to hold. Building it first risks
building the wrong box.

## Latency budget

Two new tools cost roughly **335 tokens on every request**, including
"open YouTube", which gains nothing from them. Measured, not estimated:
the tool schema is ~2219 of the ~2237-token prompt today.

That is a 15% increase against a standing 10% ceiling, so we pay for it
rather than accept it: write the new tools tight, and trim the fattest
existing ones. `close_app` is 372 tokens, `find_file` 352, `open_folder`
306 — all written before we knew what mattered.

The target is net zero prompt growth, proven by the eval. If that turns
out to be unreachable, the real number gets reported rather than quietly
spent.

## Open questions

None. The frontier was empty at the end of round 5.

Two things are deliberately deferred rather than unresolved: the pill's
button layout, which needs a prototype, and whether Apple Reminders
survives, which needs the build to exist first.
