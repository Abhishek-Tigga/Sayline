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

## The loader: two motions, three colours

Settled with the user 2026-08-14 from `design/waveform-variants.html`.

| mode | motion | colour |
|---|---|---|
| plain dictation | ring spin | `#F9F0E0` warm off-white |
| work | ring spin | `#90CAF9` cool blue |
| agent | outward dip | `#FFFFFF` |

**Ring spin** is a highlight travelling clockwise around the eight outer
cells with the centre held at 0.55. Pulse width 1, which the spin narrows
to 0.7 internally — a full-width pulse across eight cells lights the whole
ring at once and the travel disappears. Cells floor at 0.12 so the grid
stays legible as a grid.

The split is deliberate: agent mode is *doing* something and gets the
outward dip, which reads as thinking; dictation and work are *waiting* and
get the spin. Motion separates agent from the rest, hue separates
dictation from work. That matters more than it used to, because the pill's
text no longer breathes and the border beam is the only other mode signal.

### Keep `design/waveform-variants.html`

It renders nine motions side by side, each inside a pill at shipping size,
all animating off one clock — outward dip, upward sweep, upward fill,
column sweep, ring spin, breathe, diagonal sweep and its reverse, and
twinkle. Controls for cycle, size, gap, glow, dim floor and pulse width,
plus a hex field.

It is the library for the next one of these, not a throwaway: there are
more states coming that will each want their own motion, and the value is
in comparing them animating together rather than imagining them one at a
time.

## The work-mode announcement

Entering work mode shows **Work Mode**, then hands back to **Listening**.
Chosen from `design/pill-transitions.html`, which offers six treatments.

| | |
|---|---|
| transition | blur and fade, **both directions** |
| in | 0.45 s |
| hold | 0.5 s |
| out | 0.45 s |
| peak blur | 3 pt on whichever label is arriving or leaving |
| width | hugs — grows into the announcement, shrinks back |

Implemented as a single `announcementPresence` value from 0 to 1: it
rises, holds, and falls. Opacity, blur and width are all read off it, so
the two transitions cannot drift apart — they are one curve, the second
half played in reverse. Verified symmetric.

The width is measured with the real font rather than left to the layout
system. A ZStack sizes itself to its widest child, so the pill would have
sat at the announcement's width for the whole hold and never shrunk,
which is the behaviour this replaces.

Work mode settles on "Listening", the same label as plain dictation. The
mode is announced once and then carried by the loader's blue, rather than
spelled out for the entire hold.

## The speech box — superseded rules (node 34:1377)

These replace the earlier 10/14/18/22 radius and 24/28/32/36 padding.
Stated by the user as arithmetic on 2026-08-14 and confirmed by the first
three frames.

| lines | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| radius | 8 | 10 | 12 | 14 | 16 |
| horizontal padding | 16 | 18 | 20 | 22 | 24 |
| vertical padding | 12 | 14 | 16 | 18 | 20 |

Radius starts at 8 and adds 2 per line; padding starts at 16 × 12 and adds
2 per line. **Five lines maximum** — past that the box stops growing and
the text is trimmed from the front, keeping the tail.

Gap between the speech box and the pill: **8**.

The box **hugs its text**, up to a maximum width of **288** including
padding. Short transcripts get a narrow box; long ones saturate at 288 and
wrap. This is an explicit measured width rather than `.frame(maxWidth:)`,
which expands to whatever the parent offers — and the indicator hands down
the full screen width, so a cap alone became the size.

### Where the file disagrees, and why the rule won

Lines 1 to 3 match node 34:1377 exactly. Lines 4 and 5 do not:

| | rule | drawn |
|---|---|---|
| 4-line radius | 14 | 16 |
| 5-line radius | 16 | 20 |
| 5-line vertical padding | 20 | 18 |

Two frames breaking an arithmetic the other three keep reads as frames
that were not updated, and the arithmetic was stated explicitly and most
recently. The rule wins. If the frames are right and the rule is wrong,
this is the paragraph to come back to.

### Not changed, and worth knowing

- The **fill, stroke and blur** stay on the shared surface (`#141414` at
  75%, `#666666` stroke). Node 34:1377 still draws the old drift —
  `#0F0F0F` with a `#525252` stroke and blur 12 — which was resolved
  earlier in favour of one treatment for both surfaces.
- The **pill's own dimensions in this file are not authoritative**, per
  the user. It draws 10 × 8 padding; the pill ships 12 × 8.
- The speech box renders at **12pt**, while the file specifies 14pt Inter
  Medium. Not raised, so not changed — but font size decides how many
  lines a transcript takes, and line count now decides radius and padding,
  so this feeds directly into the rules above.
