# Fable — design review and simplicity audit, before any code exists

Open `/Users/abhishektigga/Documents/Dictation/Sayline`.

You are reviewing a **design note, not an implementation**. This is
deliberate. The last round shipped code first and a review afterwards, and
the review could not catch the actual problem — a whole category of user
command the architecture had no room for. Nobody notices a missing category
by reading code that already assumes it does not exist.

So the code is not written yet. Your findings change what gets built.

## Read first, in this order

1. `DESIGN-media-and-web.md` — the note under review
2. `CLAUDE.md` — build, verification layers, and the conventions that were
   earned the hard way
3. `review/LEDGER.md` — what has been claimed and what has been checked
4. `Sources/Sayline/AgentAction.swift`, `AgentExecutor.swift`,
   `AgentRouter.swift` — the vocabulary the design has to extend
5. `Sources/Sayline/FollowUp.swift` — the follow-up primitive the design
   leans on
6. `Sources/Sayline/MeetingStore.swift`, `CalendarSetup.swift`,
   `CalendarScope.swift` — for the calendar half

## Your main job

**Find the categories that are still missing.**

The design adds media control because a user said "stop the music" and got
a new browser tab. That gap existed for weeks and was invisible until it was
hit in person. Open question 2 in the note asks the same thing forward:
what *else* does a person say to a voice agent that names no destination
and assumes something already on screen?

Reading the note and confirming it is coherent is the low-value outcome.
Naming the third category — the one neither of us has thought of — is why
this review happens before the code.

## The load-bearing unknown

Measured, not assumed: posting `NX_KEYTYPE_PLAY` **resumed** a paused
Chrome/YouTube tab from silence, and three further presses **failed to
pause it again**. Same key, same code path.

If media keys cannot reliably pause a background browser tab, the user's
first decision — control anything, anywhere — may not be deliverable by
this mechanism, and the design needs rewriting rather than patching. The
probes are in the scratchpad and the results are quoted in the note. Say
plainly if you think the conclusion drawn from them is wrong.

## The second load-bearing unknown: playing music without interrupting

The user's goal is that "play some lo-fi" should not throw them out of what
they are doing. Picture-in-Picture was the proposed shape.

Five probes establish that YouTube will not play inside a `WKWebView` at
all — error 152, an embedding refusal, reproduced with the official IFrame
API and a freshly fetched live video ID. A player window we own is out.

The browser routes trade off against each other: a background tab keeps
focus but does not autoplay; a foreground tab plays but costs about six
seconds of the user's screen. Playback does survive losing focus, which is
what makes "open, wait for real audio, hand focus back" viable.

Read that section of the design note carefully and challenge it. If
`WKWebView` is not actually a dead end, or there is a legitimate route none
of the five probes covered, that finding is worth more than everything else
in this review.

## Second job: is this codebase more complicated than it needs to be?

The owner is a PM learning to code hands-on, and has to be able to read,
change and maintain everything here alone. Complexity he cannot follow is a
defect even when it is technically correct.

So: **find the places where something simpler would work just as well.**
Name them, rank them, and show the simpler version.

Look for:

- Abstractions with one caller that could be inlined
- Two things doing one job, or one thing doing two
- Files that exist only because something was split too early
- Names that need a comment to be understood, where a better name would not
- State stored in more than one place
- Anything a reader has to hold three files in their head to follow

**Do not make the changes.** Hand back a ranked list, with the simpler
version written out for the top few. This is deliberate:

1. Nobody verifies their own work — the rule in `review/LEDGER.md`. A
   reviewer who also refactors leaves nothing independently checked.
2. The user is about to test new media and calendar behaviour. A cleanup
   landing in the same build makes a failure impossible to attribute.
3. Coverage is uneven. `WebsiteCatalog`, `FollowUp`, `LocalTimestamp`,
   `Meeting`, `MeetingLink`, `CalendarScope` and `FastRoute` all have
   runnable checks. `AppDelegate`, every SwiftUI view, `MeetingStore` and
   the executor's side effects have none. Say which column each of your
   suggestions falls in — it decides what is safe to accept.

### The trap, stated plainly

Several things here look like over-engineering and are not. Each was paid
for with a real bug:

- `refreshSourcesIfNecessary()` is documented as *not* working — that is a
  measurement, not an assumption
- a 503 counts as "page exists", because treating it as missing threw away
  valid Amazon URLs
- Escape is observed rather than consumed, so the focused app still gets it
- `SurfaceStyle.parkedGlass` is dead-looking code kept deliberately
- the router's fallbacks fail open on purpose

**The reasoning lives in the comments, and the rejected alternatives live
only there.** Deleting a comment that records why something is not simpler
is itself a regression, even when the code is untouched. If a comment reads
as noise to you, say so — but separate "this comment is redundant" from
"this comment is the only surviving record of a decision".

Judge the comment density honestly either way. It is heavy by design and
may be heavier than it needs to be.

## Standards

Judge against the pillars in `CLAUDE.md`, not against taste:

- **Deterministic rules beat prompt engineering.** Every routing bug fixed
  by rewording the prompt has come back. The fixes that held were code.
- **Never silently wrong.** The calendar half of this note exists entirely
  because "no meetings" and "I cannot see your calendar" sounded identical.
  Ask whether the design reintroduces that anywhere.
- **Fail open, and say what happened.**
- **No new latency.** Agent commands already cost ~2s. A design that adds a
  round trip to answer "stop" has failed regardless of how correct it is.

A proposal that improves a pillar is worth more than one that only removes a
defect.

## What to hand back

Two separate lists, not one merged list. They get acted on at different
times and by different rules.

**A — design findings.** For each: what breaks, the concrete case that
breaks it, and what you would do instead. Rank them; the user acts on the
top of the list first.

**B — simplifications.** For each: what to simplify, the simpler version,
and whether it sits in the tested or untested column. Rank by
reader-effort saved per unit of risk, not by lines removed.

If a finding in A and a suggestion in B touch the same code, say so. A
gets built first, so B should assume that code has already changed.

Append to `review/LEDGER.md`. One rule is not optional: you may mark your
own work `claimed-fixed`, never `VERIFIED`. Only a different reviewer
promotes something, and only after running it.

End with a **follow-up prompt** for the build session: what to build first,
what to prove before moving on, and what to leave alone.
