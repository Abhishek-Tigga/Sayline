# Fable — two problems: a key that will not save, and a design we cannot match

Open `/Users/abhishektigga/Documents/Dictation/Sayline`, branch
`ui-pill-redesign`.

Two unrelated challenges. The first is blocking all dictation right now.

---

## 1 · The Groq key will not persist, and the app hid it

**Symptom.** Dictation is dead: every hold records fine and dies at the
API call with "No Groq API key set". The user has entered the key in
Settings at least twice today and believed it saved both times.

**What is actually in the keychain**, service `com.abhishektigga.sayline`:

```
OPENAI_API_KEY    present
YOUTUBE_API_KEY   present
GROQ_API_KEY      absent
```

So keychain access works in general. Two sibling items written by the same
code, in the same service, have survived a dozen rebuilds today. Only this
one write goes nowhere.

**Two defects found, one fixed, and neither is the root cause.**

*Fixed (`63e5457`).* `KeychainStore.save` discarded `SecItemAdd`'s
OSStatus entirely. A failed write was indistinguishable from a successful
one, so Settings accepted the key and said nothing. It now checks the
status, and defines success as reading the value back rather than as
`SecItemAdd` returning 0. This does not fix the save — it makes the next
attempt state a reason.

*Fixed (`4163267`).* On a `-25293` read, `load` used to DELETE the entry,
logging "belongs to an older build". That was written for the ad-hoc
signing era, where every rebuild genuinely orphaned the item. Signing has
been stable since `c15915c`, so it had become a destructive no-benefit
path — and it fired at 02:55 today and destroyed a key that had been
working at 02:26. It now reports and leaves the item alone.

**What we want from you.** Why does this one item fail to write when its
two siblings do not? Candidates we have not been able to separate:

- An ACL or partition-list difference on the pre-existing `GROQ_API_KEY`
  entry versus the other two, given this key has been deleted and rewritten
  far more times than the others.
- `SecItemDelete` succeeding while the item remains visible to
  `SecItemAdd`, giving `errSecDuplicateItem`.
- Something in the Settings UI path not calling `save` at all — we have
  NOT verified that the text field commits before the sheet closes, and
  that is an obvious suspect we are flagging rather than assuming.

Please also say whether `save`'s delete-then-add is the right shape at all,
or whether `SecItemUpdate` with an add-on-not-found fallback is the safer
pattern. Files: `Sources/Sayline/KeychainStore.swift`, and whatever calls
it in `SettingsWindowController.swift`.

**Ask the user for the log line before theorising.** The next save attempt
now prints either `KEYCHAIN SAVE FAILED ... OSStatus <n>` or
`KEYCHAIN SAVE UNVERIFIABLE`. That number is the diagnosis and nobody has
it yet.

---

## 2 · The pill does not match the Figma, and we have run out of levers

Read `DESIGN-pill-ui.md` first — it records every value and every place the
Figma and the build disagree. Figma file `g3HFEsLnpetmkjg7i1thBl`, pill at
node `23:1234`.

**The user's words:** the background blur is too strong, and *"the opacity
at 75% with the same colour that I see in Figma is not reflecting here as
per the design"*.

That second sentence is the interesting one. Same hex, same stated opacity,
different result on screen — so something in the compositing differs, not
the numbers.

**Where we got stuck.**

Figma asks for `background blur 16` (which it exports as
`backdrop-filter: blur(8px)` — Figma writes CSS at half its own value).
macOS has no equivalent. `NSVisualEffectView` is the only real backdrop
blur available and it takes a **material**, not a radius: Apple picks the
blur per material and there is nothing to set. We compared six materials
side by side and shipped `.underWindowBackground` because it was the
darkest and let least desktop colour through — but that is choosing a tint,
not matching a blur.

The fill is `#141414` at 75% over that material, exactly as specified, and
it does not look like the Figma.

**Our hypothesis, which we would like you to confirm or kill.** Figma
composites a 75% fill over a *blurred copy of the backdrop only*.
`NSVisualEffectView` is not a neutral blur — each material carries its own
vibrancy, tint and a light/dark adaptation — so we are compositing 75% over
"blurred backdrop **plus Apple's material treatment**". If that is right,
no combination of fill opacity and material can match the Figma, and the
question becomes what the closest honest approximation is.

**Specific questions:**

1. Is there any way to get a plain, untinted, fixed-radius backdrop blur on
   macOS without Screen Recording permission? We believe not, and would
   like to be wrong.
2. If not — what is the best approximation? Candidates we can see: a
   different material; a solid or near-solid fill that abandons the blur
   entirely; or a hand-rolled `CIGaussianBlur` backdrop, which needs Screen
   Recording and which we have already argued against for a dictation app.
3. Is the user seeing a *colour* problem rather than a blur one? macOS
   colours are colour-managed and Figma's `#141414` is sRGB; SwiftUI's
   `Color(red:green:blue:)` is not sRGB by default on macOS. **We have not
   checked this** and it could explain "same colour, looks different"
   entirely, independently of the blur.

Question 3 is the one we would look at first if we had more time.

**Do not propose Liquid Glass.** `SurfaceStyle.liquidGlass` is parked by an
explicit user decision (2026-08-07) after a long list of failed attempts to
suppress its backdrop adaptivity; the reasoning is at the top of
`RecordingIndicatorView.swift`.

---

## Ground rules

Unchanged. Nobody marks their own work verified. If a claim here is not
supported by the code, say so and quote both. The state of this branch:
12 commits, the pill is wired into the live indicator, and the standalone
preview is still present behind `--preview-pill` — it renders the real
`RecordingIndicatorView`, plus a fill-opacity comparison, and is
scaffolding to be deleted before release.

Write your review into `review/LEDGER.md` in the existing style.
