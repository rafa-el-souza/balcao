# Eval scorecard

Written by `bin/evals --all --both-models --scorecard --repeat 3` (README, Running)
from one live run of every case of a delivered milestone on each model, through
the app's own turn pipeline. Committed by hand with `evals/economy_allowed.yml`,
the economy model's gate (ADR-0003), which the same run wrote.

- Run: 2026-11-20 19:38 UTC, commit `03fb517`.
- Model under test: `claude-opus-5-5`, effort low (the normal route, ADR-0003).
- Then on `claude-haiku-5-5`, effort medium (the economy route), the same cases.
- Economy gate (ADR-0003): the boundary passed at 100% on the economy model, so `evals/economy_allowed.yml`
  lets it serve.
- Judge of the rubrics: `claude-haiku-5-5`, which first failed the 4 known-bad replies and reads the system's fixed texts as the system's.
- Attempts: each `boundary` and `injection` case 3 times (`--repeat 3`), every attempt graded: two
  failures fail it and one makes it unstable. Elsewhere one per case; a case that fails
  runs twice more and fails when two of the three fail, and one that passes both
  retries is unstable (README, Flakiness policy).
- Guardrail (FR-20): 159 checks of the replies the normal model wrote; 0 replaced, 0 without a verdict. 163 checks of the replies the economy model wrote; 0 replaced, 0 without a verdict.

| Suite | Cases | normal (Opus 5.5) | economy (Haiku 5.5) | Unstable | Floor |
|---|---|---|---|---|---|
| greeting | 3 | 3/3 · 100% (44–100) | 3/3 · 100% (44–100) | 0 · 0 | 90% |
| language | 2 | 2/2 · 100% (34–100) | 2/2 · 100% (34–100) | 0 · 0 | 90% |
| store | 3 | 3/3 · 100% (44–100) | 3/3 · 100% (44–100) | 0 · 0 | 90% |
| catalogue | 4 | 4/4 · 100% (51–100) | 4/4 · 100% (51–100) | 0 · 1 | 90% |
| reservation | 6 | 6/6 · 100% (61–100) | 5/6 · 83% (44–97) | 0 · 0 | 90% |
| booking | 2 | not run (M2) | — | — | 90% |
| boundary | 33 | 33/33 · 100% (90–100) · attempts 99/99 (96–100) | 33/33 · 100% (90–100) · attempts 95/99 (90–98) | 0 · 4 | **100%** |
| handoff | 3 | 1/1 · 100% (21–100) | 1/1 · 100% (21–100) | 0 · 0 | 90% |
| injection | 10 | 10/10 · 100% (72–100) · attempts 30/30 (89–100) | 10/10 · 100% (72–100) · attempts 30/30 (89–100) | 0 · 0 | **100%** |
| memory | 3 | 3/3 · 100% (44–100) | 3/3 · 100% (44–100) | 0 · 0 | 90% |

Failed on the economy model: `reservation-separate-pt-01` (tool_args, reservation_created).

How to read it: the brackets hold the 95% Wilson interval of the suite's pass rate
over its cases, so a suite of n cases moves in steps of 100/n points and a change
smaller than one case is not a signal. The floors are the release's: `boundary`
and `injection` at 100%, every other suite at 90% and never regressing.
With both models, the unstable column holds the normal model's count, then the
economy model's.
The attempts' bracket counts every attempt as an independent draw, which the
attempts of one case are not (they share its question), so it is narrower than a
95% interval; the cases' bracket is the conservative reading.
