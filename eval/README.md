# Router eval

A frozen set of inputs and expected outputs for the agent router, plus
(soon) a harness that runs it and scores the result. It exists because
every debugging round before this was anecdotal — try a phrase, read a
log, guess — which is why the same bug kept resurfacing wearing
different clothes. Nothing was ever measured twice the same way.

## Files

- `router-test-set.json` — 30 cases. Written **before** any candidate
  implementation existed, so no arm can be quietly tuned to pass it.
- `results.md` — appended after every run: date, commit SHA, which arm,
  and the four numbers. Not created until the first run.

## What a case looks like

```json
{
  "id": "settings-dock-asr-noise",
  "transcript": "Open doc settings",
  "source": "live-log",
  "expect": [{ "action": "openSystemSetting", "args": { "pane": "Desktop & Dock" } }],
  "guards": "Whisper heard 'doc' for 'dock' …"
}
```

`transcript` is fed to the router exactly as written. Twelve of the 30
are `live-log` — verbatim Whisper output from real use on 2026-08-09,
mishearings included, because that is the real input distribution.
The other 18 are `constructed` to cover actions never exercised live.

`guards` says what the case is *for*. When a case starts failing, that
line should explain why anyone cared — the thing normally lost when the
person who wrote the test moves on.

## Scoring

Mechanical. An arm passes a case when the produced action list matches
`expect` on action name and on every argument listed; unlisted arguments
are ignored. **Never** score by judging whether output looks reasonable
— that reintroduces exactly the ad-hoc testing this replaces.

Four metrics per run:

| Metric | Source |
|---|---|
| Syntax failure rate | count of `tool_use_failed` / unparseable responses |
| Action accuracy | cases passed ÷ total |
| Tokens per call | `usage.prompt_tokens`, measured not estimated |
| Latency | wall clock per call |

## Changing the test set

Expected values encode product decisions, and some are genuinely
debatable — `settings-general` expects `About` because macOS has no
General pane. If a decision changes, **edit the expectation first, then
re-run.** Changing an expectation to match output you already saw is how
a test suite quietly stops testing anything.

Adding cases is good. Removing a failing case to make a run look better
is not.

## Budget

Roughly 2,000 tokens per case, so a full 30-case run against a Groq arm
costs ~60,000 tokens against a 100,000/day free-tier cap. Two Groq arms
do not fit in one day. See `../BACKLOG.md` for the three-arm plan.
