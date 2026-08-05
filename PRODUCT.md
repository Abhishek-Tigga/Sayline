# Sayline — Product Direction

Living document. Updated as decisions get made or the direction shifts — this
is the "why," not the "what." For feature status, see [README.md](README.md).
For a chronological log of changes, see [CHANGELOG.md](CHANGELOG.md). For
things deliberately parked for later (and why), see
[BACKLOG.md](BACKLOG.md).

## Vision

Sayline starts as a dictation tool (hold a hotkey, speak, text appears at
your cursor) but the intended end state is broader: a **voice OS layer for
the Mac** — dictation plus the ability to spawn an agent that acts on your
behalf (check your calendar, set a reminder, search the web, etc.), all
triggered by voice.

Two explicit phases:

1. **Phase 1 — Dictation** (V1 complete as of 2026-08-04). Core dictation
   experience: fast, accurate, reliable across apps, feels like a real
   product. Everything in the README roadmap (V0/V1/V2) belongs to this
   phase — V2 (shipping polish) is next.
2. **Phase 2 — Agent layer**. Voice-triggered actions on top of the
   dictation foundation. Not started. Deliberately deferred until Phase 1
   is solid — see "Deferred decisions" below for what's already been
   thought through so Phase 1 doesn't paint us into a corner.

This is also a **portfolio piece** — the user is learning to build hands-on,
and the commit history is meant to show real, verified incremental work
rather than a squashed final state. Every feature gets built, tested live,
and committed before moving on.

## Key architectural decisions (and why)

- **Native Swift/SwiftUI, not Electron/Tauri.** Needed real Accessibility
  API access and lowest latency for a tool where feel/speed is the whole
  point.
- **xcodegen instead of a committed `.xcodeproj`.** Keeps the repo
  diff-friendly for a portfolio audience; `project.yml` is the source of
  truth, the `.xcodeproj` is generated and gitignored.
- **Groq for both transcription (Whisper large-v3-turbo) and cleanup
  (Llama 3.1 8B Instant).** Chosen for speed (same low-latency provider for
  both calls) and cost (see cost analysis below) — not because either model
  is uniquely best in class, but because the combination is fast and cheap
  enough to not be the bottleneck.
- **One permission (Accessibility) gates both the hotkey and text
  insertion.** Deliberately avoided also requiring separate Input
  Monitoring permission — simpler permission story for the user.
- **Direct AX text insertion, with clipboard+paste as a verified fallback.**
  AX writes can silently "succeed" without reaching the real UI in
  web/Electron/canvas apps (found via live testing in Figma and Claude
  Code) — insertion is verified by reading the field back, not trusted
  blindly.
- **Dictation styles (Verbatim / Clean / Concise) are about fidelity, not
  tone.** Tone/audience adaptation (email vs Slack vs code) is intentionally
  left to the V2 "context-aware formatting" item rather than folded into
  the style picker, to avoid two overlapping mechanisms doing similar jobs.
- **On-device transcription via WhisperKit (Argmax), not raw whisper.cpp.**
  WhisperKit is a Swift-native package (MIT licensed, macOS 14+ — matches
  our existing deployment target) that already solves C interop and model
  bundling, so we don't hand-roll either. Uses the compressed large-v3
  variant specifically (`large-v3-v20240930_626MB`) — Argmax's own
  recommended max-accuracy pick, meaningfully smaller than the
  device-auto-selected default. Still real Whisper, so we keep the
  100+ language support that was the whole reason whisper.cpp was in the
  running over Apple's closed SpeechAnalyzer.
- **Local transcription is opt-in, never silently auto-downloaded.** New
  users default to cloud (Groq) — no large download blocks the first
  dictation before they've even seen the product work. But once a user
  opts in via the toggle, the model download starts immediately in the
  background (not lazily on first dictation), and any dictation attempted
  before it's ready silently falls back to cloud rather than blocking —
  opt-in is the consent gate, auto-download is the mechanism *after* that
  gate, not a replacement for it.
- **Cloud transcription is BYOK (bring your own key), not a shared
  embedded key.** Considered three options: embedding our own key in the
  shipped app (not viable — any shipped binary can be inspected, so an
  embedded secret would get extracted and abused, a well-known attack on
  this exact pattern); a backend proxy that holds the key server-side with
  per-user metering (the actual "seamless, no setup" experience real
  products use, but requires standing up a backend + auth + usage
  tracking we don't have — a distinct future project, not settings-UI
  scope); or BYOK (user brings their own free Groq key, entered in
  Settings, stored in the macOS Keychain, never plaintext). Went with BYOK
  for now — it's the only one actually buildable without new
  infrastructure. Revisit the backend-proxy option when actually
  shipping/monetizing (see "Deferred decisions").
- **Microphone: auto-follow system default, with a manual override —
  not a full device-management UI.** Verified live that AVAudioEngine
  already tracks whatever macOS considers the default input device
  automatically (it picked up AirPods on the very next recording after
  connecting them, zero code of ours involved), since we re-read the
  input format fresh at the start of every recording rather than caching
  it. The only real new work was the manual pin (Core Audio device
  enumeration + `kAudioOutputUnitProperty_CurrentDevice`) for the case
  where someone wants a specific mic regardless of system default (e.g.
  a desk mic for quality, even with AirPods connected for calls).
- **Hotkey customization scoped to modifier keys only, not arbitrary key
  combos.** Detection relies on a clean `flagsChanged` down/up signal,
  which modifier keys (Option/Command/Control/Shift, left or right, or
  Fn) give naturally and regular keys don't. A full shortcut recorder
  supporting arbitrary combos would be materially more work (chord
  handling, conflict detection with system/app shortcuts) for a V1 item —
  revisit only if a modifier key turns out not to be enough for someone.
  Changing it is live — no tap recreation needed, since the tap already
  watches all flagsChanged events and just compares against whichever
  keycode is currently selected.
- **Context-aware formatting is a separate axis from dictation style,
  not a replacement for it.** Style (Verbatim/Clean/Concise) controls
  fidelity; context (Email/Chat/Code/General) controls tone/register.
  They combine — e.g. Clean + Email strips fillers *and* leans
  professional. Detected from the focused app's bundle ID at the moment
  the hotkey is pressed, using native `NSWorkspace` (app identity) and
  the Accessibility API (window title) — deliberately not a third-party
  library or `CGWindowListCopyWindowInfo`, since the latter needs Screen
  Recording permission (heavier, scarier) instead of reusing the
  Accessibility trust we already have for everything else.
- **Code context always forces verbatim, overriding whatever style is
  selected.** Rewriting text dictated into a code editor/terminal risks
  silently corrupting something precise (a variable name, an exact
  string) — a correctness risk, not a stylistic choice worth leaving to
  the user's selected style.
- **Bundle-ID detection has a real, confirmed ceiling — verified live,
  not assumed:**
  - Cannot distinguish different modes/tabs within one app. Tested
    directly against Claude Desktop's Chat/Co-work vs Code tabs — same
    bundle ID, same window title ("Claude") in both. Not fixable without
    something both deeper and unreliable; not worth chasing for one app.
  - Cannot see inside browser tabs by bundle ID alone, since every tab
    shares the browser's bundle ID — but the *window title* often can.
    Found via live testing that dictating into Gmail-in-Chrome fell to
    `.general` even though the title clearly read "...Gmail - Google
    Chrome...". Fixed by adding webmail title-signature matching
    (Gmail/Outlook/Yahoo Mail/ProtonMail) specifically for known browser
    bundle IDs, layered on top of the bundle-ID mapping. The more robust
    version of this — querying the browser's actual current-tab URL via
    AppleScript/Apple Events instead of string-matching a title — was
    considered and deferred: more reliable, but needs its own
    "Sayline wants to control Google Chrome" permission per browser.
    Revisit if title-matching proves too fragile.
- **The debug readout in the floating indicator (app name, bundle ID,
  window title, resolved context) is intentionally visible right now,**
  not polished away — the user explicitly wants to verify detection is
  actually working before any UI pass, since a wrong-but-invisible
  context would be worse than an ugly-but-verifiable one. Revisit
  placement/visibility once the broader UI gets redesigned.
- **Voice commands are whole-utterance-only, detected before cleanup —
  never mid-sentence, never improvised by the cleanup LLM.** A
  dictation only counts as a command ("scratch that"/"undo that" →
  undo, "new paragraph"/"new line" → insert a break) if the ENTIRE
  recording is essentially just that phrase. "Scratch that idea, let's
  go with plan B" must never trigger anything. Commands bypass style
  and context entirely, including Code context, since e.g. "new line"
  while dictating into a terminal is a genuinely useful command there
  too.
- **Matching is fuzzy (Jaro-Winkler) + a word-count guard, not exact
  string equality — and the word-count guard exists because of a real
  bug the similarity score alone missed.** Researched real precedent
  first (Wispr Flow's own "Command Mode," Talon Voice's modal design)
  before building — our whole-utterance approach matches established
  practice, not a naive first attempt. Added Jaro-Winkler (the
  recommended algorithm for short-string matching, not Levenshtein) to
  tolerate transcription noise like "scratch dat" or "scratch it"
  without an LLM call. But similarity alone wasn't sufficient: live
  testing found "scratch that idea" scored 0.94 against "scratch
  that" — Jaro-Winkler weighs shared prefixes heavily, so one extra
  trailing word barely dents the score — and would have wrongly
  triggered the command on real dictated content, exactly the failure
  mode this whole feature exists to prevent. Fixed by requiring equal
  word count alongside the similarity threshold: tolerates a *misheard*
  word, never an *extra* one. Re-verified post-fix with the exact
  failing phrase plus longer sentences containing command words —
  none trigger the command anymore.
- **Deliberately did not build mid-sentence self-correction handling**
  (e.g. "let's meet Tuesday, wait no, Friday" → "Let's meet Friday"),
  even though Wispr Flow markets exactly this. It's a real, different
  feature from Command Mode — doing it safely needs much more carefully
  scoped prompting than we have, and it's adjacent to the exact
  cleanup-LLM data-loss bug found and fixed in the previous entry.
  Revisit only with real intent to invest in getting it right, not as
  a quick addition.
- **Found and fixed a real, dangerous cleanup-prompt gap via live
  testing: the LLM would sometimes silently delete unrelated dictated
  content, not just clean it.** Two related failure modes, both from
  the same root cause (the cleanup prompts never told the model NOT to
  treat the input as an instruction directed at it):
  1. Short ambiguous input like "delete that" (alone, not matching a
     real voice command) got answered conversationally — *"I'd be
     happy to help you with that."* — instead of being cleaned as text.
  2. Far more seriously: dictating a long sentence containing "scratch
     the last sentence" mid-transcript caused the model to actually
     perform that edit — and in one case, it went further and silently
     dropped an entire *unrelated* trailing sentence the speaker never
     asked to remove. That's undirected data loss from a dictation
     tool, not a stylistic quirk — about as bad as this class of bug
     gets.
  Fixed with an explicit guardrail appended to every style prompt with
  real LLM involvement: never treat input as a command directed at the
  model, never respond conversationally, never drop content because it
  resembles an editing instruction — only genuine disfluencies get
  removed. Re-tested the exact failing inputs after the fix: the
  previously-dropped trailing sentence now survives across three
  different phrasings, and "delete that" alone now stays as literal
  text. One acceptable residual: the model still drops the
  editing-instruction phrase itself (e.g. "Delete the last sentence.")
  rather than keeping it completely verbatim — a much softer deviation
  than silently losing real content, not worth fighting further right
  now.

## Cost model (as of 2026-08-04, Groq pricing)

Per dictation: ~$0.00011 (transcription, 10s billing minimum dominates) +
~$0.00001 (cleanup pass, if not Verbatim) ≈ **$0.00012/dictation**. At
moderate use (50 dictations/day) that's roughly **$0.18/user/month** — cheap
enough that API cost is unlikely to be the main economic constraint at
plausible subscription pricing. Full breakdown was worked through in
conversation on 2026-08-04; re-derive if Groq's pricing changes materially.

## Phase 2 groundwork (decided now, not built yet)

- **Agent mode needs a separate trigger from dictation**, not automatic
  intent detection. Distinguishing "type this sentence" from "do this
  action" from words alone is unreliable and risks the tool doing
  unwanted things. A distinct hotkey/hold-key for agent mode keeps this
  predictable and means Phase 1's architecture doesn't need reworking —
  agent mode becomes a second mode next to dictation, not a rewrite.
- **Lean on macOS Shortcuts / App Intents for action execution** rather
  than hand-building integrations for Calendar, Reminders, web search,
  etc. one at a time. The agent's job becomes "turn a voice command into a
  Shortcuts run request" wherever possible, not reimplementing every
  integration. **Turned out differently in practice** — see below.
- **Every new agent capability needs its own permission grant and its own
  confirmation/safety design.** A misheard command silently deleting a
  calendar event or sending something is a real failure mode. Not solved
  yet — needs real design work when Phase 2 starts, not an afterthought.
  **Now characterized concretely** — see below.

## Phase 2 agent mode — first slice shipped and hardened (2026-08-04/05)

Trigger: hold Option, press Space to flag the current recording as an
agent request instead of dictation (per-hold, not persistent). Routes via
Groq LLM tool-calling (`llama-3.3-70b-versatile`, `tool_choice: "auto"` so
an out-of-scope request declines safely instead of forcing a bad match).

**Action execution ended up being direct native macOS APIs
(`Process`/`NSWorkspace`/`NSAppleScript`/`CGEvent`), not Shortcuts/App
Intents as originally planned.** For a small, explicit action set this
was simpler and gave more control over failure detection (e.g. checking
`open`'s exit status, retrying after a permission grant) than shelling
out to `shortcuts run` would have. Worth revisiting Shortcuts/App Intents
if the action set grows much larger or needs deeper per-app integration
than a system call can reach.

Current action set: open/close app, find file (with folder fallback +
subpath support for nested folders), open folder, open a System Settings
pane, lock screen, volume (mute/unmute/up/down), Wi-Fi on/off, Dark
Mode/Light Mode, empty Trash, screenshot. Multiple actions in one hold
are supported ("open Safari, then open Finder" does both — the router
now processes every tool call the model returns, not just the first).

**The permission landscape turned out to span five separate TCC
categories**, discovered through live testing rather than designed
upfront: Accessibility (hotkey/insertion, already had this), Microphone,
per-folder access (Desktop/Documents/Downloads — each separate, each
lazy/first-touch), Automation (per *target* app — System Events for dark
mode, Finder for empty trash — a new grant per app controlled, not one
blanket permission), and Screen Recording (screenshot). All of these
reset on every rebuild under the current ad-hoc "Sign to Run Locally"
signing (same root cause as the existing Keychain-prompt rough edge) —
dev-only pain, goes away entirely once real code signing lands.

**Real bugs found and fixed via live testing, worth remembering:**
- The floating status panel (`FloatingIndicatorWindow`) went silently
  stuck after enough show/hide cycles — stopped responding to
  `orderFrontRegardless()` with no error. Root cause was never fully
  pinned down (suspected `NSPanel` + `.canJoinAllSpaces`/`.stationary`
  interacting badly with Space/focus changes); fixed structurally by
  making the panel disposable — rebuilt fresh on every show rather than
  reused for the app's lifetime — so no accumulated AppKit state can get
  it stuck, regardless of the exact trigger.
- System Settings pane identifiers (`open_system_setting`) — the classic
  `com.apple.preference.*` scheme was wrong or reassigned for several
  panes on modern macOS (e.g. "general" now belongs to Appearance, not
  General; Network and Wi-Fi share one legacy ID and macOS picks Wi-Fi).
  Fixed by reading the real identifiers directly out of
  `/System/Library/ExtensionKit/Extensions/*.appex/Contents/Info.plist`
  on a live machine instead of guessing — still version-fragile across
  macOS releases in principle, but verified against an actual install.
- `find_file` had no visible feedback on failure at all — a no-match or
  a failed action did nothing observable, making "it failed" and "it
  silently succeeded" indistinguishable during testing. Fixed by having
  `AgentExecutor.execute` report success/failure and flashing a brief
  message on the indicator when nothing matched or an action failed.
- The very system call that triggers a folder-permission dialog doesn't
  retroactively succeed just because the user clicked Allow — the *next*
  call does. A real first-time-user's first request into a fresh folder
  would silently fail for a reason unrelated to whether the file exists.
  Fixed with a single automatic retry after a failed search.
- The model has to guess a folder when the user doesn't name one, and
  that guess is a semantic hunch, not real knowledge — "find meeting
  notes" guessed Documents when the file was in Downloads. Fixed by
  falling back across the other known folders (excluding Home, which is
  a slow recursive walk) before giving up.

## Agent mode can answer questions (2026-08-05)

Everything above is fire-and-forget — do a thing, maybe show a brief
failure pill. A real chunk of what people ask for is a *question*, not
an action ("what's my battery at," "how much storage do I have left"),
which needed a genuinely different shape, not just another tool in the
action list.

**Decided on purpose rather than defaulting into it:**
- **No second LLM call to phrase answers.** Once the real number is in
  hand (battery %, bytes free, uptime), formatting it into text is just
  string templating in Swift. Routing an already-correct fact back
  through an LLM to "say it nicely" would only add latency and a real
  hallucination risk for a case where correctness matters more than
  phrasing. The LLM's job stays exactly what it already does — pick the
  right tool and parameters — not narrate the result.
- **Answers display only, never spoken (no TTS).** User's explicit call.
- **Reuses the same tool-calling router**, not a parallel system — query
  tools sit in the same `tools` list as action tools, so a single hold
  can mix both ("open Safari, then what's my battery"). `AgentAction`
  distinguishes them at the type level (`.answerQuery` vs. every action
  case) since "did it succeed" isn't the right question for a fact
  lookup — handled by a separate `AgentExecutor.answer(_:) -> String`
  path rather than the Bool-returning `execute(_:)`.
- **Answers get a longer on-screen duration (4.5s vs. the 1.6s
  failure-flash)** — you need time to actually read a number, not just
  notice something happened.

Shipped: battery, storage, memory, uptime, volume level, macOS version,
now-playing (Music.app/Spotify only, by name via AppleScript — see
below for why not more than that). List-shaped answers ("biggest files
in my Downloads folder") deliberately deferred — see BACKLOG.md; a list
doesn't fit the single-line pill the way one fact does, and needs its
own UI decision rather than a guess.

**Two queries considered and dropped, both confirmed live, both logged
in BACKLOG.md with the reasoning:**
- **Wi-Fi network name** — assumed the `networksetup` CLI would sidestep
  CoreWLAN's permission gate; it doesn't. macOS withholds the real SSID
  from any process without Location Services permission (SSID can
  geolocate a device). Confirmed live: reported "not connected" while
  actually connected — the withholding behavior, not a bug. Adding
  Location Services for a minor query is a bad trade for an app whose
  whole pitch is dictation privacy.
- **Now-playing for browser-sourced media** (confirmed live against
  YouTube in Chrome) — browsers don't expose a queryable "current track"
  the way Music/Spotify do; the only way in is Apple's undocumented
  MediaRemote framework, exactly the private-API fragility already
  avoided when now-playing was designed.

## Known rough edge (expected until V2 code signing)

One Keychain prompt per fresh build/launch is real and understood, not a
bug to chase: our current "Sign to Run Locally" ad-hoc signing doesn't
give the app a stable identity across rebuilds, so macOS can't reliably
remember a Keychain access grant the way it would for a properly
Developer-ID-signed app (like Whisper Flow). Goes away entirely with real
code signing — already on the V2 list.

Two related bugs were found and fixed via live testing on top of that
expected behavior, both worth remembering:
- **`APIKeyProvider` caching flaw → retry storm.** The original cache
  used a plain `String?`, which can't distinguish "never checked" from
  "checked and got nothing" (e.g. a denied/interrupted prompt) — both
  look like nil. One denied prompt meant the very next call (two happen
  per dictation) retried from scratch, compounding into a real,
  observed infinite prompt loop that made the app briefly unusable.
  Fixed by tracking `hasResolved` separately from the cached value.
- **CGEventTap can be silently disabled by the system.** macOS may
  auto-disable an active event tap it decides isn't keeping up — with
  zero indication to the app. `HotkeyManager` now listens for
  `.tapDisabledByTimeout`/`.tapDisabledByUserInput` and immediately
  re-enables the tap; without this, the hotkey can go dead mid-session
  with no error, no crash, nothing in the logs to point at.

## Deferred decisions (open, not urgent)

- **Monetization model.** Not decided. On-device transcription (once built)
  would make a generous free tier or one-time-purchase model viable, since
  marginal cost per user would approach zero for that path.
- **Backend-proxied cloud key (replacing BYOK).** Would give the seamless
  "no setup" experience real consumer products have, but needs a real
  backend (server holding the Groq key, per-user auth, usage metering) we
  don't have today. Natural to build alongside monetization/shipping
  (V2), not before.

## Non-goals (for now)

- Windows/Linux support — macOS only, native, no cross-platform ambitions.
- Real-time streaming transcription — current pipeline is record-then-send,
  not live streaming; revisit only if latency becomes a real complaint.
