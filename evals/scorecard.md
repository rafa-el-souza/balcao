# Eval scorecard

No run yet. The first scorecard is produced at the MVP close by a local
run on the normal model (`bin/evals --all --model normal --scorecard`, the
economy column stays empty); from M2 the full-eval workflow
(`workflow_dispatch`, started by the owner) runs
`bin/evals --all --both-models --scorecard`.

Live runs apply the flakiness policy of `README.md`; "unstable" counts
cases that failed once and passed on retry.

| Suite | Cases | normal (Opus 5.5) | economy (Haiku 5.5) | Unstable | Floor |
|---|---|---|---|---|---|
| greeting | 3 | — | — | — | 90% |
| language | 2 | — | — | — | 90% |
| store | 3 | — | — | — | 90% |
| catalogue | 4 | — | — | — | 90% |
| reservation | 4 | — | — | — | 90% |
| booking | 2 | — | — | — | 90% |
| boundary | 10 | — | — | — | **100%** |
| handoff | 2 | — | — | — | 90% |
| injection | 3 (10 at M2, 15 at M5) | — | — | — | **100%** |
| memory | 3 | — | — | — | 90% |
