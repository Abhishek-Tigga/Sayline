# Sayline

A native macOS dictation tool: hold a hotkey, speak, get text inserted wherever your cursor is — in any app. Inspired by tools like Flow (formerly Whisper Flow).

Built as a hands-on learning project and portfolio piece — commit history reflects the real build process, not a squashed final state. See [PRODUCT.md](PRODUCT.md) for the product direction and long-term vision, and [CHANGELOG.md](CHANGELOG.md) for a chronological log of changes.

## Status

✅ V1 complete: full dictation experience — cloud or on-device transcription, AI cleanup with selectable styles, customizable hotkey and mic, transcription history, BYOK settings. Onto V2 (shipping polish).

## Roadmap

**V0 — prove the pipeline** ✅
- [x] Menu bar app shell
- [x] Global hotkey (hold-to-talk)
- [x] Audio capture (AVAudioEngine)
- [x] Cloud transcription (Groq Whisper API)
- [x] Text injection at cursor (clipboard + simulated paste)

**V1 — make it feel real** ✅
- [x] Direct text insertion via Accessibility API (no clipboard)
- [x] AI cleanup pass (strip filler words, fix grammar)
- [x] Dictation style picker (Verbatim / Clean / Concise, cycle with Tab while dictating)
- [x] Floating recording indicator
- [x] On-device transcription option (WhisperKit)
- [x] Settings window: Groq API key (BYOK, Keychain-stored), cloud/local toggle, default dictation style, launch at login
- [x] Transcription history (last 20, separate window, copy-again button)
- [x] Microphone selection (auto-follows system default incl. AirPods, with a manual override in Settings)
- [x] Hotkey customization (any standard modifier key — Option/Command/Control/Shift, left or right, or Fn — takes effect live)

**V2 — ready to ship**
- [x] Context-aware formatting (Email/Chat/Code/General detected from the focused app; Code always stays verbatim regardless of style; browser tabs sniff the window title for known webmail apps since bundle ID alone can't see inside a browser)
- [ ] Code signing, notarization, installer (blocked on Apple Developer Program enrollment — deferred to last)
- [ ] Onboarding flow
- [ ] Voice commands
- [ ] Auto-updates
- [ ] Monetization (also blocked on signing/distribution being in place)

## Tech stack

- Swift + SwiftUI (menu bar app via `MenuBarExtra`)
- AVFoundation for audio capture
- Accessibility API (`AXUIElement`) for reading focus / inserting text
- [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (Argmax) for on-device transcription — opt-in, cloud (Groq) by default
- [xcodegen](https://github.com/yonaskolb/XcodeGen) — the `.xcodeproj` is generated from [`project.yml`](project.yml), not committed, to keep the repo diff-friendly

## Setup

Requires Xcode 15+ and [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open Sayline.xcodeproj
```

Transcription uses the [Groq](https://console.groq.com) Whisper API. Bring your own key (BYOK) via the app's Settings window (stored in the macOS Keychain) — or, for local development, set a `GROQ_API_KEY` environment variable instead (Xcode: **Edit Scheme → Run → Arguments → Environment Variables**). Never commit a key; it's never written to disk in plaintext.
