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
| backdrop blur | 4 |
| drop shadow | `#616161` at 25%, x 0, y 1, blur 4 |

What was drawn, and is now deliberately **not** used: speech boxes had fill
`#0F0F0F`, the 2–5 line boxes had stroke `#525252`, and blur was 8 on the
pill and the 1-line box and 12 on the rest. Blur 4 appears nowhere in the
file — it is the card's intent, chosen over every drawn value.

## The pill

| | value |
|---|---|
| radius | 8 (fixed — the radius rule below is speech-box only) |
| padding | **12 horizontal, 8 vertical** — overrides the Figma's 16 × 10 |
| gap | **8**, between loader and label — overrides the Figma's 6 |
| label | Inter Regular 16, `#f2f2f2` |
| loader | 15×15, see below |

Padding was settled on the rendered pill rather than in Figma: 16 × 10 was
the drawn value, 10 × 8 was tried and read as crammed, 12 × 8 is the
result.

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
