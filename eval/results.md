# Router eval results

Append-only. One row per run. See [README.md](README.md) for what the metrics
mean and the rules for changing the test set.

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

## Notes on specific rows

**Runs that never reached the model are not recorded.** A bad credential or
dead network measures the harness, not the arm, and a 0% row that actually
means "auth failed" is worse than no row. Enforced by the
`every_case_errored` guard in `run_eval.py`. One such row was written on
2026-08-08 before that guard existed and has been removed.

**`+prompt-edit` / `+vocab-edit` / `+pane-correction`** mark runs made against
uncommitted working-tree changes. The harness reads source files, not the
committed tree, so a bare SHA would describe code that never existed in that
commit. The first three were relabelled by hand; `run_eval.py` now appends
`+dirty` automatically.

**Two reverted attempts at `settings-general`.** Rewording the prompt changed
nothing. Adding alias keys to the pane vocabulary also changed nothing on the
target case *and* regressed `gpt-5.6-luna` 27 → 26 by giving models a
generic-sounding bucket — both "banana settings" and "doc settings" started
resolving to About. Both reverted. The eventual fix was deterministic
(`AgentRouter.correctedSettingsPane`), not prompt-based.

**Run-to-run variance is real.** `gpt-4o-mini` failed
`settings-screen-time-implicit` with `Uptime` on one run and `NowPlaying` on
another, same input. Differences of one case are inside the noise — re-run two
or three times before believing a small delta.
