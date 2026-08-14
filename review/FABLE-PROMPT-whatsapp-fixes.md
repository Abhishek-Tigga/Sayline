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

## 5 · The "Which Ashutosh?" list was not comprehensive (user report)

The question offered two Ashutoshes; the one the user wanted was not
among them. Three mechanisms, in likely order — check all three, they
are not exclusive:

- **The option cap is a bug regardless.** `SharePageExecutor`'s ask
  shows `options.prefix(2)` — a third or fourth match is silently
  dropped, and nothing in the log or the question says so. If the
  resolver ever returns more than two, the cap must go (or the
  question must say "and 2 more — say the full name"). The pill can
  carry more than two choices; the current 2 is a UI convenience
  discarding real answers.
- **Contacts without a phone number are skipped silently.**
  `readContacts()` keeps only cards with at least one phone number.
  A wanted contact stored with just an email (or nothing) never
  becomes a candidate, and the user cannot tell "filtered out" from
  "not found". If the resolver drops name-matches for having no
  number, say so in the failure/ask: "Ashutosh Verma has no phone
  number in Contacts."
- **The account boundary.** CNContactStore only sees accounts enabled
  in macOS Internet Accounts. An Ashutosh who lives in WhatsApp (or
  an unsynced Google account) is invisible to us — same class as the
  calendar-source finding in BACKLOG.md. Nothing to code; the
  failure message should hint it: "…in your Mac's Contacts."

Diagnostic to run before fixing: log the total candidate count and
the name-match count at resolve time (names only, never numbers),
then have the user search Contacts.app for the missing Ashutosh —
whether the card exists and whether it carries a phone number decides
which mechanism this was.

## 6 · The last fallback should be WhatsApp's own picker, not a dictated number

The user's Mac had TWO "My Card" entries, and macOS's chosen me-card
was the EMPTY one — they had to type their own number in by hand and
correctly point out that no normal user does this. Your region-code
completion (landed in f3ea0f6) fixes the filled-local-number case;
the truly-empty case still falls back to asking the user to dictate a
phone number by voice, which is the most mishearable utterance in the
product.

Better final rung: `whatsapp://send?text=<message>` with **no phone
parameter** opens WhatsApp with the message staged and WhatsApp's own
chat picker up — "Message Yourself" sits at the top, one click,
zero numbers involved, nothing to mishear, and decision 4 still holds
(the user clicks the chat and then Enter). Chain becomes: me-card
international → me-card local + region → **number-less picker**. The
voice ask can be deleted outright — the picker beats it in every
case, including the first-run one. If the picker route works in a
live test, also drop `sharePageSelfNumber` storage: one less copy of
a phone number on disk.

## Also known, not yours

- Glossary doesn't rebuild on a Contacts *grant* mid-session (needs a
  relaunch today) — Fable's, going to BACKLOG.
- Bare "share this" router misses from 21:23 — already in your queue
  from the earlier review.

When done: ledger entry as usual, claimed-fixed. The user's live
retest script: "send this to me on WhatsApp" (must open your own
chat), then "send this to Ashutosh" twice — question the first time,
remembered the second.
