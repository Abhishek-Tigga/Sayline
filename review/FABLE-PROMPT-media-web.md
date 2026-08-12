# Fable — design review, before any code exists

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

For each finding: what breaks, the concrete case that breaks it, and what
you would do instead. Rank them — the user has limited time and will act on
the top of your list first.

Append to `review/LEDGER.md`. One rule is not optional: you may mark your
own work `claimed-fixed`, never `VERIFIED`. Only a different reviewer
promotes something, and only after running it.

End with a **follow-up prompt** for the build session: what to build first,
what to prove before moving on, and what to leave alone.
