# Sayline — Product Direction

Living document. Updated as decisions get made or the direction shifts — this
is the "why," not the "what." For feature status, see [README.md](README.md).
For a chronological log of changes, see [CHANGELOG.md](CHANGELOG.md).

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
  integration.
- **Every new agent capability needs its own permission grant and its own
  confirmation/safety design.** A misheard command silently deleting a
  calendar event or sending something is a real failure mode. Not solved
  yet — needs real design work when Phase 2 starts, not an afterthought.

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
