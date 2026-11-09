# Review instruments: what each one does

Every review instrument used on this repository is recorded here before its
first use: what it looks for, how much it returns, whether it verifies, and
its blind spots. A reviewer whose recipe is unknown is not run (ADR-0013).
The texts of built-in recipes belong to their vendor and are not copied here;
this file records their behaviour.

## The project's own agents

Defined under `.claude/agents/`, each file being its own recipe: `finder`
(six correctness angles, no cleanup, no floor, cap of fifteen with the rest
named, JSON with proposed reach; every executable pull request), `verifier`
(claims only, own route, four verdicts with a score, reach, reproduction,
second step comparing routes; risk-list pull requests), `fix-review` (one
question over fix commits, reproduction required; one pass, risk list) and
`interface-review` (screens against the brief, the wireframes and
`interface-checklist.md`; assertions, never pixels; at the MVP close and at
milestone closes). When and where each runs is ADR-0013. Their recall is
unmeasured until defects found on the host are attributed to their origin
at the MVP close; the pull requests' Review sections are the measure.

## Built-in `/code-review` (Claude Code 2.1.318, read 2026-11-06)

**How the recipe is chosen.** The recipe is selected by the *model the session
runs on* and the level typed (`low`, `medium`, `high`, `xhigh`, `max`). The
session's model family is looked up in a fixed table; a family the table does
not name falls to a default column. On 2026-11-06, both models available in
this development account (Fable 5.1 and Opus 5.5) fell to the default column,
observed by reading the tag line of the prompt each one received. The table
below is the default column; Sonnet 5 has its own column, which fans out to
finder and verifier subagents at `medium` and above, and is not what runs
here.

| Level typed | What runs (default column) | Angles | Floor | Cap | Verification |
|---|---|---|---|---|---|
| `low` | one pass over the hunks of the diff, no file reads beyond the diff, no subagents | correctness visible in the hunk, plus duplicated helper or dead code visible in the diff | at least min(files changed, 4) | 8 | none |
| `medium` | **identical to `high`** | | | | |
| `high` | eight angles run inline by the session, in sequence; no subagents | 3 correctness (line by line with the enclosing function; removed behaviour; callers and callees) + 3 cleanup (reuse, simplification, efficiency) + altitude (prefer the general change over a special case) + conventions (CLAUDE.md violations, quoted) | at least 5, "do not invent" | 10 | none: dedup only, "do not re-judge" |
| `xhigh` | ten angles inline (adds language pitfalls and wrapper/proxy correctness), then a gap sweep in the same context | as above + 2 correctness | at least 7 | 15 | none; "do not drop on uncertainty" |
| `max` | ten finder subagents, one verifier subagent per candidate (one vote: confirmed, plausible, refuted), then a sweep subagent | as `xhigh`, fanned out | none stated | 15 | yes, one vote per candidate; refuted dropped |

Notes that matter for the policy:

- **Verification exists only at `max` on these models.** The `CONFIRMED` and
  `PLAUSIBLE` verdicts the findings tool can carry are produced only there (or
  on Sonnet 5). The project's own verifier (ADR-0013) is the only
  verification that runs in this repository.
- **Cleanup angles are half the recipe** from `medium` up: reuse,
  simplification, efficiency, altitude and conventions. Their candidates use
  the same shape as bugs and compete for the same cap; correctness outranks
  them only when the cap forces a cut. A finding of these angles is a
  cleanup, not a defect, and the policy routes it to `deferred`.
- **A floor is stated at every level** (half the cap from `medium` up, with
  "do not invent to hit the floor"). A floor pushes marginal candidates
  through; the project's verifier is what decides them.
- **The cap is silent.** Candidates beyond the cap are dropped without a
  note. `--max-findings all` lifts it; the flag is sticky across runs, so the
  policy never passes it.
- **The level is sticky too**: with no level typed, the last one typed is
  reused. The policy always types the level.
- **Scope.** The recipe reads the diff against the upstream or `main` plus
  uncommitted changes, or the PR, branch or path passed as a target. It reads
  enclosing functions and callers; it is not a whole-branch or whole-file
  review.
- **Execution shape in this account.** Invoked from a session, the skill runs
  as a forked background agent on the session's model, with the session's
  full context. Invoked from a subagent it forks again, on that subagent's
  model. The findings arrive as a task notification.
- **Use in this repository (ADR-0013).** None in the MVP: the built-in is
  not run, because its cleanup angles, its floor, its silent cap and its
  conventions angle (which would quote the owner's private file) make it a
  poor policy even where it is a good finder. The recipe is recorded here
  so that a later revisit can decide to run it as a counterweight, from an
  Opus agent as in the probe, with its candidates transcribed into the
  finder's shape and triaged like any other, and its conventions
  candidates discarded before anything is written.
- **`--comment`** posts each finding as an inline PR comment through the
  GitHub token, before any verification; **`--fix`** applies findings to
  the working tree. Neither is used here.

### Probe of 2026-11-06

A throwaway repository outside the project, with fourteen planted
correctness defects (nine Ruby, five TypeScript), three cleanup baits and two
correct helper files reachable only through the reuse angle. The `medium`
recipe was run twice on Opus 5.5: once through the skill itself, once with the
same recipe text pasted to a plain agent. Results below.

| | Run 1: the skill itself (Opus 5.5) | Run 2: the same recipe text, plain agent (Opus 5.5) |
|---|---|---|
| Tool calls | 3 | 11 |
| Planted defects found as their own finding | 10 of 14, two more merged into one finding | 9 of 14, two pairs merged |
| Found but cut by a cap | 1 cleanup bait | 2 real bugs by the per-angle cap of 6; 1 planted bug reclassified as simplification and cut by the final cap |
| Missed outright | 2 (the cancel that never reaches the store; the idempotency race) | 1 (the idempotency race) |
| Real defects not planted | 0 | 2 (cancel raises for a delisted item before deleting the row; cancel does not invalidate the query) |
| False positives | 0 | 0 |
| Cleanup angles in the output | 1 finding (duplication + reuse), 1 cut | 0 in the ten, 7 cut by the cap |
| Conventions angle | nothing (no CLAUDE.md in the probe) | 2 candidates quoting the user-level CLAUDE.md, cut by the cap |

What the probe showed:

- **Recall is good and precision was perfect** on a small diff: twelve or
  thirteen of fourteen planted defects reached the output or the cap, with
  no false positive, at a cost of three to eleven tool calls.
- **The caps drop real bugs in silence.** The per-angle cap of six dropped
  two real bugs in run 2 before they could compete with weaker findings from
  another angle; the final cap of ten merged pairs of defects into one
  finding in both runs. Nothing says so in the output.
- **The conventions angle reads the tool's user-level working-agreement
  file** and quotes it in findings. In this repository that file is the
  owner's private working agreement (ADR-0007): a finding of this angle
  never enters the findings file and is never posted. This alone rules out
  `--comment`.
- **Every finding lacks what the policy needs**: no reach, no reproduction,
  no verification, and cleanup mixed with correctness. The project's
  finder and verifier add the first three; triage separates the fourth.
- The sample is one small diff on one day; the numbers are indicative, not a
  measurement.
