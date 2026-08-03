# Sayline

A native macOS dictation tool: hold a hotkey, speak, get text inserted wherever your cursor is — in any app. Inspired by tools like Flow (formerly Whisper Flow).

Built as a hands-on learning project and portfolio piece — commit history reflects the real build process, not a squashed final state.

## Status

🚧 V0 in progress. Currently: a bare menu bar shell with no dictation functionality yet.

## Roadmap

**V0 — prove the pipeline**
- [x] Menu bar app shell
- [x] Global hotkey (hold-to-talk)
- [ ] Audio capture (AVAudioEngine)
- [ ] Cloud transcription (Groq Whisper API)
- [ ] Text injection at cursor (clipboard + simulated paste)

**V1 — make it feel real**
- [ ] Direct text insertion via Accessibility API (no clipboard)
- [ ] AI cleanup pass (strip filler words, fix grammar)
- [ ] On-device transcription option (whisper.cpp)
- [ ] Floating recording indicator
- [ ] Settings: hotkey, mic, cloud/local toggle
- [ ] Transcription history

**V2 — ready to ship**
- [ ] Code signing, notarization, installer
- [ ] Onboarding flow
- [ ] Context-aware formatting
- [ ] Voice commands
- [ ] Auto-updates
- [ ] Monetization

## Tech stack

- Swift + SwiftUI (menu bar app via `MenuBarExtra`)
- AVFoundation for audio capture
- Accessibility API (`AXUIElement`) for reading focus / inserting text
- [xcodegen](https://github.com/yonaskolb/XcodeGen) — the `.xcodeproj` is generated from [`project.yml`](project.yml), not committed, to keep the repo diff-friendly

## Setup

Requires Xcode 15+ and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open Sayline.xcodeproj
```
