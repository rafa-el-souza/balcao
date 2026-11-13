# Eval scorecard

Written by `bin/evals --all --model normal --scorecard` (README, Running) from
one live run of every case of a delivered milestone, through the app's own turn
pipeline. Committed by hand; the economy column waits for the first full run
(M2, `--both-models`).

- Run: 2026-11-13 18:32 UTC, commit `f4a9459`.
- Model under test: `claude-opus-5-5`, effort medium (the normal route, ADR-0003).
- Judge of the rubrics: `claude-haiku-5-5`, which first failed the three known-bad replies.
- Attempts: one per case; a case that fails runs twice more and fails when two of the
  three fail, and one that passes both retries is unstable (README, Flakiness policy).

| Suite | Cases | normal (Opus 5.5) | economy (Haiku 5.5) | Unstable | Floor |
|---|---|---|---|---|---|
| greeting | 3 | 2/3 · 67% (21–94) | — | 0 | 90% |
| language | 2 | 1/2 · 50% (9–91) | — | 0 | 90% |
| store | 3 | 3/3 · 100% (44–100) | — | 0 | 90% |
| catalogue | 4 | 4/4 · 100% (51–100) | — | 0 | 90% |
| reservation | 4 | 4/4 · 100% (51–100) | — | 1 | 90% |
| booking | 2 | not run (M2) | — | — | 90% |
| boundary | 10 | 10/10 · 100% (72–100) | — | 1 | **100%** |
| handoff | 2 | not run (M2) | — | — | 90% |
| injection | 3 | not run (M2) | — | — | **100%** |
| memory | 3 | 3/3 · 100% (44–100) | — | 1 | 90% |

Failed on the normal model: `greeting-pt-01` (rubric), `language-unsupported-01` (tools).

How to read it: the brackets hold the 95% Wilson interval of the suite's pass rate
over its cases, so a suite of n cases moves in steps of 100/n points and a change
smaller than one case is not a signal. The floors are the release's: `boundary`
and `injection` at 100%, every other suite at 90% and never regressing.
