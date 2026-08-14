# Share feature: four fixes from the first live session

Fable, 2026-08-14, from the user's live testing. All four are in your
files — Fable stayed out to avoid a second working-tree collision.
Evidence lines are in `~/Library/Logs/Sayline/sayline.log` 21:47–21:52.

## 1 · "Send this to ME on WhatsApp" routes to nothing

`agent could not determine an action for "Send this to me on WhatsApp"`
(21:50:17), while "Share this to my WhatsApp" routes fine. The
`share_page` recipient description covers "my/myself" but the model
does not map bare "me". Fix in the tool description; add router cases:
"send this to me on WhatsApp", "send me this page", "WhatsApp this to
me" → selfTarget. Test-first per the standing rule: cases in, baseline
run, then the wording change, then rerun.

## 2 · The disambiguation dead-end logs nothing and remembers nothing

At 21:51 the "Which Ashutosh?" follow-up got a misheard answer
("Mura, Sotosh"), matched nothing, and returned
`.failed("Still not sure…")` — correct behavior, but no `[share]` log
line for the outcome (the flash is the only trace), and the user
experienced "it does nothing". Add the log line. The mishear itself
shrinks from here on: contact names entered the bias glossary at
21:55 (48 entries now).

## 3 · Remember the disambiguation choice (user-requested)

What the user wants is call-history ranking; macOS exposes no call
history to any app, so the buildable version is:

- **Per spoken-name memory**: once "Ashutosh" resolves to "Ashutosh
  Sharma" — by answer or by unambiguous match — store it (same
  pattern as `sharePageCountryCodes`). Next named send for that
  spoken name skips the question and logs
  `[share] Ashutosh -> Ashutosh Sharma (remembered)`. Safe under
  decision 4: the chat opens prefilled, a wrong face is visible
  before Enter. A different answer to a later question overwrites
  the memory.
- **Option order by dictation history** when the question does fire:
  rank the choices by mentions in the user's stored history (the
  bias builder already computes exactly this ranking — reuse, don't
  reimplement).

## 4 · Try the me-card before asking for the user's number

Decision 10 assumed the me-card is unreliable and always asked. The
user's card exists and they expect it to be used. Amend:
`CNContactStore.unifiedMeContactWithKeys...` first; a number with a
country code there is used silently (log which); ask only when the
card is missing, empty, or code-less. Update the design doc's
decision 10 with this amendment and the user's correction as the
reason.

## Also known, not yours

- Glossary doesn't rebuild on a Contacts *grant* mid-session (needs a
  relaunch today) — Fable's, going to BACKLOG.
- Bare "share this" router misses from 21:23 — already in your queue
  from the earlier review.

When done: ledger entry as usual, claimed-fixed. The user's live
retest script: "send this to me on WhatsApp" (must open your own
chat), then "send this to Ashutosh" twice — question the first time,
remembered the second.
