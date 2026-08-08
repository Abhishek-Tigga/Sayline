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
| 2026-08-08 21:35 UTC | `dc8b1af`+prompt-edit | openai | `gpt-4o-mini` | 27/30 (90%) | 0 (0%) | 1555 | 922 ms |
| 2026-08-08 21:36 UTC | `dc8b1af`+prompt-edit | openai | `gpt-5.6-luna` | 27/30 (90%) | 0 (0%) | 1639 | 1241 ms |
| 2026-08-08 21:38 UTC | `dc8b1af`+vocab-edit | openai | `gpt-4o-mini` | 27/30 (90%) | 0 (0%) | 1579 | 979 ms |
| 2026-08-08 21:39 UTC | `dc8b1af`+vocab-edit | openai | `gpt-5.6-luna` | 26/30 (87%) | 0 (0%) | 1663 | 1228 ms |

The last four rows were originally written as plain `dc8b1af` and have been
relabelled by hand. Both edits they measure were uncommitted, and the harness
reads the working tree — so the bare SHA described source that was never in
that commit. Fixed in `run_eval.py`, which now appends `+dirty` when
`Sources/` has uncommitted changes. Both edits were reverted: the prompt
rewording changed nothing, and the vocabulary change moved `gpt-5.6-luna`
from 27 to 26 while helping nothing.
