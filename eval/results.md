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

**The prompt now contains the current time, so no two runs share an input.**
Added 2026-08-10 so the model can resolve "tomorrow at 3". It also means
temperature 0 can no longer produce identical runs even in principle — the
system prompt differs on every call. Runs at `ab09a17` scored 54 then 55
out of 57 with no code change; the case that moved was `reminder-no-time`,
where the model invented a due date it usually omits. Treat a one-case move
as noise. This is a better explanation than the network one below, which is
also true but smaller.

**Temperature 0 makes the model deterministic, not the run.** Setting
temperature to 0 did stop the router wandering, and identical results
across repeat runs is now the normal case. It is not a guarantee: four
runs at `f0cb0a3` scored 55, 55, 53, 55 out of 57 with no code change
between them. The variance is `page_is_real`, which makes live HEAD
requests — a slow or refused response scores a case differently. An
earlier note here claiming runs are "identical" overstated it. Treat a
one-or-two case move as noise unless it repeats; the token count, which
touches no network, is the stable signal.

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
| 2026-08-09 15:06 UTC | `4ebf9d9+dirty` | openai | `gpt-4o-mini` | 43/47 (91%) | 0 (0%) | 2237 | 1137 ms |
| 2026-08-09 15:09 UTC | `4ebf9d9+dirty` | openai | `gpt-4o-mini` | 43/47 (91%) | 0 (0%) | 2237 | 1096 ms |
| 2026-08-09 15:11 UTC | `4ebf9d9+dirty` | openai | `gpt-4o-mini` | 44/47 (94%) | 0 (0%) | 2237 | 1191 ms |
| 2026-08-10 09:15 UTC | `2f108e5+dirty` | openai | `gpt-4o-mini` | 44/47 (94%) | 0 (0%) | 2237 | 1313 ms |
| 2026-08-10 09:17 UTC | `2f108e5+dirty` | openai | `gpt-4o-mini` | 45/47 (96%) | 0 (0%) | 2237 | 1326 ms |
| 2026-08-10 09:19 UTC | `2f108e5+dirty` | openai | `gpt-4o-mini` | 45/47 (96%) | 0 (0%) | 2237 | 1241 ms |
| 2026-08-10 09:49 UTC | `106b4b5+dirty` | openai | `gpt-4o-mini` | 48/51 (94%) | 0 (0%) | 2237 | 1400 ms |
| 2026-08-10 09:53 UTC | `106b4b5+dirty` | openai | `gpt-4o-mini` | 49/51 (96%) | 0 (0%) | 2237 | 1248 ms |
| 2026-08-10 19:16 UTC | `d2ad9d6+dirty` | openai | `gpt-4o-mini` | 50/57 (88%) | 0 (0%) | 2420 | 1338 ms |
| 2026-08-10 19:18 UTC | `d2ad9d6+dirty` | openai | `gpt-4o-mini` | 55/57 (96%) | 0 (0%) | 2444 | 1256 ms |
| 2026-08-10 19:20 UTC | `d2ad9d6+dirty` | openai | `gpt-4o-mini` | 55/57 (96%) | 0 (0%) | 2353 | 1421 ms |
| 2026-08-10 19:22 UTC | `d2ad9d6+dirty` | openai | `gpt-4o-mini` | 55/57 (96%) | 0 (0%) | 2353 | 1220 ms |
| 2026-08-10 19:24 UTC | `d2ad9d6+dirty` | openai | `gpt-4o-mini` | 53/57 (93%) | 0 (0%) | 2353 | 1257 ms |
| 2026-08-10 19:26 UTC | `d2ad9d6+dirty` | openai | `gpt-4o-mini` | 55/57 (96%) | 0 (0%) | 2353 | 1352 ms |
| 2026-08-10 21:35 UTC | `ab09a17+dirty` | openai | `gpt-4o-mini` | 54/57 (95%) | 0 (0%) | 2345 | 1290 ms |
| 2026-08-10 21:37 UTC | `ab09a17+dirty` | openai | `gpt-4o-mini` | 55/57 (96%) | 0 (0%) | 2345 | 1208 ms |
| 2026-08-10 21:49 UTC | `13d806a+dirty` | openai | `gpt-4o-mini` | 55/57 (96%) | 0 (0%) | 2345 | 1063 ms |
| 2026-08-10 21:51 UTC | `13d806a+dirty` | openai | `gpt-4o-mini` | 56/57 (98%) | 0 (0%) | 2345 | 1099 ms |
| 2026-08-10 22:43 UTC | `7863d93+dirty` | openai | `gpt-4o-mini` | 57/59 (97%) | 0 (0%) | 2345 | 1168 ms |
| 2026-08-10 23:10 UTC | `9dc8ae1+dirty` | openai | `gpt-4o-mini` | 56/60 (93%) | 0 (0%) | 2391 | 1151 ms |
| 2026-08-10 23:12 UTC | `9dc8ae1+dirty` | openai | `gpt-4o-mini` | 57/60 (95%) | 0 (0%) | 2432 | 1004 ms |
| 2026-08-10 23:14 UTC | `9dc8ae1+dirty` | openai | `gpt-4o-mini` | 57/60 (95%) | 0 (0%) | 2432 | 1004 ms |
| 2026-08-10 23:17 UTC | `9dc8ae1+dirty` | openai | `gpt-4o-mini` | 58/59 (98%) | 0 (0%) | 2432 | 1298 ms |
| 2026-08-10 23:28 UTC | `c24e7ad+dirty` | openai | `gpt-4o-mini` | 57/59 (97%) | 0 (0%) | 2432 | 1067 ms |
| 2026-08-10 23:38 UTC | `2aea5a4+dirty` | openai | `gpt-4o-mini` | 57/59 (97%) | 0 (0%) | 2432 | 1118 ms |
| 2026-08-10 23:48 UTC | `34d8a20+dirty` | openai | `gpt-4o-mini` | 58/61 (95%) | 0 (0%) | 2446 | 1147 ms |
| 2026-08-10 23:52 UTC | `34d8a20+dirty` | openai | `gpt-4o-mini` | 59/61 (97%) | 0 (0%) | 2446 | 998 ms |
| 2026-08-11 00:20 UTC | `8f0f60c+dirty` | openai | `gpt-4o-mini` | 57/61 (93%) | 0 (0%) | 2277 | 1019 ms |
| 2026-08-11 00:24 UTC | `8f0f60c+dirty` | openai | `gpt-4o-mini` | 59/61 (97%) | 0 (0%) | 2293 | 1206 ms |
| 2026-08-11 00:31 UTC | `6feea28+dirty` | openai | `gpt-4o-mini` | 67/69 (97%) | 0 (0%) | 2361 | 1079 ms |
| 2026-08-11 00:38 UTC | `6feea28+dirty` | openai | `gpt-4o-mini` | 66/69 (96%) | 0 (0%) | 2383 | 1036 ms |
| 2026-08-11 00:40 UTC | `6feea28+dirty` | openai | `gpt-4o-mini` | 68/69 (99%) | 0 (0%) | 2383 | 1132 ms |
| 2026-08-11 09:28 UTC | `fdfac31+dirty` | openai | `gpt-4o-mini` | 68/69 (99%) | 0 (0%) | 2383 | 993 ms |
| 2026-08-11 09:31 UTC | `fdfac31+dirty` | openai | `gpt-4o-mini` | 66/69 (96%) | 0 (0%) | 2383 | 1170 ms |
| 2026-08-11 09:32 UTC | `fdfac31+dirty` | openai | `gpt-4o-mini` | 69/69 (100%) | 0 (0%) | 2383 | 1120 ms |
| 2026-08-11 09:35 UTC | `fdfac31+dirty` | openai | `gpt-4o-mini` | 68/69 (99%) | 0 (0%) | 2383 | 1103 ms |
| 2026-08-11 09:37 UTC | `fdfac31+dirty` | openai | `gpt-4o-mini` | 68/69 (99%) | 0 (0%) | 2383 | 1083 ms |
| 2026-08-11 09:39 UTC | `fdfac31+dirty` | openai | `gpt-4o-mini` | 68/69 (99%) | 0 (0%) | 2383 | 1037 ms |
| 2026-08-12 11:46 UTC | `89357fb+dirty` | openai | `gpt-4o-mini` | 72/72 (100%) | 0 (0%) | 2412 | 1029 ms |
| 2026-08-12 11:48 UTC | `89357fb+dirty` | openai | `gpt-4o-mini` | 72/72 (100%) | 0 (0%) | 2412 | 1279 ms |
