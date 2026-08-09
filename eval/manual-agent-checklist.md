# Manual agent test checklist

For the things a script can't check — whether a browser tab actually
opened, whether audio actually started. The router's *decisions* are
covered by `router-test-set.json`; this covers the end that only a human
can see.

All of these are **agent mode**: hold the hotkey **+ Space**, speak,
release.

Pace them a few seconds apart. Say each one plainly — no need to
over-enunciate, the mishearings are useful data.

---

## A. Opening sites

| # | Say | Expect |
|---|---|---|
| A1 | open youtube | youtube.com |
| A2 | open gmail | mail.google.com |
| A3 | open figma | figma.com |
| A4 | open toolfolio.com | toolfolio.com — spelled-out domain |
| A5 | open notion | notion.so |

## B. Searching a site

| # | Say | Expect |
|---|---|---|
| B1 | search lo-fi music on youtube | YouTube **results list**, not a video |
| B2 | look up Satya Nadella on LinkedIn | LinkedIn people results |
| B3 | google swift concurrency | Google results |
| B4 | search noise cancelling headphones on amazon | Amazon results |
| B5 | search swift on github | GitHub code results |

## C. Playing on YouTube (uses API quota, 100/day)

| # | Say | Expect |
|---|---|---|
| C1 | play a Kendrick Lamar song on youtube | A **video page, playing** — not a list |
| C2 | play lo-fi study music on youtube | Video, playing |
| C3 | play bohemian rhapsody on youtube | The Queen video, playing |

The difference between B1 and C2 is the whole point — same site, same
kind of query, different verb, different result.

## D. Apple Music control

Have Music.app open with something queued first.

| # | Say | Expect |
|---|---|---|
| D1 | play music | Audio **actually starts** |
| D2 | pause | Audio stops |
| D3 | next track | Skips forward |
| D4 | play a Kendrick Lamar song on apple music | Apple Music **search page** — known limit, can't autoplay the catalogue |

## E. Refusals — these are meant to fail

| # | Say | Expect |
|---|---|---|
| E1 | open toolfolio | Refuses: *"Say the full address, like toolfolio.com"* |
| E2 | open blahblahsite | Same refusal |
| E3 | (hold the key, say nothing, release) | *"Didn't catch that"* — no junk pasted |

E3 is the hallucination filter. Before it existed this pasted "." or
"Thank you." into whatever was focused.

## F. Regression — these worked before, they must still work

| # | Say | Expect |
|---|---|---|
| F1 | open safari | Safari opens |
| F2 | close safari | Safari quits |
| F3 | close whatsapp | WhatsApp quits (the invisible-character fix) |
| F4 | open keyboard settings | Keyboard pane |
| F5 | what's my battery | Battery percentage on the pill |
| F6 | open safari then tell me my battery | **Both** happen, in order |

## G. Say a real "thank you"

| # | Say | Expect |
|---|---|---|
| G1 | (normal volume) "Thank you" — as **dictation**, not agent mode | Pastes "Thank you." |

Guards the filter from eating genuine speech. If this gets swallowed the
loudness threshold is wrong.

---

## What to report back

For anything that fails, the log line matters more than the symptom —
it says whether the model chose wrong, or chose right and execution
failed. Those need completely different fixes.
