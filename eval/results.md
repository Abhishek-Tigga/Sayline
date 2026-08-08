# Router eval results

Append-only. One row per run. See [README.md](README.md) for what the metrics mean and the rules for changing the test set.

Runs where every case failed before reaching the model (bad credential,
network down) are **not** recorded — they measure the harness, not the
arm, and a 0% row that actually means "auth failed" is worse than no row.
The harness enforces this; see the `every_case_errored` guard in
`run_eval.py`. One such row was written on 2026-08-08 before that guard
existed and has been removed.

| When | Commit | Arm | Model | Accuracy | Syntax failures | Median tokens | Median latency |
|---|---|---|---|---|---|---|---|
| 2026-08-08 21:17 UTC | `a2ef4fc` | openai | `gpt-5-nano` | 26/30 (87%) | 0 (0%) | 1602 | 2952 ms |
| 2026-08-08 21:26 UTC | `4e6edb4` | openai | `gpt-5-mini` | 27/30 (90%) | 0 (0%) | 1602 | 2644 ms |
| 2026-08-08 21:27 UTC | `4e6edb4` | openai | `gpt-5.6-luna` | 27/30 (90%) | 0 (0%) | 1602 | 1251 ms |
| 2026-08-08 21:28 UTC | `4e6edb4` | openai | `gpt-4o-mini` | 27/30 (90%) | 0 (0%) | 1518 | 966 ms |
| 2026-08-08 21:31 UTC | `4e6edb4` | openai | `gpt-5` | 27/30 (90%) | 0 (0%) | 1602 | 3352 ms |
