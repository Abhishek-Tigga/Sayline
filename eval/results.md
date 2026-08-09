# Router eval results

One row per run, appended by `run_eval.py`. See [README.md](README.md) for
what the metrics mean and the rules for changing the test set. Notes come
first so appended rows always land at the bottom of the table.

## Notes

**Runs where more than a fifth of cases never reached the model are not
recorded.** They measure the harness or the account's rate limits, not the
arm. Two such runs happened before the guard was strict enough: a
`gpt-5-nano` run on 2026-08-08 where a truncated API key failed all 30, and
a `groq-tools` run on 2026-08-09 where the daily token cap failed 27 of 30
and produced a meaningless 2/30 that looked like a catastrophic baseline.
Both rows have been removed.

**`+suffix` on a commit** marks a run made against uncommitted working-tree
changes. The harness reads source files, not the committed tree, so a bare
SHA would describe code that never existed in that commit. `run_eval.py`
now appends `+dirty` automatically.

**Two reverted attempts at `settings-general`.** Rewording the prompt changed
nothing. Adding alias keys to the pane vocabulary also changed nothing on the
target case *and* regressed `gpt-5.6-luna` 27 → 26 by giving models a
generic-sounding bucket — both "banana settings" and "doc settings" started
resolving to About. Both reverted. The fix that worked was deterministic
(`AgentRouter.correctedSettingsPane`), not prompt-based.

**Run-to-run variance is real.** `gpt-4o-mini` failed
`settings-screen-time-implicit` with `Uptime` on one run and `NowPlaying` on
another, same input. A one-case difference is inside the noise — re-run two
or three times before believing a small delta.

**Groq's daily cap is not visible in response headers.** `x-ratelimit-*`
reports tokens per *minute* only. A small probe call succeeding proves
nothing about the daily budget; the only reliable signal is a full-size call
returning 200. Getting this wrong on 2026-08-09 wasted an entire baseline
attempt.

## Runs

| When | Commit | Arm | Model | Accuracy | Syntax failures | Median tokens | Median latency |
|---|---|---|---|---|---|---|---|
| 2026-08-08 21:17 UTC | `a2ef4fc` | openai | `gpt-5-nano` | 26/30 (87%) | 0 (0%) | 1602 | 2952 ms |
| 2026-08-08 21:26 UTC | `4e6edb4` | openai | `gpt-5-mini` | 27/30 (90%) | 0 (0%) | 1602 | 2644 ms |
| 2026-08-08 21:27 UTC | `4e6edb4` | openai | `gpt-5.6-luna` | 27/30 (90%) | 0 (0%) | 1602 | 1251 ms |
| 2026-08-08 21:28 UTC | `4e6edb4` | openai | `gpt-4o-mini` | 27/30 (90%) | 0 (0%) | 1518 | 966 ms |
| 2026-08-08 21:31 UTC | `4e6edb4` | openai | `gpt-5` | 27/30 (90%) | 0 (0%) | 1602 | 3352 ms |
| 2026-08-08 21:35 UTC | `dc8b1af`+prompt-edit | openai | `gpt-4o-mini` | 27/30 (90%) | 0 (0%) | 1555 | 922 ms |
| 2026-08-08 21:36 UTC | `dc8b1af`+prompt-edit | openai | `gpt-5.6-luna` | 27/30 (90%) | 0 (0%) | 1639 | 1241 ms |
| 2026-08-08 21:38 UTC | `dc8b1af`+vocab-edit | openai | `gpt-4o-mini` | 27/30 (90%) | 0 (0%) | 1579 | 979 ms |
| 2026-08-08 21:39 UTC | `dc8b1af`+vocab-edit | openai | `gpt-5.6-luna` | 26/30 (87%) | 0 (0%) | 1663 | 1228 ms |
| 2026-08-08 21:57 UTC | `434f8c6`+pane-correction | openai | `gpt-4o-mini` | 28/30 (93%) | 0 (0%) | 1518 | 999 ms |
| 2026-08-09 14:38 UTC | `3bab25b` | openai | `gpt-4o-mini` | 32/38 (84%) | 0 (0%) | 1963 | 1020 ms |
| 2026-08-09 14:41 UTC | `3bab25b+dirty` | openai | `gpt-4o-mini` | 36/38 (95%) | 0 (0%) | 2064 | 1069 ms |
