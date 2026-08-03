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

1. **Phase 1 — Dictation** (current focus). Get the core dictation
   experience genuinely good: fast, accurate, reliable across apps, feels
   like a real product. Everything in the README roadmap (V0/V1/V2) belongs
   to this phase.
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

## Deferred decisions (open, not urgent)

- **On-device transcription: whisper.cpp vs Apple SpeechAnalyzer.**
  whisper.cpp is more engineering work (C interop, model bundling) but
  works on older macOS and is more capable (100+ languages, fine-tunable).
  SpeechAnalyzer is far simpler to build but requires macOS 26+ and is a
  closed model with unclear accuracy advantage over Whisper large-v3
  specifically (benchmarks found beat smaller Whisper variants, not
  large-v3). Leaning whisper.cpp for shippability, not yet committed.
- **Monetization model.** Not decided. On-device transcription (once built)
  would make a generous free tier or one-time-purchase model viable, since
  marginal cost per user would approach zero for that path.

## Non-goals (for now)

- Windows/Linux support — macOS only, native, no cross-platform ambitions.
- Real-time streaming transcription — current pipeline is record-then-send,
  not live streaming; revisit only if latency becomes a real complaint.
