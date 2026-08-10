# Sayline — working notes for Claude

Native macOS menu-bar dictation app, plus an agent mode. Hold a hotkey and
speak to dictate; hold it and press Space to issue a command instead.

Swift + SwiftUI, no Electron. Commercial product with its own backend —
**not** bring-your-own-key, whatever older notes suggest.

## Build and run

The `.xcodeproj` is generated and gitignored. **Run `xcodegen generate`
after adding or removing any Swift file** or the build won't see it.

```bash
xcodegen generate
xcodebuild -project Sayline.xcodeproj -scheme Sayline -configuration Debug build
```

Relaunching with logs visible — the app is a menu-bar agent, so `NSLog`
output only reaches you through the redirect:

```bash
pkill -x Sayline; sleep 1
open --stderr /tmp/sayline.log ~/Library/Developer/Xcode/DerivedData/Sayline-*/Build/Products/Debug/Sayline.app
```

"Build succeeded" is not verification. Almost every bug in this project's
history was found by running it and reading `grep "Sayline:" /tmp/sayline.log`,
not by compiling.

## Read these before changing behaviour

The reasoning is the part that gets lost — the decisions are visible in the
code, the rejected alternatives are not.

| File | What it holds |
|---|---|
| `DESIGN-meetings-reminders.md` | 21 decisions with their rejected alternatives. Meetings are designed but **not built** |
| `BACKLOG.md` | Parked work, each with why it's parked and what unparks it |
| `PRODUCT.md` | Direction and the "why" behind product calls |
| `CHANGELOG.md` | One row per meaningful change |
| `eval/README.md` | What the router metrics mean, and the rules for changing the test set |
| `review/LEDGER.md` | What has been claimed, what has been independently checked, what is still open |

If something looks wrong, check these first. Several apparent mistakes are
decisions with reasons written down.

**Append to `review/LEDGER.md` when you close a review finding.** It is
shared with whoever reviews next, and it carries one rule that is not
optional: you may mark your own work `claimed-fixed`, never `VERIFIED`.
Only a different reviewer promotes it, and only after running something.

## How to verify

Four layers, all cheap, none of them optional when touching what they cover.

**Router accuracy** — 57 cases against the live model. Reads the real prompt
and tools out of `AgentRouter.swift`, never its own copy:

```bash
python3 eval/run_eval.py --arm openai --dry-run          # compiles only, no API calls
python3 eval/run_eval.py --arm openai --model gpt-4o-mini
```

Run the `--dry-run` line after **any** change to which files `AgentRouter`
depends on. The harness compiles a hand-maintained list, and splitting
`LocalTimestamp` out of `AgentRouter` broke it for a day without anyone
noticing — the eval only runs when a human runs it.

**Deterministic logic** — the half the router eval structurally cannot see,
because it scores what the model emits, not what we do afterwards:

```bash
swiftc -o /tmp/chk Sources/Sayline/WebsiteCatalog.swift eval/catalog-checks/main.swift && /tmp/chk
swiftc -o /tmp/chk Sources/Sayline/FollowUp.swift eval/consent-checks/main.swift && /tmp/chk
swiftc -o /tmp/chk Sources/Sayline/LocalTimestamp.swift eval/timestamp-checks/main.swift && /tmp/chk
```

**Live URLs** — the catalog is compiled in, so a moved URL needs a release.
This detects, it cannot heal:

```bash
python3 eval/url-health.py
```

**By hand** — `eval/manual-web-checklist.md`. The eval sends clean text; the
app gets whatever the transcriber heard. That gap has hidden real bugs that
the eval passed.

## Conventions that were earned

**Deterministic rules beat prompt engineering.** Every attempt to fix a
routing bug by rewording the prompt has failed or regressed something else.
Every fix that held was code: `correctedSettingsPane`, the personal-pages
table, `LocalTimestamp`. When we know the answer, don't ask the model.

**Write the test case before the fix.** The test set is the record of what
broke. A case added after the fix tends to describe the fix rather than the
bug.

**Measure before and after.** Accuracy, prompt tokens, latency. The standing
rule is that a new feature must not make the system slower; when a change
costs something, report the number rather than spending it quietly.

**Fail open, and say what happened.** A check that cannot decide should let
the work through. A silence gate that failed closed ate real dictation; a
page check that treated 503 as "missing" threw away correct URLs.

**Prototype UI in HTML first.** Both pill designs and the follow-up states
were settled by looking at a throwaway page. Some questions cannot be
answered by talking — build the disposable version and look at it.

## Settled — read the reasoning before reopening

- **Liquid Glass is parked, not deleted.** `SurfaceStyle.parkedGlass` is one
  line from returning. Six fixes for its backdrop flicker were tried and
  rejected; the flicker *is* the glass look. See the note in
  `RecordingIndicatorView.swift`.
- **Personal pages are deliberately not HEAD-verified.** They are auth-gated,
  our check carries no cookies, and `github.com/pulls` answers 404 to a
  logged-out request. Verifying would break the feature it protects.
- **Escape is observed, not consumed.** Swallowing it would eat a key press
  the focused app may need.
- **The microphone never reopens on its own.** A follow-up question is
  answered by holding the hotkey. A dictation app should not start listening
  unasked.
- **Agent mode is a separate trigger, not intent detection.** Telling "type
  this" from "do this" by words alone is unreliable.

## Open problems

- **The Mac freezes during use, cause unknown.** Two theories tested and
  disproven — event-tap starvation, and an `NSPanel` leak (14 created, 14
  deallocated). Not fixed, not reproduced on demand. The event tap is the
  most-suspected component; treat changes there as higher risk.
- **Meetings are designed and unbuilt.** No EventKit calendar code exists.
- **~2s latency on every agent command** — the router round trip. Real, and
  currently unaddressed.
- **Two API keys were pasted in chat** and should be rotated.

## Style

The user is a PM with an EE background, learning to code hands-on. Keep
replies short and plain: small words, short paragraphs, jargon explained
inline. Still teach — they want to understand the why, not just get the
result.
