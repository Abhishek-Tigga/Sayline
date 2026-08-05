# Sayline — Backlog

Things deliberately parked, not forgotten. Each entry says *why* it's
parked and what it would take to unpark it. When picking this back up,
check it before starting — some of these have real technical reasons
they weren't done, not just time constraints. For current direction see
[PRODUCT.md](PRODUCT.md); for what's shipped see [README.md](README.md)
and [CHANGELOG.md](CHANGELOG.md).

## Next up (explicitly requested, in order)

- **"Sayline can answer questions."** Everything agent mode does today is
  fire-and-forget (do a thing, maybe show a brief failure pill). A real
  chunk of what people will ask for is a *question*, not an action —
  "what's my battery at," "what's playing," "how much storage do I have
  left." Answering means the agent has to speak or display a result back,
  which doesn't exist in any form yet. This is a distinct capability, not
  another entry in the action-router's tool list — needs its own design
  pass (how does an answer surface — the floating pill? something else?
  does it get spoken via TTS?) before implementation starts.

## Agent actions considered and skipped (technical reasons, not scope)

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
