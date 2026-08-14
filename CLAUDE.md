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

**There is a persistent log now** — `~/Library/Logs/Sayline/sayline.log`,
written with no redirect and reachable from the menu bar via *Reveal Log
File*. It is what a user can actually hand over. The stderr redirect below
is still useful for watching live.

Relaunching with logs visible — the app is a menu-bar agent, so `NSLog`
output only reaches you through the redirect:

```bash
pkill -x Sayline; sleep 1
open --stderr /tmp/sayline.log ~/Library/Developer/Xcode/DerivedData/Sayline-*/Build/Products/Debug/Sayline.app
```

"Build succeeded" is not verification. Almost every bug in this project's
history was found by running it and reading `grep "Sayline:" /tmp/sayline.log`,
not by compiling.

**Rebuilds no longer reset permissions** (since 2026-08-13). The build was
ad-hoc signed, whose designated requirement is the literal binary hash, so
every rebuild looked like a different app to macOS: Accessibility and
Microphone grants dropped, and the Keychain refused the stored Groq key with
`errSecAuthFailed` (-25293). It now signs with the Apple Development
certificate in `project.yml`, and the requirement names the certificate
instead of the hash. If permissions start resetting again, check the app is
still signed before debugging anything else:

```bash
codesign -d -r- ~/Library/Developer/Xcode/DerivedData/Sayline-*/Build/Products/Debug/Sayline.app
```

A requirement reading `cdhash H"..."` means it fell back to ad-hoc — see the
comment above `CODE_SIGN_IDENTITY` in `project.yml`. This is a development
certificate: it fixes rebuilds on this machine and does **not** let anyone
else run the app. Shipping still needs Developer ID and the paid programme.

## Read these before changing behaviour

The reasoning is the part that gets lost — the decisions are visible in the
code, the rejected alternatives are not.

| File | What it holds |
|---|---|
| `DESIGN-meetings-reminders.md` | 21 decisions with their rejected alternatives. Meetings are **built** |
| `BACKLOG.md` | Parked work, each with why it's parked and what unparks it |
| `PRODUCT.md` | Direction and the "why" behind product calls |
| `CHANGELOG.md` | One row per meaningful change |
| `eval/README.md` | What the router metrics mean, and the rules for changing the test set |
| `review/LEDGER.md` | What has been claimed, what has been independently checked, what is still open |
| `DESIGN-work-mode.md` | Work mode's eight decisions with their rejected alternatives |
| `DICTATION-HISTORY.md` | **Read first when dictation, the mic or the hotkey breaks.** Every past failure, its cause, and what was working just before |

If something looks wrong, check these first. Several apparent mistakes are
decisions with reasons written down.

**Append to `review/LEDGER.md` when you close a review finding.** It is
shared with whoever reviews next, and it carries one rule that is not
optional: you may mark your own work `claimed-fixed`, never `VERIFIED`.
Only a different reviewer promotes it, and only after running something.

## How to verify

Six layers, all cheap, none of them optional when touching what they cover.

**Router accuracy** — 72 cases against the live model. Gets the real prompt
and tool schema by asking the built binary, so there is no second copy to
drift:

```bash
xcodebuild -project Sayline.xcodeproj -scheme Sayline -configuration Debug build
python3 eval/run_eval.py --arm openai --dry-run          # no API calls
python3 eval/run_eval.py --arm openai --model gpt-4o-mini
```

**Build first.** The harness reads the newest binary in DerivedData; a stale
one measures the prompt you had yesterday.

It used to compile a hand-maintained list of source files instead, which
broke three times when `AgentRouter` gained a dependency nobody added —
twice unnoticed for a day, because a harness that cannot compile and a
harness nobody ran look identical. `Sayline --dump-config` ended that class.
Two source-compiled modes remain for pane resolution; they go away with the
`--parse-actions` migration in `BACKLOG.md`.

**Deterministic logic** — the half the router eval structurally cannot see,
because it scores what the model emits, not what we do afterwards.

Keep the `&&`. Running the binary as a separate command after a failed
`swiftc` executes a stale one from a previous build, which reports a
confident pass — that happened on 2026-08-11 and nearly shipped.

**Run them after changing any file they compile.** These lines rot: when a
source file gains a dependency, its command stops compiling and the suite
goes quiet rather than red. FactGuard needing `AppContext.swift` broke this
block on 2026-08-14 — the third instance of the same class. The eval's own
verifier binary rots the same way and for the same reason: after any guard
change, rebuild it before trusting a number, or it scores with the old
rules. That one produced a 39% that was really 29%.

```bash
swiftc -o /tmp/chk Sources/Sayline/WebsiteCatalog.swift eval/catalog-checks/main.swift && /tmp/chk
swiftc -o /tmp/chk Sources/Sayline/FollowUp.swift eval/consent-checks/main.swift && /tmp/chk
swiftc -o /tmp/chk Sources/Sayline/LocalTimestamp.swift eval/timestamp-checks/main.swift && /tmp/chk
swiftc -o /tmp/chk Sources/Sayline/AgentAction.swift Sources/Sayline/WebsiteCatalog.swift \
  Sources/Sayline/InstalledAppCatalog.swift Sources/Sayline/FastRoute.swift \
  Sources/Sayline/SaylineLog.swift eval/fastroute-checks/main.swift && /tmp/chk
swiftc -o /tmp/chk Sources/Sayline/Meeting.swift Sources/Sayline/MeetingLink.swift \
  eval/meeting-checks/main.swift && /tmp/chk
swiftc -o /tmp/chk Sources/Sayline/CalendarScope.swift eval/scope-checks/main.swift && /tmp/chk
swiftc -o /tmp/chk Sources/Sayline/FactGuard.swift Sources/Sayline/AppContext.swift \
  eval/factguard-checks/main.swift && /tmp/chk
```

The fast path answers some commands without calling the model at all, so
the router eval cannot see it — `fastroute-checks` is the only thing that
can. Its negative cases matter most: a false match there does not give a
wrong answer, it silently drops the rest of the sentence.

**Deterministic logic, cont.** `scope-checks` covers which calendar
accounts are readable; `meeting-checks` covers meeting parsing and link
detection. Both are pure and framework-free on purpose.

**Capture path** — the one part of the app that used to be untestable
without a human holding the hotkey, which is why six dictation
regressions shipped in a day. Mandatory after **any** `AudioRecorder`
change:

```bash
Sayline --selftest-capture 3 5
```

Five holds on one recorder. Asserts start latency < 150 ms, ~the whole
window on disk, and **peak amplitude** — a recording of the right length,
rate and size can still be pure silence, and was.

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

**While idle, Sayline holds nothing.** No input stream, no output stream,
no device claim, and no OS-level state — ducking, secure-input
workarounds — that outlives the gesture which justified it. Idle means no
hold in progress and no chime sounding; anything acquired for a gesture is
released within a second of its end. On 2026-08-13 the app quietened every
other app on the Mac by ~43x for as long as it ran, and the person it
happened to had no way to attribute it to us. Any effect on the system
must be scoped to a gesture, and the *absence* of leftovers has to be
asserted by a test, because a leftover is invisible to whoever caused it.

**Verify the contract, not the delta.** Check the invariant the feature
must always satisfy, not just the symptom you removed. Every dictation
regression on 2026-08-13 was visible in the log that shipped with its own
fix. See `DICTATION-HISTORY.md`.

**Assert on the payload, not the envelope.** Duration, byte count and
format are the envelope; a silent recording has all three correct. Look
inside.

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

- **The event tap is sometimes disabled by the system with
  `kCGEventTapDisabledByUserInput`, cause unknown** (2026-08-13). Distinct
  from the CoreAudio deadlock fixed the day before: the main thread was
  healthy throughout and the disable code differs. Our circuit breaker
  then re-entered itself and turned it into a 25,000-iteration freeze —
  that loop is fixed; the trigger is not. Full entry and a first-response
  checklist in `review/LEDGER.md` under "OPEN · Why macOS disabled the
  event tap".

- **The Mac freezes during use, cause unknown. Four incidents, three
  theories, all disproven** — event-tap starvation, an `NSPanel` leak (14
  created, 14 deallocated), and Secure Input contention. The fourth
  incident on 2026-08-11 took the user's keyboard until the app was killed,
  with the tap enabled and secure input off, which the third theory
  explicitly did not cover.
  Two things now exist that did not during those investigations: a circuit
  breaker that switches the tap off after four disables in two minutes
  rather than fighting for the keyboard, and `StallWatchdog`, which records
  whether the main thread was alive at the moment the tap was disabled —
  the single fact that separates "our callback is blocked" from "the system
  refused us". Next incident, read `~/Library/Logs/Sayline/sayline.log` for
  `MAIN THREAD STALLED` next to the disable lines.
- **The eval still scores the model's raw output, not the app's.** Pane
  correction, search-URL decomposition and due-date stripping all run after
  the model and the harness cannot see them. `Sayline --parse-actions`
  exists and works; wiring it in means rewriting 30 expectations one at a
  time, which is in `BACKLOG.md` with the reason it must not be automated.
- **~2s latency on every agent command** — the router round trip. Real, and
  currently unaddressed.
- **Two API keys were pasted in chat** and should be rotated.

## Style

The user is a PM with an EE background, learning to code hands-on. Keep
replies short and plain: small words, short paragraphs, jargon explained
inline. Still teach — they want to understand the why, not just get the
result.
