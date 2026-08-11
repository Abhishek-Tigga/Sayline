# Sayline — Backlog

Things deliberately parked, not forgotten. Each entry says *why* it's
parked and what it would take to unpark it. When picking this back up,
check it before starting — some of these have real technical reasons
they weren't done, not just time constraints. For current direction see
[PRODUCT.md](PRODUCT.md); for what's shipped see [README.md](README.md)
and [CHANGELOG.md](CHANGELOG.md).

## Next up (explicitly requested, in order)

- **Google Calendar users see an empty calendar** (found live 2026-08-11,
  half-fixed, strategy not yet chosen).

  **The problem, in three parts.** Sayline reads through EventKit, which
  reads whatever Calendar.app holds. A user whose calendar lives in Google
  gets nothing unless they have added that account in System Settings →
  Internet Accounts. Even once added, CalDAV refreshes every 15 minutes by
  default, so a meeting created or moved minutes ago is not there yet. And
  all of it fails as "no meetings" — the same words as a genuinely free
  afternoon — which reads as a broken app rather than a setup step, while
  the meeting sits visible in a browser tab.

  This matters more than it sounds: most people's work calendar is Google,
  so the default experience for the feature's main audience is that it
  silently does not work.

  **Already shipped** (commit on 2026-08-11): an empty result is diagnosed
  before it is reported — no calendars offers to open Internet Accounts,
  a 24-hour-empty calendar names sync as a possible cause, genuinely
  nothing keeps the plain answer. Queries call `refreshSourcesIfNecessary()`
  first, which is best-effort and does not fix the 15-minute default. The
  query log names the accounts supplying calendars.

  That makes the gap visible and recoverable. It does not close it.

  **Two candidate paths, not yet decided.**

  *A — onboarding check.* Notice at first run that no calendars are
  configured and say so before the user tries a command and forms a first
  impression. Cheap, folds into the permission-status view already parked
  as O-E. Does not help the 15-minute staleness at all, and still depends
  on the user doing the setup.

  *B — read Google Calendar directly.* Removes the CalDAV dependency
  entirely for the users who need it most, and makes freshness ours rather
  than Calendar.app's.

  **An unverified claim, flagged rather than relied on.** The suggestion
  as first made was that OAuth PKCE lets a desktop app do this with no
  client secret and no backend, token in Keychain. The auth flow part is
  broadly right. What was not checked, and could change the answer:

  - `calendar.readonly` is a **sensitive scope**. Google requires app
    verification before users outside a test list can grant it — a review
    process with a privacy policy and possibly a security assessment,
    measured in weeks, not an afternoon.
  - Unverified apps are capped at a small number of test users, which is
    fine for development and not for shipping.
  - The loopback redirect flow for installed apps has changed over time;
    the currently supported shape needs confirming rather than assuming.
  - A refresh token in the Keychain is a long-lived credential for
    someone's calendar. That raises the stakes of the storage decision
    well above an API key.

  If verification is required, path B stops being "no backend needed" and
  starts being a compliance project — which changes the sequencing
  argument entirely, because the commercial backend is a plan rather than
  a thing.

  **What is worth deciding.** Whether B is achievable on the timeline the
  product needs, or whether A plus honest copy is the right answer until
  the backend exists. Building OAuth before the backend exists risks
  building it twice.

  **Probe of the Apple Calendar route (2026-08-11, ~10 minutes — treat as
  leads, not conclusions).**

  - `tell application "Calendar" to reload calendars` is a real command in
    Calendar.app's scripting dictionary and returns cleanly. **Confirmed
    that it returns, NOT that it pulls from the server** — the difference
    is the entire reason to use it, and it was not tested.
  - It launches Calendar.app *visibly*. A dictation app that opens Calendar
    every time someone asks about meetings is worse than the staleness it
    fixes, so this cannot run on every query. The shape that might work:
    offer it only when staleness is already suspected — the
    `suspiciouslyEmpty` case already exists — via the follow-up primitive,
    so nothing appears unasked.
  - A "Refresh Calendars" item exists under the View menu and is drivable
    through Accessibility, as a fallback if scripting is ever blocked.
  - No refresh interval was found in `com.apple.iCal`, so the 15-minute
    default does not appear to be a writable preference.
  - `~/Library/Accounts` is TCC-protected and reads as empty. `dataaccessd`
    performs the CalDAV sync and is private-framework territory.
  - No public API was found for adding a CalDAV account programmatically.
    Not an exhaustive search.

  **Findings on both routes (Fable, 2026-08-11 — the probe taken past its
  limits; each item says established or not).**

  *The Apple Calendar route, answering the four open questions:*

  1. **Adding or configuring a calendar account from an app: no supported
     way exists.** Established as firmly as a negative can be: the
     Accounts framework's add-account surface was never public API on
     macOS for this, `~/Library/Accounts` is TCC-protected, and a
     `.mobileconfig` CalDAV payload — the one real mechanism for
     provisioning CalDAV — is a dead end *for Google specifically*,
     because Google's CalDAV endpoint requires OAuth and macOS's Google
     account flow lives inside System Settings itself. The Internet
     Accounts deep link already shipped is the ceiling of what an app can
     do: put the user one click from the right pane.
  2. **The CalDAV refresh interval is not writable by code.** No key in
     `com.apple.iCal` (confirmed again), and the real setting is stored
     per-account in the TCC-protected Accounts store. BUT it is
     user-settable to **"Every minute"** in Calendar → Settings →
     Accounts → Refresh Calendars — which collapses the 15-minute
     staleness to ~1 minute with zero code. That sentence belongs in the
     `suspiciouslyEmpty` copy and in onboarding copy. This is the
     cheapest real mitigation found on either route.
  3. **`reload calendars` is weaker than the probe hoped — recommend
     dropping it.** The sdef's own description reads "reload all calendar
     *files* contents", i.e. re-read local data, which is exactly the
     thing that does NOT help; nothing suggests it pulls from the server,
     and it needs a per-app Automation grant plus a visible Calendar.app
     launch. The offer-only-when-stale shape was sound *if* the command
     pulled; since that is unestablished-leaning-no, this is the
     workaround that would embarrass us. Park it permanently unless
     someone demonstrates a server pull in a packet trace.
  4. **The approach nobody had ranked: measure `refreshSourcesIfNecessary`
     first.** Apple's docs describe it as pulling new data from remote
     sources when needed — if it genuinely triggers a CalDAV pull, the
     staleness problem is already fixed by the call shipped on
     2026-08-11, and every workaround above is moot. This is a
     ten-minute live test (edit an event in Google's web UI, ask Sayline
     within a minute, read the log) and it is the FIRST thing to do —
     before building anything. Also available and cheap:
     `EKEventStoreChanged` notifications to know when data moved
     (reactive hygiene, does not force sync), and the per-calendar
     secret ICS URL — see route C below.

  *The Google route, answering the four questions:*

  5. **Verification: established, and lighter than feared.**
     `calendar.readonly` is a **sensitive** scope (Google's own doc uses
     "reading events stored in Google Calendar" as its example).
     Sensitive-scope verification means brand/domain verification, scope
     justification, and a demo video — Google states **up to ~10 days**.
     The CASA security assessment Opus worried about applies to
     *restricted* scopes (Gmail, Drive); the sensitive-verification page
     requires no assessment. So path B is a ~10-day review, not a
     compliance project — but it is still a review, with a privacy
     policy and a homepage as prerequisites. (Scope classifications are
     documentation and move; re-check at build time. The definitive
     check remains creating the Cloud project and reading the real
     consent screen.)
  6. **Redirect flow: established.** Loopback (`http://127.0.0.1:port`)
     remains the supported flow for the Desktop client type — it was
     deprecated for iOS/Android/Chrome clients, *kept* for desktop.
     Custom URI schemes are deprecated. One correction to the original
     claim: Google issues Desktop clients a `client_secret`, it is just
     explicitly non-confidential — embeddable, not absent. No backend
     needed stands.
  7. **Test-user cap: established — 100 test users, and the part that
     actually bites: refresh tokens from an app in Testing status expire
     every 7 days.** A beta on Testing status means every user
     re-authorizes weekly. Workable for a handful of dev machines,
     wrong for a real beta; the fix is completing the (10-day)
     verification, after which both limits lift.
  8. **Keychain custody: acceptable, and arguably better than the
     backend.** A refresh token in the login Keychain is the standard
     custody model for native apps (every desktop Google client does
     this); it is device-bound, encrypted at rest, and revocable from
     the user's Google account page. A backend holding thousands of
     users' calendar tokens is a honeypot and an availability
     dependency. Scope it read-only, name the revocation path in the
     privacy copy, and Keychain is the right answer even after the
     backend exists.

  *Route C, proposed by neither: the per-calendar secret ICS URL.*
  Google Calendar exposes a "secret address in iCal format" per calendar
  — a capability URL, plain HTTPS GET, no OAuth, no verification, no
  test-user cap. The user pastes one URL into Sayline settings; it lives
  in the Keychain like a key. This solves the *absence* problem (no
  macOS account needed at all) with BYOK-grade friction the beta already
  tolerates. **Unestablished and decisive:** how stale Google serves
  that feed — third-party ICS subscribers have historically seen lag
  from minutes to hours. If the feed is fresh, C beats both A and B for
  the beta; if it lags hours, it is worse than a 1-minute CalDAV
  refresh. Ten-minute human test: create an event, curl the feed, time
  it.

  **Recommendation.** Neither A-then-wait nor B-now. Sequence:
  1. *Measure first*: the `refreshSourcesIfNecessary` live test (§4) and
     the ICS staleness test (route C) — twenty minutes total, and each
     result can delete a workaround from this list.
  2. *Ship A's remaining halves now*: the "Every minute" refresh-interval
     sentence in the stale-calendar copy, and the Internet Accounts
     nudge folded into onboarding when O-E unparks. Zero risk, helps
     every user including the ones B would never cover (Exchange,
     iCloud).
  3. *Hold B until commercialization*, then do it properly: the ~10-day
     sensitive verification is real but affordable exactly once there is
     a privacy policy, a homepage, and a shipping product to demo —
     all of which the backend/monetization milestone produces anyway.
     Building B during beta buys weekly re-auth pain and a review
     process ahead of the assets it needs.
  4. *Route C is the bridge if, and only if,* the measurements in step 1
     show CalDAV-at-1-minute still failing real beta users AND the ICS
     feed proves fresh. Otherwise skip it — two calendar pipelines is a
     real cost for a maybe.

- **Country-scoped site catalogs, served rather than compiled in**
  (raised 2026-08-11, parked until after meetings ships).

  The idea as put: detect the country at install, download only that
  country's config, and send only that during tool calling so the model
  processes fewer tokens.

  Half of it already exists as of today. Sites carry an optional region and
  `promptVocabulary` filters by it, so an Indian Mac is offered Flipkart
  and an American one is not — the token saving is already banked, with no
  download involved.

  **What the download would actually buy is different, and worth being
  precise about.** The catalog is compiled in, so a moved URL needs an App
  Store release. Serving it is a *fix velocity* change, not a token one.
  That distinction matters because it changes what to build: a static file
  the app fetches on launch and caches, falling back to the built-in copy,
  rather than an install-time country download.

  **One correction to the shape.** Downloading only one country's file
  would mean a user cannot reach any other country's sites at all. Region
  detection is a guess — `Locale.current.region` is the keyboard region,
  not where someone is — and people travel, and plenty of people shop
  across borders. The size argument does not hold either: the whole
  catalog is 24 KB of text, so shipping every country costs nothing worth
  measuring.

  So: **ship all countries, filter the prompt by region, serve the file for
  updates.** Same token saving, no cliff when the guess is wrong.

  Also on this thread: make the per-country lists exhaustive. India
  currently has four entries added reactively after two live refusals.
  Ajio, Nykaa, Zomato, BookMyShow, IRCTC and MakeMyTrip were all left out
  because curl could not verify them — every Indian retailer 403s — and
  guessing a URL is what this catalog exists to avoid. They need browser
  verification, one at a time.

- **A synonym layer for settings panes** (raised 2026-08-11 by a review
  pass, not yet built).

  The catalog only knows the names Apple ships. Measured against 26
  phrases people actually say, it rejects nine of them: volume,
  brightness, dark mode, screen saver, screensaver, microphone, camera,
  time zone, firewall. Today the model covers the gap by translating —
  "volume" becomes Sound, "brightness" becomes Displays — and that mostly
  works.

  It matters because it blocks a fix the user asked for. Asked to open a
  pane that does not exist, the model does not decline; it substitutes a
  real one, so "open banana settings" opens About confidently. The user
  was explicit that saying "I don't know that one" is better than opening
  the wrong panel.

  The obvious guard — refuse when the model's pane shares no word with
  what was spoken — was built on 2026-08-11 and reverted the same day. It
  caught banana and refused all nine phrases above, because "volume" and
  "Sound" share nothing either. Nine real intents traded for one nonsense
  one.

  **The order matters:** teach the catalog the synonyms first, then the
  comparison becomes safe to reintroduce, because anything still
  unresolved is genuinely unknown. Doing it the other way round is what
  failed.

  One caution from the record: `eval/results.md` notes an earlier attempt
  at pane aliases that regressed a case by giving the model a
  generic-sounding bucket to fall into. Add synonyms narrowly, one eval
  case each, rather than a broad alias table.

- **Disambiguate "tomorrow" said late at night** (requested 2026-08-11,
  parked deliberately — build the rest first).

  Found live at 01:06. Saying "remind me tomorrow at 10am" at one in the
  morning almost certainly means *nine hours from now*, not thirty-three.
  We currently take it literally, so the reminder lands a full day after
  it was wanted — and silently, because a date a day out still looks
  plausible when it flashes past in the pill.

  The model has no way to get this right on its own. It is told the
  current time and follows the calendar meaning of the word, which is
  correct English and the wrong answer. Nothing in the prompt can fix
  that without also breaking "tomorrow" said at 3pm, where the literal
  reading is right.

  **The shape it should take:** when the current hour is small — roughly
  midnight to 5am — and the request says "tomorrow", ask instead of
  guessing. The follow-up primitive already does this, and the question
  is a two-button one:

      Sayline
      Tomorrow at 10:00 — which did you mean?
      [ Today 10:00 ]  [ Tomorrow 10:00 ]

  Both options are named with their real date, because "today" at 1am is
  itself ambiguous to read.

  **Open questions for whoever builds it:**
  - Where is the boundary? Midnight–5am is a guess. The honest version
    keys off "is the named time still ahead of us today", which handles
    11pm→"tomorrow morning" too.
  - Does it apply to "tonight" and "this morning", which are worse? At
    1am "this morning" has already half happened.
  - Should it ask, or default to the nearer reading and say which it
    chose? Asking is safer but costs a turn on something people say
    often. Reading it back — "reminder set · Today, 10:00 AM" — may be
    enough on its own, since the message already names the day.

  That last one is worth settling before building: the feedback copy
  added on 2026-08-11 already says "Today" or "Tomorrow" out loud, so
  the wrong reading is now visible rather than silent. That may have
  already fixed the expensive half of this.

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
  Groq API calls came back HTTP 403 and the cause went unidentified at
  the time. **Root cause found 2026-08-09: Groq sits behind Cloudflare,
  which rejects Python's default `Python-urllib/x.y` User-Agent with
  403 "error code: 1010"** — no rate-limit headers, no JSON body,
  nothing resembling an API error, which is why it read like a bad key.
  Any honest agent string is accepted; `eval/run_eval.py` now sends
  `Sayline-Eval/1.0`. Nothing was ever wrong with the key. Reuse
  `post_json` from the eval harness rather than writing a fresh
  request, and this cannot recur. The 70B swap itself stays on hold
  until the test actually runs and shows a real difference — don't swap
  on assumption.
- **Open a URL / website by voice** (designed weeks ago, never
  written down here, never built — logged 2026-08-09 after it surfaced
  from memory rather than from this file, which is exactly the failure
  mode this document exists to prevent). Today "open youtube" runs
  `open -a "youtube"` and fails, because no app has that name.

  Two requests that sound alike but are very different jobs, and only
  the first is in scope for now:
  - **"open youtube" / "open toolfolio.com"** — resolve to a URL and
    hand it to the browser. Small.
  - **"play lo-fi music on youtube"** — open, search, then click play.
    That is browser automation, a different project entirely. See the
    grand-vision section.

  Agreed design from the original discussion: default browser via
  `NSWorkspace.shared.open(url)`; a named browser ("open x in Chrome")
  via `open -a <browser> <url>`, matching the existing open_app style;
  and a hybrid of a curated list of common sites plus domain guessing,
  so both "open youtube" and "open toolfolio.com" work. A 28-site
  starter list was proposed and approved but never committed anywhere,
  so it needs redoing.

  Worth deciding before building: what happens to a bare word that is
  neither a known site nor a valid domain. Guessing `.com` will
  sometimes be wrong, and opening the wrong site is more annoying than
  refusing. The visible-fallback pattern from the settings catalog
  probably applies.


- **Bring back native music playback: Apple Music, then Spotify**
  (Apple Music was built and working, then deliberately removed
  2026-08-09 — user asked to be reminded, so raise this unprompted when
  music comes up again). All music now defaults to YouTube, which does
  play real audio via the video path.

  **What was given up.** Apple Music had genuine transport control
  through AppleScript — play, pause, next track, previous — verified
  live moving the app from paused to playing. YouTube has no equivalent:
  a link can start a video, but nothing can pause or skip what is
  already playing. So "pause" and "next track" no longer do anything.
  That is the real cost of the simplification, and it is worth
  re-reading before deciding this was purely a cleanup.

  **What was already impossible, so nothing was lost there.** Playing a
  *named* song through Apple Music never worked and the dead ends are
  documented: the free iTunes Search API does return the exact track,
  but opening its URL leaves Music.app `stopped`, and sending `play`
  afterwards errors with "Can't get name of current track" because a URL
  navigation never queues anything. Real catalogue playback needs
  MusicKit — Apple Developer account ($99/yr, already required for code
  signing), a MusicKit key and developer token, plus an Apple Music
  subscription on the user's side.

  **Spotify**, still never built, hits a similar wall: it exposes the
  same AppleScript transport verbs, so play/pause/skip would work, but
  `play track` takes a URI and getting one for a named song needs their
  Web API.

  Restoring transport control is small — the removed `controlMusic` in
  `AgentExecutor` plus its `control_music` tool, recoverable from git
  history around commit `df34cd5`. Deciding *which* app a bare "pause"
  should target when several are installed is the actual design
  question, and probably means whichever is currently playing.

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
