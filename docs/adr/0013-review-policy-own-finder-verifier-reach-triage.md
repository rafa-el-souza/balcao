# ADR-0013: Review policy: the project's own finder, a verifier on risk-list pull requests, triage by reach, the pull request as the record

**Status:** accepted · **Date:** 2026-11-09 (decided with the owner after a
first, heavier draft of 2026-11-06 was judged too expensive for a twelve-day
MVP; the built-in reviewer's recipe was read and probed on 2026-11-06, see
`docs/reviews/instruments.md`).

## Context

The code of this repository is written mostly by a coding agent and merged
by that agent once CI is green (threat model T8); the owner writes and
reviews whatever he chooses. CI holds the mechanical gates: lint, static
security analysis, dependency audit, the suites with a fake model, the
secret scan. What CI cannot hold is a reading of the change for logic
defects. The first draft of the working agreement left that reading to
Claude Code's built-in `/code-review`, with the author of the change
deciding which findings were real.

Three facts made that draft insufficient:

1. **The author judged its own review**, in the same context that produced
   the bug, with no evidence required for a discard.
2. **The built-in recipe depends on the session's model.** Read in the
   tool's code and probed on 2026-11-06: for the models used here, `medium`
   and `high` are the same recipe, eight angles run inline, half of them
   cleanup competing with correctness for a cap of ten, a floor of five, no
   verification, and a conventions angle that quotes the user-level
   working agreement, which here is the owner's private file (ADR-0007).
   Recall was good on a probe (twelve of fourteen planted defects) and
   precision perfect; what the output lacks is reach, reproduction and
   verification.
3. **Nothing was recorded**, so nothing could be counted later.

A heavier policy was then designed on 2026-11-06 (four agents on every pull
request, a verifier per finding, a counterweight, findings as a TSV with a
Ruby script, a CI job and a merge hook, screenshot baselines) and set aside
the same night: for a twelve-day MVP of nineteen pull requests, its
ceremony would have cost more days than the defects it would catch.

## Options

1. **The built-in reviewer as the policy**, author decides. Cheapest; the
   three facts above stand.
2. **The heavy policy of 2026-11-06.** Every finding verified, recorded and
   enforced; about a day of review per three days of code.
3. **A lean policy with the project's own instruments:** a tracked finder
   on every pull request that changes executable code, a verifier and one
   fix review on the risk list only, triage by reach, the pull request's
   Review section as the only record, revisited with numbers at M5.

## Decision

Option 3.

**Scope.** Every pull request that changes executable code is reviewed
before merge. Executable is everything except `docs/`, `config/locales/`,
`evals/recordings/`, `evals/scorecard.md` and Markdown files; workflow and
configuration YAML count as executable.

**Instruments.** Agent definitions under `.claude/agents/`, tracked,
written and changed in pull requests like any code, each read-only with its
limits written as prohibitions (no writes, no git that writes, no network,
no builds or tests, no sub-agents) and each given the code and the claims,
never the author's conclusions:

- *Finder*, on every pull request in scope, once CI is green and before any
  fix: correctness only (line by line with the enclosing function; removed
  behaviour; callers and callees; the language's pitfalls for Ruby, Rails,
  TypeScript, React and SQL; wrappers and adapters; the requirement ids the
  diff cites, traced), no cleanup angles, no floor, a cap of fifteen with
  every candidate beyond it named in one line. Each candidate carries a
  concrete scenario, a reproduction when one can be stated, and a proposed
  reach. One run per scope (Rails, `web/`) when a pull request exceeds
  about seven hundred added lines.
- *Verifier*, on **risk-list** pull requests only: receives the claims
  (location, what is said to happen, conditions, proposed reach), never
  the finder's route, builds the path from the code itself, weighs what
  stops the claim as well as what makes it worse, and decides `real`,
  `real with conditions`, `not real` or `cannot tell`, with the decisive
  line, the reach as it finds it and its own reproduction; then compares
  with the finder's route. On other pull requests the author triages the
  finder's claims under the dismissal rule below.
- *Fix review*, on risk-list pull requests only, once: after the fixes are
  committed, one question over those commits alone, what did they break or
  leave half done, with a reproduction for every finding; never a second
  pass; what is left is written for the owner.
- *Interface review*: once, at the MVP close, over the screens that exist,
  against `docs/design-brief.md`, the wireframes of design §6.8 and
  `docs/reviews/interface-checklist.md`, with Testing Library or Playwright
  assertions as reproductions, never pixels. Before any pull request that
  creates or changes a screen, the session itself takes screenshots at
  390 px and desktop in pt-BR and looks at them; that is the interface
  check inside the MVP.

**The risk list.** Session cookie and Origin checks, Rack::Attack limits,
the budget cap and ledger, secrets and the boot check, the Dockerfile and
the Kamal configurations, the tools and their idempotency keys, the
WhatsApp webhook and the Graph API client, authentication when the console
arrives, and the pull request that closes the MVP or a milestone. There the
finder's brief receives the SR ids the diff touches, to attack on purpose.

**Reach decides, not severity.** Every kept finding gets a reach, written
by the verifier where one ran and by the author otherwise, and never
relabelled afterwards: `cliente` (someone talking to Balcão or visiting the
landing meets the effect), `dono` (the owner meets it in the console, the
deploy or the evals), `atacante` (an actor of the threat model crosses a
trust boundary), `teorico` (only a failure path nobody drives). The first
three are fixed in the pull request, test first, one commit per finding,
the commit body naming the finding; a fix is surgical and never redesigns
an existing rule. `teorico` findings get their line and the author's
recommendation and are the owner's call, in batch.

**Dismissal is the owner's.** No finding is dropped without a written
reason in the pull request. The owner reads the dismissals and the
`teorico` lines in batch at the MVP close and at each milestone close (his
round); pull requests do not wait for him. A `cannot tell` claim is settled
by writing its reproduction as a test: red, it is fixed as its reach says;
green or no test possible, it is the owner's call with the test kept as a
guard. An author that disagrees with a `real` finding says so in words,
with the test it would have written, and the finding goes to the owner.

**The record is the pull request.** A tracked pull request template opens
every pull request with a Review section: instruments run, findings by
reach, fixed lines with their commits, dismissed lines with their reasons,
`teorico` lines for the owner. Nothing else: no findings file, no script,
no CI job, no merge hook, no inline posting through the GitHub API; the
reports of the agents are saved whole outside the repository. The built-in
`/code-review` is not used; its recipe stays recorded in
`docs/reviews/instruments.md` so that nobody runs it blind later.

**Revisit at the MVP close and at M5**, from the pull request descriptions:
findings per instrument and reach, dismissals, defects found on the host
that no review caught. What to add then (the verifier everywhere, the fix
review everywhere, a data record, the counterweight, screenshot baselines)
is decided one item at a time, each as an amendment or a new ADR.

## Consequences

- The working agreement's review rules are the operational summary of this
  ADR; this ADR is where a rule's reason lives.
- `docs/reviews/` holds the instruments record and the interface checklist;
  `.claude/agents/` holds the four briefs, public, with nothing private in
  them (ADR-0007). The heavier policy's artefacts (the findings format, the
  script contract, the enforcement layers) stay outside the repository
  until a revisit asks for them.
- Cost inside the MVP: about half an hour per pull request (one Opus agent
  and the triage) plus a second agent on the risk list, about a day and a
  half in twelve, counted in design §9.1.
- Two risks accepted and measured rather than designed away: the author's
  triage on non-risk pull requests may lean toward dismissing (the owner's
  round reads every dismissal), and the finder's recall is unmeasured until
  defects found on the host are attributed to their origin.
- The ADR-0005 measurement planned for M4 is ADR-0014.
