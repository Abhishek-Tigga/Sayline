# Media control and web fixes — design for review

Written 2026-08-12 after a live test session surfaced five failures. Four
of them are one bug wearing four hats.

## What failed

| Said | Happened | Real cause |
|---|---|---|
| "play music" | Opened YouTube, played nothing | Request is incomplete; we guessed instead of asking |
| "play lo-fi music on YouTube" | Worked | — |
| "stop the music on YouTube" | Opened another YouTube tab | **No concept of acting on what is already running** |
| "Open Gmail" | Nothing useful | Unknown — we do not log what the app decided |
| "when is my next meeting" | "No meetings" | True, but indistinguishable from "I can't see your calendar" |

## The shape of the problem

Every web action Sayline has is one-way: hear words, build a URL, open it.
That is the entire vocabulary. "Stop" is not a URL, so the router did the
only thing the design allows and opened YouTube again.

The missing category is **acting on state that already exists**. Stop,
pause, skip, previous, louder, quieter, mute, close that tab. None of them
name a destination. All of them assume something is already happening.

This is not a bug in the web catalog. It is a category the architecture has
no room for, which is why no amount of prompt work would have fixed it.

## Settled by the user

1. **Scope: anywhere.** Control whatever is playing — Spotify, Music, a
   browser tab — not browsers only.
2. **Nothing playing → say so.** Do not silently no-op.
3. **"Play music" with no target → ask.** Offer the shape of an answer: an
   artist, a song, or a genre (English, Bollywood, Afro). Resolve their
   reply into a real search. Playing from their own playlists waits for the
   Google integration.
4. **Controls are comprehensive**, not just play/pause: next, previous,
   volume, mute, close the tab.
5. **App-vs-website: resolve to the website in all cases, for now.**
6. **Action logging always on** for the rest of this session, removed before
   release.

## Measured platform facts

Probed directly on macOS 26.3 rather than assumed. All four probes are in
the scratchpad; the results are what the design has to live with.

**Media keys work.** Posting `NX_KEYTYPE_PLAY` as a system-defined CGEvent
resumed a paused Chrome/YouTube tab from silence. No new permission — it
rides the Accessibility grant we already hold for the hotkey.

**Media keys did not reliably pause it again.** Three subsequent presses
left the tab producing audio. Play worked, pause did not, same key, same
code path. Unexplained, and it is the single biggest risk in this design —
see open questions.

**Per-process audio detection works, with public API.**
`kAudioHardwarePropertyProcessObjectList` plus `kAudioProcessPropertyIsRunningOutput`
(macOS 14.2+) cleanly caught a process starting and stopping playback, and
names the app. This is how we answer decision 2.

**But it over-reports.** It means "holds the output stream open", not "is
audible". Sayline itself shows as outputting during silence because of the
mic engine, and Chrome stays listed with a paused tab. Reliable for apps
that release the device, optimistic for browsers.

**The private API that would give an exact answer is dead.**
`MRMediaRemoteGetNowPlayingApplicationIsPlaying` loads and its callback
fires, but returns `false` with empty info even while audio plays. Apple
gated it behind an entitlement. Correct outcome anyway — private API in a
commercial app is a future breakage we would own.

**Device-level CoreAudio is useless here.**
`kAudioDevicePropertyDeviceIsRunningSomewhere` reported `true` in every
state, because we are always one of the processes holding the device.

## Proposed design

### A new action family, separate from web

`AgentAction` gains media control cases that carry no destination:
`mediaPlayPause`, `mediaStop`, `mediaNext`, `mediaPrevious`, `mediaMute`,
`closeCurrentTab`. Volume already exists as `setVolume` and should be
reused, not duplicated.

These are deliberately **not** web actions. "Stop the music" must behave
identically whether the sound is coming from Spotify, Music, or a tab, and
routing it through the website catalog is what produced the bug.

### Knowing what is playing

`NowPlaying.whatIsAudible()` returns the app names currently outputting,
always excluding our own PID. Three outcomes:

- **Nothing, and no known media app running** → "Nothing is playing." High
  confidence; nothing was even a candidate.
- **Nothing detected, but a browser is open** → the honest gap. Send the
  key and report what we did, not what we know: "Sent pause to Chrome."
- **Something detected** → name it. "Paused Spotify" is a better answer
  than "Paused", and we get the name for free.

### "Play music" with no target

Uses the follow-up primitive already built. Non-destructive, so a timeout
means cancelled, not confirmed. Question: *"What would you like to hear —
an artist, a song, or a genre?"* Their reply becomes the YouTube search.

### Gmail and the app-vs-website rule

Decision 5 is implemented as asked: a site in the catalog resolves to its
URL, and `openApp` is not attempted for it.

**I want this flagged, not quietly shipped.** Applied literally, "open
Spotify" opens the web player rather than the Spotify app you have
installed, and the same goes for Slack, WhatsApp and Notion. That is worse
than today for those four. The rule is right for Gmail — there is no Gmail
app — but "in all cases" may be broader than intended. Fable should weigh
whether "prefer the app only when it is actually installed, website
otherwise" delivers the same fix without that cost.

### Logging

One line per turn recording the resolved action and its arguments, which
does not exist today. Every web failure above was undiagnosable because the
log records what the user said and not what the app chose. Behind a flag
that defaults on for now, off before release.

### Calendar: empty is not the same as blind

`whatsNextMeeting` currently answers "no meetings" for both "your calendar
is empty" and "I cannot see any calendar". The measured evidence is that
the user's Google account *is* connected and the answer was literally
correct — and still useless, because there was no way to tell.

Three distinct answers, never one:

- **No calendar access** → say that, and offer the setup card.
- **Access, zero accounts** → say that, and offer the setup card.
- **Access, accounts, no events in window** → "Nothing in the next N hours",
  which is now trustworthy because the other two cases cannot reach here.

Also: account counting currently runs at launch, before Calendar permission
exists, so a first run always computes zero. It must run after the grant,
not before.

The setup card should stop being gated on *dismissal* and start being gated
on *connection*. Someone who dismisses it while still having nothing
connected will hit the same wall tomorrow with no way back.

## Open questions for review

1. **Why did play work and pause not?** This is the load-bearing unknown.
   If media keys cannot reliably pause a background browser tab, decision 1
   ("anywhere") may not be deliverable through this mechanism, and the
   fallback — AppleScript per browser, plus Automation permission most
   people will decline — is materially worse. Is there a mechanism neither
   of us has considered?
2. **What else is in this category?** The point of reviewing before coding.
   "Stop the music" was invisible until a user hit it. What other commands
   assume existing state and have no destination — and would embarrass us
   the same way? Scroll down, go back, close this window, turn it up,
   read that again, undo that.
3. **Is the over-reporting detector honest enough to ship?** Naming an app
   we are not certain is audible risks "Paused Chrome" when Chrome was
   silent. Better to name it and occasionally be wrong, or stay vague and
   always be safe?
4. **Decision 5's cost** — see the Gmail section.
5. **Close-the-tab** is the one control here that is destructive and
   irreversible in the way that matters (an unsaved form, a half-written
   message). Should it confirm first, given `FollowUp` already refuses to
   let a destructive question confirm on timeout?
