# Build: share the current page to WhatsApp / AirDrop

Fable, 2026-08-14. For Opus. The design is settled and user-confirmed —
your job is the build, not the design. Where the design doc and this
prompt disagree, the design doc wins; where you find a real hole in it,
stop and surface it in the ledger rather than improvising a fix.

## Read first, in this order

1. `DESIGN-whatsapp-share.md` — all twelve decisions with their
   rejected alternatives. The build must match it.
2. `CLAUDE.md` — verification layers, the add-a-suite rule, the
   idle-holds-nothing convention.
3. `review/LEDGER.md`, the protocol at the top — you mark your own
   work claimed-fixed, never VERIFIED.

## Non-negotiables, restated because each was paid for

- **The page URL and phone numbers never enter a model prompt**
  (design decision 2). The router emits (recipient, note); the app
  attaches the URL and resolves the number locally. If you find
  yourself passing the URL to the model for any reason, stop.
- **Prefill, never send** (decision 4). No code path may trigger
  WhatsApp's send. The user presses Enter, always.
- **URL capture at agent-flag time, not hotkey-down, not execution
  time** (decision 3). Apple Events fire only on agent-flagged holds —
  a plain dictation must never touch the browser. Idle holds nothing.
- **Ambiguity asks, timeout does nothing** (decision 5). Use the
  existing `FollowUp` mechanism. A guessed recipient is the worst
  outcome this feature can produce.

## Build order — tests before code, per the standing rule

1. **Router test cases first.** Add to `eval/router-test-set.json`:
   named send ("send this to Priya, tell her…"), self send ("save
   this to my WhatsApp"), unnamed send ("share this"), explicit
   target ("…via AirDrop"), and the negatives — "send this email to
   Priya" in Mail context must not become a share; "open WhatsApp"
   must stay `openApp`. Run the eval for a baseline BEFORE the tool
   exists (expect the new cases to fail — that failure is the
   baseline), build afterward, run again. Report both numbers and the
   prompt-token delta; the no-slower rule applies.
2. **The deterministic core, as its own file(s)** so the suite can
   compile it framework-free where possible: recipient disambiguation
   (two-match detection, mobile-label preference), percent-encoding
   (emoji, multiline note, long query strings), `whatsapp://` and
   `wa.me` URL construction. Write `eval/whatsapp-checks/main.swift`
   in the style of the existing suites. **Its CLAUDE.md compile line
   lands in the same commit the suite does** — five suites once
   existed that no fresh session would have run.
3. **The action.** New `AgentAction` case (recipient enum: named /
   selfTarget / unnamed; note; explicit target if spoken). Tool schema
   entry generated the same way the others are. Remember
   `--dump-config` feeds the eval — if the tool schema or any prompt
   text changes, the harness sees it automatically, but rebuild the
   binary before trusting a number.
4. **URL capture.** AppleScript per browser family (Safari dialect,
   Chromium dialect for Chrome/Edge/Brave/Arc), reusing the
   `runAppleScriptReturningString` helper in `AgentExecutor`. Firefox
   and non-browsers fail visibly with the messages from the design
   doc's failure table. Capture is triggered where agent mode is
   flagged; store it on the same per-hold state that carries the
   agent flag.
5. **Contacts resolution**, local only: CNContactStore, fuzzy
   first-name match, the disambiguation follow-up, per-contact
   country-code follow-up with persistence. Contacts permission
   requested on first named send, not at launch.
6. **Self number + default target in Settings**: the one-time
   follow-up that captures the user's own number, and the visible
   "Share links via: Ask / WhatsApp / AirDrop" control (decision 7).
   The "…, always" spoken answer sets it; explicit spoken target
   always overrides it.
7. **AirDrop**: `NSSharingService(named: .sendViaAirDrop)` with the
   URL, self/unnamed sends only. Picker canceled = nothing happens.
8. **By hand, before claiming**: one real send per scriptable
   browser; the Firefox and non-browser failures; the two-match
   follow-up live; "always" persisting and visible in Settings; the
   note landing cleaned-casual (decision 9 — Clean, not Work).

## Logging

Every branch logs with the `Sayline:` prefix: URL captured (log the
host only, not the full URL — the log file is meant to be handed
over), recipient resolved (name, not number), target chosen, prefill
opened, every failure with its user-visible message. The agent-turn
gap class from the backlog ("23s with nothing logged") must not be
repeated here: anything that can take more than a second logs when it
starts, not only when it ends.

## When done

Ledger entry: what you built, what you ran (eval numbers before and
after, suite output, the by-hand list with what you saw), what you
could not verify and why — claimed-fixed, with verification
suggestions for the next reviewer. CHANGELOG row. If any design
decision proved unbuildable as written, the ledger entry says so
explicitly rather than the code quietly diverging.
