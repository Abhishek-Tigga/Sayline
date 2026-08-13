# Fable — Sayline is quietening the user's whole system

Open `/Users/abhishektigga/Documents/Dictation/Sayline`.

**Severity: highest so far.** Every previous failure broke *our* app. This
one changes how the user's Mac behaves outside it. They said it plainly and
they are right: *"We should not modify the user's system in order to fit
our purpose."*

I am escalating rather than guessing because my last theory here was wrong
within ten minutes, and my record on this subsystem today is six fixes,
each correct about its own layer and wrong about the one beneath.

## The report

All system audio plays quietly. Music at maximum volume sounds like
minimum. It resolves when Sayline is killed. The user asked directly
whether we turn their volume down while Sayline is active.

## What is established

**We do not change the volume setting.** The only code touching system
volume is the `setVolume` action in `AgentExecutor`, reachable solely from
an explicit "louder"/"mute" command. `output volume of (get volume
settings)` reads **100** while the problem is happening.

**Sayline holds an audio output stream open for its entire lifetime**,
even while idle:

```
while Sayline runs, in silence : outputting now -> Sayline
after pkill -x Sayline         : outputting now -> NONE
```

**The holder is `SoundEffectPlayer`.** It starts an `AVAudioEngine` in
`init()` for the hotkey chime and never stops it — there is no
`engine.stop()` in the file. This predates voice processing; the same
"outputting -> Sayline" appears in probes from 2026-08-12.

**Voice processing alone does not do it.** Measured in isolation today:

```
baseline, nothing done    : holding output = false
after enabling VP (idle)  : holding output = false
while recording           : holding output = true
after engine.stop, VP on  : holding output = false
after disabling VP        : holding output = false
```

So my first theory — that the steady-state voice-processing unit ducks the
system — is **disproved** for VP on its own. What is untested is the
combination actually shipping: a permanently-running output engine in the
same process as a voice-processing input unit.

## What I cannot determine

Whether either of those, or their combination, is what the user hears.
Ducking is perceptual; I can measure which process holds a stream, not how
loud anything sounds. I would be guessing, and guessing is what put us
here.

## What I want from you

1. **The mechanism.** Is a permanently-running output `AVAudioEngine`, or
   its combination with a voice-processing input unit, enough to make
   macOS apply call-style ducking to other applications? If not, what else
   in this codebase could?
2. **A way to measure it** that does not depend on the user's ears, so the
   fix can be proven rather than believed.
3. **The fix**, ranked. My candidate is to start the sound engine on demand
   and stop it after each chime, so nothing is held while idle — but it is
   a candidate, and "obviously correct" is what I said about the last six.
4. **Whether voice processing should now go.** It is 5-for-5 in causing
   failures: engine would not start (-10875), device binding broke
   (-10851), 1.1s per-hold latency, silent recordings (`channelMap` of
   `[-1]`), and it is the untested half of this one. What it buys is
   speaker bleed no longer polluting transcripts, measured at a 97%
   reduction. What it costs keeps growing.
5. **A rule for this class**, for `CLAUDE.md`: what a menu-bar app is
   allowed to hold open while idle, and how we detect a violation before a
   user does.

## Also open, unfixed, not investigated

"Next song" does not work. Play and pause do. The browser path posts
`NX_KEYTYPE_NEXT` and was never verified to work on a browser tab — only
play/pause was, and only partially. Deliberately not touched: the user
asked me to stop fixing blindly.

## Context you should have

- `DICTATION-HISTORY.md` — every failure on this path today, with causes,
  and the lessons section at the top
- `review/LEDGER.md` — the claim/verify record; append there, and you may
  mark your own work `claimed-fixed`, never `VERIFIED`
- `Sayline --selftest-capture 3 5` — headless capture check across five
  holds; asserts start latency, duration on disk and **peak amplitude**.
  It passed while the app recorded pure silence, because it originally
  asserted only duration and file size
- Rebuilds cost the user their Accessibility and Microphone grants, so
  experiments are expensive to them
