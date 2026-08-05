# Sayline — Backlog

Things deliberately parked, not forgotten. Each entry says *why* it's
parked and what it would take to unpark it. When picking this back up,
check it before starting — some of these have real technical reasons
they weren't done, not just time constraints. For current direction see
[PRODUCT.md](PRODUCT.md); for what's shipped see [README.md](README.md)
and [CHANGELOG.md](CHANGELOG.md).

## Next up (explicitly requested, in order)

- **List-shaped query answers** (e.g. "what are the biggest files in my
  Downloads folder"). Single-fact queries (battery, storage, memory,
  uptime, volume, macOS version, now-playing) shipped 2026-08-05, all
  displayed on the existing floating pill with a longer readable
  duration than the failure-flash. A list of several files with sizes
  doesn't fit one line the way a single fact does — needs either a hard
  condensed format or the pill growing into a small multi-line surface
  for this case specifically. Deliberately scoped separately from the
  single-fact batch rather than guessed at alongside it.

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

- **System Settings pane identifiers (`open_system_setting`) are
  version-fragile.** The working identifiers were pulled directly from
  `/System/Library/ExtensionKit/Extensions/*.appex` on this machine's
  actual macOS build, not guessed — but Apple has changed these before
  (Ventura's System Settings rewrite broke the old `com.apple.preference.*`
  scheme) and could again. If a pane opens the wrong thing after a macOS
  update, that's why — re-derive the identifier the same way rather than
  guessing.
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
