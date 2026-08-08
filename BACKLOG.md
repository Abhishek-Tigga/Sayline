# Sayline — Backlog

Things deliberately parked, not forgotten. Each entry says *why* it's
parked and what it would take to unpark it. When picking this back up,
check it before starting — some of these have real technical reasons
they weren't done, not just time constraints. For current direction see
[PRODUCT.md](PRODUCT.md); for what's shipped see [README.md](README.md)
and [CHANGELOG.md](CHANGELOG.md).

## Next up (explicitly requested, in order)

- **Agent router eval harness + JSON-mode migration** (agreed
  2026-08-09, harness to be built first). Two linked pieces: a way to
  *measure* the router, then a change to the router that needs
  measuring.

  Why now: every debugging round this session has been anecdotal — try
  a phrase, read a log, guess. No fixed inputs, no score, no memory
  between rounds, which is exactly why the same failure kept
  resurfacing in different clothes. The harness exists to end that.

  **The problem being fixed:** tool calling makes the model emit a
  bespoke `<function=name>{...}</function>` wrapper that Groq's server
  parses; that wrapper is unconstrained learned behavior, and when the
  model drops the `>` the whole request dies server-side with HTTP 400
  `tool_use_failed`. Measured 60% of calls reaching the API in one
  session log (n=5, biased toward hard cases). The temperature-0.6
  retry currently in `AgentRouter` does *not* reliably fix it —
  confirmed live, a retried call reproduced byte-identical malformed
  output — and it doubles token cost on exactly the requests already
  failing, which contributed to hitting the daily cap.

  **Three arms to compare, same test set, same scoring:**
  - **A — Groq tool calling** (`llama-3.3-70b-versatile`, current, at
    commit `4f80fe1`). The baseline everything else must beat.
  - **B — Groq JSON object mode** (`response_format:
    {"type": "json_object"}`, supported on all Groq models; strict
    schema-enforcing mode is GPT-OSS-only so unavailable here). No
    wrapper to malform. Also ~33% cheaper per call: measured payload
    ~2,370 tokens, of which the tools array is 72% (~1,626), and 47%
    of that array (~772 tokens) is pure JSON Schema scaffolding prose
    doesn't need. Guarantees *valid* JSON, not *correct-shaped* JSON —
    we validate the parsed structure ourselves (already do, via
    `fuzzyMatch` + catalog lookup).
  - **C — OpenAI small model with strict structured outputs**
    (`gpt-5-nano` $0.05/$0.40 per 1M first, `gpt-5-mini` $0.25/$2.00 or
    `gpt-4o-mini` $0.15/$0.60 if nano's action selection is too weak).
    Strongest fix available: the schema is enforced *during*
    generation, so malformed output is structurally impossible rather
    than merely less likely. Also sidesteps the constraint that
    actually hurts — Groq free tier caps the 70B router at 100K
    tokens/**day** (hit twice in one session), while OpenAI Tier 1
    ($5 paid) is ~200K tokens/**minute** on 4o-class models. Watch
    latency: Groq's whole edge is speed and this sits in a
    hold-to-talk loop, so record per-call latency, don't assume.

  B and C are competing fixes for the same bug — build only the
  winner. Blast radius either way is one file; `AgentAction`,
  `SettingsPaneCatalog`, `AgentExecutor` are untouched.

  **Measure before implementing.** The harness is a standalone script
  that hits all three arms directly with the same test set, so only the
  winner gets written as production Swift — rather than building two
  routers and discarding one. Risk to control: the harness must
  faithfully reproduce the real system prompt and tool definitions or
  the numbers mean nothing. Prefer concatenating the actual
  `AgentRouter.swift` (+ its deps) into a `swift` script, the way
  `TranscriptCleanupValidator` was tested, over retyping the prompts.

  **Prerequisites before arm C:** an OpenAI API key (real money,
  pennies at this volume) and a second Keychain entry — `KeychainStore`
  currently hardcodes one account, `GROQ_API_KEY`, and all three call
  sites read `APIKeyProvider.groqAPIKey`. Roughly 30 lines plus a
  Settings field. Not needed for arms A and B.

- **Teach the eval methodology back to Abhishek** (requested
  2026-08-09 — surface this when the eval work is done, or whenever he
  asks about it). He asked for the harness to be *built* first without
  a walkthrough, then explained afterwards: he's a PM learning to build
  hands-on, so the goal is transferable industry practice, not a tour
  of this repo's files. Worth covering when the time comes: why a
  frozen test set beats ad-hoc manual testing (this whole session is
  the cautionary tale — same bug resurfacing in different clothes
  because nothing was ever measured twice the same way); why the test
  set must be written *before* the implementation; why scoring has to
  be mechanical rather than a human judging output quality; what
  regression cases are and why passing-cases belong in the set;
  golden/reference datasets and how real teams build them; the
  difference between offline eval and production monitoring; and where
  this sits relative to how LLM products are actually evaluated in
  industry (eval-driven development, LLM-as-judge and its pitfalls,
  why benchmark scores rarely predict your specific task). Use
  `eval/router-test-set.json` as the concrete worked example since he
  will have watched it get built.

  **Guardrails, agreed in this order:**
  1. **Write the test set before the implementation.** Building first
     and designing the test after means unconsciously picking cases the
     new version happens to pass — drawing the target around where the
     arrow landed. ~20 transcripts with expected action + arguments,
     checked into `eval/`.
  2. **Include cases that already work,** not just broken ones
     (`Open Safari`, `Close Safari`, `find my resume in downloads`) —
     otherwise we fix syntax failures and silently regress action
     selection, which is the specific risk JSON mode carries (tool
     calling is a heavily trained path; JSON mode leans on our prompt).
     Also include the session's real failures (`Show my screen time`,
     `Open doc settings`, `Close settings`, `Open general settings`),
     multi-action requests, and out-of-scope requests that must match
     nothing.
  3. **Baseline the current implementation first,** at commit
     `4f80fe1`, on that same test set — same inputs, same scoring, so
     the comparison isn't today's log vs. tomorrow's impression.
  4. **Pass bar set up front, not judged in the moment:** syntax
     failures → 0%; action accuracy ≥ baseline; tokens/call < ~1,800.
     Syntax fixed but accuracy down is a *fail*, not a trade to
     rationalize later.
  5. **Branch, don't delete** (`agent-json-mode` off `main`) — the
     established branch-per-experiment convention. Reverting stays a
     `git checkout`, not a reconstruction.

  **Scoring must be mechanical** — compare to expected values in the
  file, never a judgment call about output quality, or it's vibes with
  extra steps. Metrics: syntax failure rate (count of `tool_use_failed`
  / unparseable), action accuracy (exact match on action + key args),
  tokens per call (from `usage.prompt_tokens` in each response —
  measured, not estimated), latency.

  **Maintaining the score:** results checked into `eval/` as an
  append-only file (date, commit SHA, implementation, the four
  numbers), re-run whenever the router changes. It becomes a regression
  guard — when a prompt tweak quietly breaks `find_file` months from
  now, the numbers say so instead of a user noticing.

  **Known constraint:** only arms A and B spend Groq's budget —
  ~20 cases × 2 arms × ~2,000 tokens ≈ 80,000 tokens against a
  100,000/day cap, so they realistically run on different days (or the
  set trims to ~12 cases). Arm C spends OpenAI credit instead, so it
  can run the same day as either. Note the irony worth remembering:
  the cheapest way to escape Groq's measurement bottleneck is the arm
  that doesn't use Groq.

- **8B vs 70B cleanup compliance A/B test** (blocked, on hold — user
  explicitly parked this 2026-08-08; remind them of this item whenever
  they ask what's in the backlog). Before switching `TranscriptCleaner`
  from `llama-3.1-8b-instant` to `llama-3.3-70b-versatile`, actually
  measure whether 70B gives better prompt compliance on this narrow
  cleanup task rather than assuming it — run both models against a set
  of real/realistic raw transcripts (a couple of confirmed historical
  failures plus constructed filler-heavy samples matching this user's
  real dictation style) through the *actual* `TranscriptCleaner`
  system prompt, score each output with the same disallowed-edit-
  fraction logic `TranscriptCleanupValidator` uses, and compare. First
  attempt (2026-08-08) failed before producing any real data — all 10
  Groq API calls came back HTTP 403, and the follow-up diagnostic curl
  (to see the actual error body) was blocked by the auto-mode
  permission classifier since it echoed key-related output. Root cause
  of the 403 was never established — could be the stored key, could be
  the test script. **Before re-attempting: confirm the key still works
  via a real dictation in the app itself first**, so a second blind
  failure doesn't waste another round. The 70B swap itself stays on
  hold until this test actually runs and shows a real difference —
  don't swap on assumption.
- **List-shaped query answers** (e.g. "what are the biggest files in my
  Downloads folder"). Single-fact queries (battery, storage, memory,
  uptime, volume, macOS version, now-playing) shipped 2026-08-05, all
  displayed on the existing floating pill with a longer readable
  duration than the failure-flash. A list of several files with sizes
  doesn't fit one line the way a single fact does — needs either a hard
  condensed format or the pill growing into a small multi-line surface
  for this case specifically. Deliberately scoped separately from the
  single-fact batch rather than guessed at alongside it.

- **Cleanup quality polish** (low priority, not required now that
  edit-validated cleanup — shipped 2026-08-08, see CHANGELOG — bounds
  the downside). Upgrade the cleanup model from `llama-3.1-8b-instant`
  to the 70B already used for agent routing, for better first-pass
  compliance (cost is a rounding error per the existing cost analysis).
  Whisper `prompt` parameter to bias transcription toward custom
  vocabulary (app names, "Sayline").

## Agent actions considered and skipped (technical reasons, not scope)

- **Wi-Fi network name query.** Tried via the `networksetup` CLI on the
  assumption it would sidestep CoreWLAN's permission requirement — it
  doesn't. macOS withholds the real SSID from any process, CLI or API,
  without **Location Services** permission (a precise SSID can be used
  to geolocate a device via Wi-Fi-to-location lookup services). Dropped
  rather than added Location Services for it — a genuinely bad look for
  an app whose whole pitch is dictation privacy, for a minor query.
  Confirmed live: reported "Not connected to Wi-Fi" while actually
  connected, which is the withholding behavior, not a real failure.
- **"What's playing" for browser-sourced media** (e.g. YouTube in
  Chrome). Now-playing currently only checks Music.app/Spotify by name
  via AppleScript, which have a real, documented "current track" you can
  query. Browsers don't expose anything equivalent for an arbitrary tab
  playing audio — the only way to get this would be Apple's undocumented
  MediaRemote framework (what third-party "now playing" menu bar utilities
  use), which is exactly the private-API fragility already avoided when
  now-playing was first built. Confirmed live: asking about YouTube audio
  correctly reported nothing playing, since it isn't Music/Spotify — this
  is the deliberate scope boundary working as intended, not a bug.

- **Bluetooth toggle (on/off).** No reliable way to do this without `sudo`,
  a private framework, or a third-party CLI like `blueutil` (not
  preinstalled, would add an external dependency). "Open Bluetooth
  settings" still works via `open_system_setting`, just not a direct
  toggle. Revisit only if a clean first-party mechanism turns up.
- **Do Not Disturb / Focus mode toggle.** Apple removed simple AppleScript
  control of this after the Monterey Focus overhaul. Would need Shortcuts
  app integration (user has to pre-build a Shortcut) or fragile
  Accessibility-based UI scripting of Control Center. Not cheap like the
  rest of this batch turned out to be.
- **Direct file delete/move/rename by voice.** Real destructive risk if a
  transcript is misheard — unlike Empty Trash (recoverable, and the
  Trash's whole purpose), a wrong "delete that file" has no safety net.
  Would need a confirmation step at minimum before this is worth building.
- **Restart / Shut down.** Irreversible, loses unsaved work in every other
  running app, not just Sayline's own business. Likely permanently out of
  scope unless there's a strong, explicit reason to add it later.

## Known fragility (shipped, but worth knowing about)

- **System Settings pane identifiers are read live, not hardcoded**
  (`SettingsPaneCatalog`, shipped 2026-08-08 — see CHANGELOG) — scans
  `/System/Library/ExtensionKit/Extensions/*.appex` at launch, so the
  stale-identifier class of bug (Ventura's System Settings rewrite broke
  the old `com.apple.preference.*` scheme; `.general` went stale again
  later) is now self-healing across macOS updates rather than something
  to re-derive by hand. What's still worth knowing: Apple splits these
  extensions across two different plist schemas (`NSExtension` vs the
  newer `EXAppExtensionAttributes`) — if a future macOS version
  introduces a third schema, the scan would silently under-count again
  the same way the first verification pass did before this was caught.
  If the catalog's pane count ever looks low, check
  `SettingsPaneCatalog.extensionPointIdentifier(from:)` for a missed
  schema before assuming panes were removed.
- **`AgentExecutor` file-search folder fallback deliberately excludes
  `.home`** — it's a full recursive walk of the entire home directory and
  would be slow plus prompt-heavy. Only searched if the user names it
  explicitly.
- **Undo ("scratch that") isn't reliable after direct Accessibility-API
  text insertion** — only guaranteed after the clipboard-paste fallback
  path, since AX writes bypass the app's own undo stack. Documented,
  accepted limitation, not something being chased further.

## Unresolved from testing

- **E2 regression (voice commands) — root cause not confirmed.** During
  the agent-mode test pass, "scratch that" failed to undo once. Likely
  explanation is the AX-insertion undo limitation above resurfacing
  rather than an actual agent-mode regression, since nothing in
  `TextInjector.undo()` changed — but which app this happened in was
  never confirmed. Worth a quick live retest (note the target app) before
  fully closing this out.
- **B6 (unreproduced) — "open Preview" once opened Finder's Downloads tab
  instead**, and the indicator got stuck in "Transcribing" once before
  unsticking. Happened once, never reproduced since, root cause unknown.
  Watch for it recurring; if it does, check logs for that specific run
  before guessing at a fix.

## Deferred to the end of V2 (already decided, not re-litigated here)

- Auto-updates
- Onboarding flow (would be the natural place to front-load the
  Desktop/Documents/Downloads permission prompts as one batch at first
  launch instead of scattered surprises later — see PRODUCT.md)
- Code signing / notarization — blocked on $99 Apple Developer Program
  enrollment, not yet done
- Monetization

## Longer-term "grand vision" (explicitly one-step-at-a-time, not this phase)

- Email search ("look through my emails for anything from a recruiter")
- Calendar queries ("how many events do I have today")
- Browser automation (spawn a browser, search something, e.g. Airbnb)

These would likely need MCP-style integrations or dedicated APIs per
service — real work, deliberately not started until the current small
action set is solid.
