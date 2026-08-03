# Changelog

Chronological log of changes to Sayline. One row per meaningful change —
newest at the bottom, matching commit order. For the "why" behind
decisions, see [PRODUCT.md](PRODUCT.md); for current feature status, see
[README.md](README.md).

| Date | Area | Change |
|---|---|---|
| 2026-08-03 | Scaffold | Initial menu bar app shell (SwiftUI `MenuBarExtra`), xcodegen project setup, public GitHub repo created |
| 2026-08-03 | Hotkey | Global hotkey listener via CGEventTap — hold Right Option, gated behind Accessibility permission |
| 2026-08-03 | Audio | Audio capture via AVAudioEngine, records to temp `.wav` while hotkey held |
| 2026-08-03 | Transcription | Groq Whisper (large-v3-turbo) integration — sends recorded audio, gets transcript back |
| 2026-08-03 | Insertion | Clipboard + simulated Cmd+V text injection — completed V0 (full hotkey → record → transcribe → paste loop working) |
| 2026-08-03 | Insertion | V1: direct text insertion via Accessibility API (`kAXSelectedTextAttribute`), clipboard as fallback with restore |
| 2026-08-03 | Insertion | Bug fix: AX insertion was silently "succeeding" in web/Electron/canvas apps (Figma, Claude Code) without reaching the real UI — now verifies by reading the field back before trusting it |
| 2026-08-03 | Cleanup | V1: AI cleanup pass (Groq Llama 3.1 8B Instant) strips filler words, fixes grammar before insertion |
| 2026-08-03 | UI / Cleanup | V1: floating recording indicator (frosted-glass overlay, bottom-center) + dictation style picker (Verbatim / Clean / Concise), cycled via Tab while dictating, persisted across launches |
| 2026-08-04 | Product | Established product direction doc (`PRODUCT.md`) and this changelog; discussed and documented long-term "voice OS + agent" vision as Phase 2, with dictation (Phase 1) as current focus |
| 2026-08-04 | Transcription | V1: on-device transcription via WhisperKit (Argmax) — opt-in toggle, cloud remains default for new users. Fixed a real concurrency bug found via live testing (rapid hotkey presses during model download triggered overlapping downloads that corrupted the model cache); added single-flight loading. Redesigned the flow so opting in triggers the download immediately in the background, with dictation silently falling back to cloud until the model is ready — no blocking wait. Switched to Argmax's recommended compressed large-v3 model for a smaller download at the same accuracy tier. Verified live: fallback-to-cloud during download, then automatic switch to local once ready (sub-second transcription after the one-time model load) |
