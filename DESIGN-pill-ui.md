# Pill + speech box — the settled spec

Source: Figma `g3HFEsLnpetmkjg7i1thBl`, nodes `13:431` (rules) and `15:948`
(pill). Settled with the user 2026-08-14.

**Read this rather than the Figma.** The rule cards and the drawn frames
disagreed in four places, and the resolutions below are decisions, not
transcription. Building from the file directly will reintroduce them.

## Fill, stroke and effect — pill and speech box, identical

The user's call: **the rule card wins**, and both surfaces share one set of
values. The drawn frames had drifted apart and neither matched the card.

| | value |
|---|---|
| fill | `#141414` at 75% |
| stroke | `#666666` at 25%, weight 1 |
| backdrop blur | see note — 4 per rule card, 8 per node 23:1234, neither settable in code |
| drop shadow | `#616161` at 25%, x 0, y 1, blur 4 |

What was drawn, and is now deliberately **not** used: speech boxes had fill
`#0F0F0F`, the 2–5 line boxes had stroke `#525252`, and blur was 8 on the
pill and the 1-line box and 12 on the rest. Blur 4 appears nowhere in the
file — it is the card's intent, chosen over every drawn value.

## The pill

| | value |
|---|---|
| radius | 8 (fixed — the radius rule below is speech-box only) |
| padding | **12 horizontal, 8 vertical** — settled on screen, overrides node 23:1234's 16 × 8 |
| gap | **8**, between loader and label — overrides the Figma's 6 |
| label | Inter Regular 16, `#f2f2f2` |
| loader | 15×15, see below |

Padding took a long detour and the final value is **not** in the Figma:
16 × 10 (first node), 10 × 8 (crammed), 12 × 8, 16 × 8 (node 23:1234),
14 × 10, 14 × 8, and back to **12 × 8**. Judged on the rendered pill each
time — the screen wins over the file.

### Backdrop blur is not implementable as specified

Figma's Effects panel shows **Background blur 16** on the pill. Figma
exports background blur at HALF its own value, which is why the CSS reads
`backdrop-filter: blur(8px)` and why the rule card's "4" was a Figma 4
(CSS 2) rather than a contradiction. Mystery solved, and irrelevant:
`BackdropBlur` is an `NSVisualEffectView` with `.hudWindow` / `.behindWindow`,
and AppKit chooses the blur radius per material — there is no radius to
set. Matching a specific pixel blur would mean replacing it with a
hand-rolled CIFilter backdrop, which is a real piece of work and has not
been asked for. Recorded so nobody goes looking for the setting.

### The pill is 168 × 35, not 175 × 37 — and that is the typeface

Measured with a GeometryReader on the built pill, against the node's
175 × 37. Every specified value matches, so the whole difference is font
metrics:

| | Figma (Inter Regular 16) | built (SF Pro 16) |
|---|---|---|
| "Agent Listening" width | 120 | 113 |
| content height | 21 | 19 |

Figma specifies Inter; the app uses `.system(size: 16)`, which is SF Pro —
as it did before this redesign. Keeping SF Pro is a deliberate default: it
is the macOS system font and this is a system-level overlay, so Inter would
read subtly foreign. Bundling Inter would match the Figma exactly and is a
one-line change plus a font file, if the exact match matters more.

## Speech box — radius by line count

Every line adds 4, capped at 5 lines.

| lines | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| radius | 10 | 14 | 18 | 22 | 22 |

Matches the drawn frames exactly; no discrepancy here.

## Speech box — padding by line count

**The rule card has the axes transposed.** It reads "Vertical 24, horizontal
16" for one line, but every drawn frame is the reverse, and 24 above and
below a single 16 px line would be far taller than the render. The user's
call: follow the geometry.

| lines | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| horizontal | 24 | 28 | 32 | 36 | 36 |
| vertical | 16 | 20 | 24 | 28 | 28 |

Text is Inter Medium 14. Spoken-but-superseded lines are `#999`; the live
last line is `#FDFDFD`.

## The loader

The Figma placeholder independently confirms the animation spec already
settled in [`design/waveform.html`](design/waveform.html): a 3×3 of **5 px**
squares butted edge to edge — 15 px total, no gap, no corner radius.

Its drawn state is centre `#FFFFFF`, edges `#CCCCCC`, corners `#4D4D4D`.
Against this ground that is roughly opacity 1.0 / 0.8 / 0.3, which is frame
10 of the model — the "plus". The placeholder and the animation agree
without either being derived from the other.

Motion, unchanged: 800 ms cycle, dip 90% of cycle, ring lag 15%, white,
8 px glow, dip shape `[1, .8, .5, .3, .1, .1, .3, .6, .9, 1]`.

Note the older speech-box variants in the file draw the loader at 4 px
cells (12 px total). 15 px is the settled size; 12 px is superseded.
