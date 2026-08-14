# Share the current page — WhatsApp and AirDrop — agreed design

Settled 2026-08-14: a self-grill by Fable over the design tree, then the
resolved shape confirmed by the user, who added one decision of his own
(AirDrop, decision 6) that survived the loophole check with a scoping
fix. Recorded because the reasoning is the part that gets lost — the
decisions will be obvious from the code, the rejected alternatives will
not.

Nothing here is built yet.

## The model in one paragraph

While reading a page in a browser, the user holds the hotkey, presses
Space, and says *"send this to Priya — tell her this is the pricing
article I mentioned."* Sayline grabs the current tab's URL locally,
routes the words (never the URL) through the agent model, resolves
"Priya" to a phone number locally in Contacts, and opens WhatsApp on her
chat with the note and the link already typed in. **The user presses
Enter.** Nothing ever sends itself. A send with no named person —
*"save this to my WhatsApp"*, *"share this"* — goes to the user
themself, via WhatsApp or AirDrop, asking which the first time and
remembering the answer only if told to.

## The decisions

**1 · v1 is self + named contacts. Groups are parked, not built.**
WhatsApp has no official way to deep-link into a group chat. The only
route is robot-clicking WhatsApp's own search UI, which breaks on every
redesign of theirs and has "message lands in the wrong group" as its
failure mode — the single worst outcome this feature can produce.
Rejected: UI automation for groups (fragile, catastrophic failure
shape); waiting until groups work to ship anything (self + contacts is
most of the daily value). Unparks if WhatsApp ever documents a group
link.

**2 · The page URL and the phone number never enter a prompt.** The
router model sees the user's words and emits (recipient, note). The app
attaches the URL afterward and resolves the name in Contacts locally.
The user's reading history and their contacts' numbers stay on the
machine — the only party that ever receives the link is WhatsApp
itself, which is where the user is sending it. Rejected: letting the
model see the URL to write a smarter note ("check out this TechCrunch
piece") — a nicety that costs the privacy line the product is pitched
on. The note is built from spoken words only.

**3 · "This" is captured when agent mode is flagged, not after
routing.** The URL is read from the front browser at the moment Space
is pressed during the hold. Routing takes seconds and the user may
switch tabs while it runs; "this" must mean what they were looking at
when they asked. Rejected: capture at execution time (races the user's
attention); capture at hotkey-down for every dictation (fires Apple
Events on plain dictations that will never need a URL — pay the cost
only when agent mode is actually requested).

**4 · Prefill, never send. On every path, forever.** WhatsApp opens
with the message typed into the box; the user hits Enter. Same
principle as the reminder-delete consent gate: a wrong-recipient
message is unrecoverable, and the one-keystroke review cost buys out
the entire failure class. This is also what makes decision 8's loose
phrase-matching safe — a wrong route is a message you simply don't
send. Rejected: auto-send (the nightmare), and a "trusted contacts
auto-send" tier (complexity that exists to remove a single keystroke).

**5 · Recipient resolution is deterministic, and ambiguity is asked,
not guessed.** Contacts lookup is local fuzzy matching. Two matching
names → the existing follow-up question ("Priya Sharma or Priya
Mehta?"), answered by holding the hotkey, exactly like every follow-up
in the app. Several numbers on one card → prefer the mobile label,
else ask. Timeout or Escape → nothing happens. A misheard name fails
visibly, showing what was heard. Rejected: most-recently-contacted
tiebreaking (invisible state pretending to be smart; the wrong-person
cost is asymmetric).

**6 · AirDrop is the second target — for self and unnamed sends only.**
The user's addition, kept after a loophole check with one scoping fix:
macOS cannot AirDrop to a *name* — it can only open the device picker
and let the user click. So for a named person, WhatsApp is the only
route that can actually reach them, and no question is asked. For
self/unnamed sends the two targets serve genuinely different moments —
AirDrop is instant handoff (the link opens on the phone now), WhatsApp
Message-Yourself is storage (it waits in the chat) — which is exactly
why the app asks rather than picking. Rejected: asking on named sends
too (a question with one real answer); dropping AirDrop (real use
case, nearly free via `NSSharingService`).

**7 · The default is voice-settable in one breath, and lives visibly in
Settings.** First unnamed send asks "WhatsApp or AirDrop?" Answering
"WhatsApp" answers this time only; answering "WhatsApp, always" sets
the default and the question never comes back. The default is shown in
Settings ("Share links via: Ask / WhatsApp / AirDrop") so the standing
rule stays visible and changeable. Explicit words in the command ("on
WhatsApp", "via AirDrop") always beat the default. Rejected: a second
"make this your default?" follow-up (two stacked questions for one
send); silently adopting a repeated choice as the default (invisible
state — three weeks later the app "always AirDrops" and nobody
remembers why).

**8 · Bare "send this to Priya" routes to WhatsApp without the word
"WhatsApp".** It is the only named-person target in v1, and decision 4
makes a wrong route harmless. Revisited the day a second named-person
channel (email-send) exists — recorded here so that day actually
triggers the revisit. Rejected: requiring the word "WhatsApp" spoken
every time (ceremony that protects against nothing, since nothing
sends itself).

**9 · The note is Clean, not Work.** Spoken words tidied — fillers
gone, punctuation fixed, casual register kept. WhatsApp is informal;
Work mode's restructuring and email shell would dress a one-line "check
this out" in a suit. No note spoken → the message is the bare URL.
Rejected: Work-mode treatment (wrong register), auto-adding the page
title as text (WhatsApp link previews already show it; our copy would
be noise).

**10 · Self-send number is asked once and stored locally.** First
"save to my WhatsApp" triggers a one-time follow-up for the user's own
number, stored on the machine, editable in Settings. Rejected: reading
the Contacts "me" card (unreliable — usually empty), and requiring
Settings setup before first use (the feature should be discoverable by
speaking to it).

**11 · Browsers in, everything else fails visibly.** Safari, Chrome,
Edge, Brave, Arc — all scriptable, all already in `AppContext`'s
browser list. Firefox does not answer AppleScript URL queries: honest
visible failure, parked with the reason. Front app not a browser →
"Nothing to share here — this works from a browser." Rejected: URL
scraping from window titles (titles don't carry URLs; guessing breaks
the trust rule), and AX-tree URL extraction (deep, fragile, and the
exact IPC class implicated in the freeze history).

**12 · Delivery is the `whatsapp://` scheme with `wa.me` fallback, and
odd URLs ship as-is.** The scheme opens the desktop app directly; the
web fallback covers its absence, and no WhatsApp at all fails visibly.
localhost and file:// links are sent unjudged — the user asked. Note
and URL are percent-encoded (emoji, multiline, long query strings each
get a test case). Rejected: validating "shareworthy" URLs (we don't
judge), bundling the note and link into one line (WhatsApp previews
work best with the URL on its own line).

## Permissions this costs, all first-use, all degradable

| Permission | Asked when | If denied |
|---|---|---|
| Automation → per browser | First "send this" from that browser | Visible failure + how to grant |
| Contacts | First send to a named person | Self-send still works fully |

No new always-on state: Apple Events fire only on an agent-flagged hold
(decision 3), matching "while idle, Sayline holds nothing."

## Failure modes, enumerated

All fail open and say what happened, per the standing convention.

- WhatsApp not installed → says so (after `wa.me` fallback also fails).
- Firefox or non-browser front app → says so, names the limitation.
- Name not found / misheard → shows the name it heard.
- Two matches / multiple numbers → follow-up question; timeout does
  nothing.
- No country code on the resolved number → follow-up asks once;
  remembered for that contact.
- Automation or Contacts denied → visible, with the settings path.
- AirDrop picker canceled → nothing happens, nothing retried.

## Verification plan — written before the build, per the rule

- **Router cases first**: new test-set entries for named send, self
  send, unnamed send, explicit-target send, and the negative cases
  ("send this email to Priya" while in Mail must *not* become a
  WhatsApp share). Run the eval before and after the tool lands;
  the standing no-slower rule applies to prompt-token cost.
- **Deterministic suite** for the pure parts: recipient disambiguation,
  number-label preference, percent-encoding (emoji, multiline, long
  URLs), scheme/fallback URL construction. Compiled and run like every
  other suite; the CLAUDE.md line lands in the same commit as the
  suite, per the add-a-suite rule.
- **By hand**: one real send per browser in the table; the Firefox and
  non-browser failure messages; the two-Priyas follow-up live; the
  "always" answer actually persisting and showing in Settings.

## Parked, with reasons

- **Groups** — decision 1. Unparks on an official group link.
- **Firefox** — decision 11. Unparks if Firefox grows AppleScript URL
  support (it has been "planned" for a decade; do not wait).
- **More share targets** (email-to-self, reminders "read this
  tomorrow") — the captured-URL plumbing makes these cheap later;
  each is its own design conversation. Email-send specifically
  triggers the decision-8 revisit.
- **Contact names into transcription vocabulary biasing** — the
  misheard-name failure and the biasing work share a fix; noted in
  the biasing design when it happens.
