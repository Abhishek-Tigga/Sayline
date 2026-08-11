# Meetings — architecture

Fable, 2026-08-11. Builds on the 21 decisions in
`DESIGN-meetings-reminders.md`, which are settled and not re-derived here.
Two of them get a flag for the user (§9) — argued against their stated
reasons, not walked past. The reminders half of that design is built and
verified; this document covers only what remains: **join my next meeting**
and **what's my next meeting**.

The one-paragraph version: meetings mirrors the ReminderStore /
ReminderCoordinator shape with one deliberate improvement — the
load-bearing logic (link extraction, "next" selection) lives in pure,
EventKit-free functions so it gets a deterministic check suite on day one
instead of joining the untested-guardrail list. Entry is two
zero-parameter router tools plus FastRoute phrases, feeding the existing
`AgentTurnRunner` with no new pipeline shapes. The token cost is small and
paid for by the tool-description trim the design already promised.

---

## 1. Types, ownership, layout

Four new files. The split follows one rule learned twice in this repo
(`TranscriptCleanupValidator` untested; F6 still parked): **anything that
decides must be compilable without frameworks, so a `swiftc` check suite
can hold it.** EventKit appears in exactly one file.

### `Meeting.swift` — the value, and the selection logic (pure)

```swift
struct Meeting {
    let title: String
    let start: Date
    let end: Date
    let joinURL: URL?          // extracted once, at mapping time
    let isAccepted: Bool       // EKParticipantStatus.accepted, else false
}

enum MeetingSelection {
    /// The design's "next": running now, or starting within `window`
    /// (30 min). Soonest start wins; a tie breaks toward accepted.
    /// Pure — `now` is a parameter, never Date() — same injected-clock
    /// pattern that made the bare-day fix testable.
    static func next(from meetings: [Meeting], now: Date,
                     window: TimeInterval = 30 * 60) -> Meeting?
}
```

Why not put selection inside the store, where ReminderStore keeps its
scoring? Because ReminderStore's scoring is the one part of the reminders
build that no suite covers — it is testable only through a live EventKit
database. That was tolerable for token-overlap scoring; it is not
tolerable for the logic that decides *which meeting the user joins*. A
wrong pick is announced by name (settled decision), so it is visible —
but visible-after-joining is worth a test suite that makes it rare.

### `MeetingLink.swift` — where event text stops (pure)

```swift
enum MeetingLink {
    /// The join link, or nil. Checks url, then location, then notes —
    /// the settled field order. Matches KNOWN PROVIDER PATTERNS ONLY
    /// (zoom.us/j/…, meet.google.com/…, teams.microsoft.com/l/meetup-join…,
    /// webex.com/meet|join…). Never "any URL found in notes".
    static func extract(url: URL?, location: String?, notes: String?) -> URL?
}
```

The provider whitelist is the trust boundary made mechanical. The design
already says "a known meeting-link pattern"; this pins down why *known*
is load-bearing: `notes` is attacker-writable, and a rule that extracted
any URL would let anyone who can send an invite plant an arbitrary link
that a voice command opens. A missed provider degrades to the honest "no
join link" answer — fail open, visibly, and the manual checklist grows a
provider. A too-loose pattern fails toward opening a stranger's URL.
Asymmetric costs; the whitelist errs on the cheap side.

### `MeetingStore.swift` — the only file that imports EventKit

Mirrors `ReminderStore` deliberately: own `EKEventStore`, same
access-status enum shape, same ask-only-when-the-prompt-will-show rule.

```swift
final class MeetingStore {
    func requestAccess() async -> CalendarAccess   // granted / denied / failed
    /// Events overlapping [now, now+window], mapped to Meeting values.
    /// All calendars — the design's no-configuration filter is "has a
    /// join link", applied later, not a calendar picker.
    func meetings(around now: Date) async -> [Meeting]
}
```

Mapping `EKEvent → Meeting` calls `MeetingLink.extract` once, here. After
this point no code sees event text except UI display. This thin mapping
layer is the one part no suite can reach; it is deliberately too thin to
hide a decision, and the manual checklist covers it (§6).

Sharing the reminders `EKEventStore` was considered and skipped: calendar
and reminder access are separate TCC grants with separate request calls,
the stores share no state worth sharing, and two small stores that each
mirror a proven file beat one store with two permission lifecycles.

### `MeetingCoordinator.swift` — the conversation (@MainActor)

Mirrors `ReminderCoordinator` exactly: permission flow including the
denied-once "Open System Settings?" follow-up (the Privacy_Calendars deep
link is already verified in the design doc; `debugAskYesNo` already
prototyped this precise question), the honest answers, the result
surfaces.

```swift
@MainActor final class MeetingCoordinator {
    func join() async      // announce by name, open link in browser
    func whatsNext() async // read it back
}
```

Outcome copy, all from settled decisions:
- Join, link found: notice "Joining <name>" / detail "<time>" — the name
  is always said, so a wrong pick is visible immediately.
- Next event has no link: "Next: Design review at 3:00 — no join link."
  Never "no meetings found" when that would be false.
- Nothing in the window: "No meetings in the next 30 minutes."
- Denied permission: the offerSettings pattern, once, never nagging.

## 2. How it enters the system

Nothing new in the pipeline — that is the point; the `AgentTurnRunner`
refactor was built to make this paragraph short.

- **`AgentAction`**: `.joinMeeting`, `.whatsNextMeeting`. No payloads.
- **Router tools**: `join_meeting`, `next_meeting`, both zero-parameter.
  Zero-parameter tools are the cheapest kind in tokens and the safest in
  parsing — nothing to malform, nothing to fuzzy-match.
- **`AgentTurnRunner`**: two cases, both `Task { await meetings.… }`
  returning `.asking` — the coordinator owns the ending, same as
  reminders. Actions stay parallel per the standing product decision.
- **FastRoute**: fixed phrases — "join my meeting", "join my next
  meeting", "join the meeting", "what's my next meeting", "next meeting",
  "when's my next meeting" — mapped to the two actions. Whole-utterance
  only, as ever. This makes join the fastest command in the app: no model
  round trip, an EventKit query measured in tens of milliseconds, then a
  browser open. The common case of this feature never waits on a model.
- **Eval harness**: two lines in `TOOL_TO_ACTION`. The Swift-helper file
  list does **not** grow — the router gains no new source dependency,
  because tools are declared in `AgentRouter` and the meeting types sit
  behind the action enum. The F2 failure class stays closed.

## 3. Prompt-token cost, and what pays for it

Standing baseline, measured this morning at `8f0f60c`: **2,446 median
prompt tokens** (up 101 from the regional site additions — already spent,
and the meetings budget must be honest about starting there).

Cost of entry: two zero-parameter tools ≈ **+110–160 tokens** (name,
one-line description, empty schema plus strict-mode scaffolding). The
design's earlier ~335 estimate assumed parameterized tools; going
zero-parameter is what shrinks it. Nothing else rides the prompt — no
pane-list-style vocabulary, no site names, and FastRoute phrases are
free.

Payment, as the design already promised: the trim of the three fattest
tools (`close_app` 372, `find_file` 352, `open_folder` 306 tokens —
"all written before we knew what mattered"). The trim is parked as F7,
but it is parked *as an independent optimization*; here it is the named
funding source for a budgeted feature, so it lands as part of this work,
in this order:

1. Eval at baseline (have it: 59/61, 2,446 tokens).
2. Trim commit. Eval: accuracy must hold, tokens drop.
3. Meetings-tools commit. Eval: accuracy must hold, tokens ≤ 2,446.

Three runs, each attributable. If the trim cannot fund the tools, the
real number gets reported, not quietly spent — the standing rule.

## 4. Permissions — the fourth prompt

Asked on first use, never at launch (settled). Concretely:

- First "join my meeting" → `requestFullAccessToEvents()`. macOS 14 has
  no read-only calendar grant, so full access is requested to *read* —
  worth one honest sentence in any user-facing copy, since "why does a
  dictation app want full calendar access" is the question a reviewer
  asks.
- The system prompt appears after hotkey release, user-initiated —
  exactly the moment the design says people say yes.
- Denied → say it once, offer the settings deep link via the follow-up
  primitive, never re-prompt. Verbatim the `ReminderCoordinator`
  pattern.
- The reminders build found that the TCC-granting call itself doesn't
  retroactively succeed — the *next* call does. `MeetingStore` awaits
  the grant before querying (the ReminderStore shape already handles
  this), and the manual checklist includes the grant-then-first-query
  sequence.
- Dev-loop reality, recorded so nobody rediscovers it: ad-hoc signing
  resets all of this every rebuild. The calendar grant joins the
  `tccutil` dance. Fifth reason the permission status view (O-E, parked)
  eventually earns its place; not built now.

## 5. The trust boundary in practice

Where event text goes, exhaustively:

| Event text | Reaches |
|---|---|
| url / location / notes | `MeetingLink.extract` — regex against provider whitelist, returns URL or nil, retains nothing |
| title | The pill/notice, as display — and nowhere else |
| anything | The router prompt: **never** |

The router only ever sees the user's own speech; both meeting tools take
no arguments, so there is nothing for a prompt injection to steer even in
principle — the model can pick `join_meeting`, and everything after that
is deterministic code over data. The one future feature that would cross
the line ("summarize my meeting") is out of scope and already fenced in
the design doc: if event text must ever reach a model, that call carries
no tools.

One boundary subtlety this document adds: the *extracted URL* is also
attacker-supplied in the weak sense that an invite sender chose it. The
provider whitelist is what caps that: the worst plantable link is a real
meeting on a real provider, which is the feature working as designed.

## 6. Testing, layer by layer

The recurring trap, named in the eval README and hit again by the
bare-day bug: **the router eval scores what the model emits and is
structurally blind to everything we do afterwards.** For meetings that
blindness is nearly total — the tools have no arguments, so the eval can
only ever verify "the right tool got picked". Every decision this feature
actually makes lives after the tool call. So:

**Router eval (new cases, ~8):** phrasing variety for both tools ("hop
on my meeting", "when's my next call"); negatives that matter more than
the positives: "create a meeting tomorrow at 3" must match *nothing*
(calendar writes are out of scope — the model must decline, not
improvise `create_reminder`); "cancel my next meeting" must not route to
`cancel_reminder`; "what meetings do I have today" (list-shaped, parked)
should decline rather than half-answer via `next_meeting`.

**New `swiftc` suite — `eval/meeting-checks` (ships with the feature,
not after it):** compiles `Meeting.swift` + `MeetingLink.swift` only.
Injected clock throughout.
- Selection: inside/outside the 30-minute window; running-now; two
  meetings with the tie broken by start then by acceptance; all-day
  events and linkless holidays never winning join; empty window.
- Extraction: Zoom in `url`, Zoom in `location`, Meet in `notes`, Teams'
  monstrous `meetup-join` URLs, a notes field containing a survey link
  plus a Meet link (must return the Meet link), a notes field with only
  a non-provider URL (must return nil — the trust boundary as a test
  case), plain-text notes, empty everything.

**fastroute-checks:** the new phrases positive; negatives — "join the
design review" falls through (named join is not v1), "what's my next
reminder" falls through.

**Manual checklist additions:** one real invite from each provider on a
real calendar; a linkless event; grant flow, denial flow, and the
settings offer; the granted-then-first-query sequence; a recurring
meeting's next occurrence.

**Not coverable and said out loud:** the `EKEvent → Meeting` mapping and
the EventKit query itself. Kept thin enough to read in one screen; the
manual checklist is their only net. url-health does not apply — meetings
compiles no URLs, only patterns.

## 7. Failure modes, silent ones first

- **EventKit is blocking IPC in a pipeline with a freeze in its
  history.** Rules: no EventKit call on the main thread (`MeetingStore`
  methods are async and hop off), none anywhere near the tap thread, and
  every store call logs its elapsed ms — the Secure Input incident was
  diagnosable only because thread-tagged logs existed; meetings arrives
  pre-instrumented. The permission dialog is a normal dialog, not secure
  input; no tap interaction expected. If a freeze ever coincides with a
  calendar query, the log will say so in one line.
- **Wrong meeting picked** — visible by design (name announced), bounded
  by the selection suite.
- **Wrong link extracted** — the survey-link-plus-meet-link case; bounded
  by the whitelist and its test. A miss degrades to the honest no-link
  answer, never to opening a random URL.
- **Duplicate events across calendars** (same standup on two calendars):
  selection may "tie" a meeting with itself; both rows carry the same
  link, so join is unaffected. Accepted for v1, noted in the suite as a
  documented case rather than guessed at.
- **Browser open fails** — `NSWorkspace.open` returns false → the
  existing failure flash. Not silent.
- **Empty title** — "Joining Untitled meeting at 3:00" beats crashing on
  a nil; a fixture case.
- **The prompt eats the moment** — first-ever join pays the permission
  dialog and then must retry; the coordinator re-queries after grant
  rather than reporting failure. Second command works; the design priced
  this in.

## 8. Deliberately not in the first build

Each with the reason, so unparking is an argument rather than an
accident:

- **Named-meeting join** ("join the design review") — needs fuzzy title
  matching against attacker-adjacent text and a disambiguation
  conversation; v1's join-next with the name announced covers most of
  the value. Falls to the router, which declines.
- **Meeting notifications** ("your meeting starts in 5") — a scheduler
  and a interruption-policy question, nothing shared with join.
- **Today's-meetings list** — the parked list-answer surface; same
  parking reason as reminders' list.
- **Calendar picker setting** — the design's own named fallback if
  all-calendars filtering proves wrong. Build the evidence first.
- **Zoom/Teams native app launch** — no such app installed here; dead
  code today (settled).
- **Cross-calendar dedupe** — documented, harmless for join.
- **"Summarize my meeting"** — crosses the trust boundary; fenced until
  a no-tools model call exists.

## 9. Two flags for the user — argued, not re-litigated

1. **"Answers flash in the pill for 4.5 seconds" (settled) — propose the
   notice box instead, on the decision's own terms.** The stated reason
   for the pill flash was to ship the smaller thing first and let "too
   small" become the concrete reason for a box. Since then the box got
   built anyway, for reminders, and is verified live. "Next: Design
   review at 3:00 — no join link" is a title plus a detail line — the
   box's exact shape, and plainly too much for a one-line flash. Using
   `showNotice` here is the fallback the decision itself named, arriving
   on schedule. Flagged because the words "flash in the pill" are in the
   design doc and the implementation would visibly differ.
2. **Full-access ask for a read-only feature.** The design settled
   read-only calendar *use*; macOS offers no read-only *grant* for
   events. No alternative exists, so this is a copy problem, not a
   design change — but the user should knowingly own the optics of
   "full calendar access" before the prompt ships, because it is the
   fourth permission and the scariest-sounding one.

## 10. Order of work

1. Tool-description trim + eval (funds the budget, independent risk).
2. `Meeting.swift` + `MeetingLink.swift` + `meeting-checks` suite — pure
   logic proven before EventKit exists.
3. `MeetingStore` + `MeetingCoordinator` + runner/action/tool wiring +
   FastRoute phrases + eval cases; eval run three (tokens ≤ 2,446,
   accuracy holds).
4. Live pass: permission gauntlet, one real invite per provider, the
   manual checklist. This is also the session that finally exercises the
   F4 frozen-countdown fix, which is first on the live list.
