# ADR-0022: What publishing the demo needs comes first, the showcase after

**Status:** accepted · **Date:** 2026-11-19 (a documents-only pull request;
the owner's words the same day) · Amends
[ADR-0020](0020-what-v1-leaves-out-the-plan-after-the-mvp.md): its order
("M4, M2, M3, M5, as before") and its words "which the operator links once
from the console".

## Context

ADR-0020 kept the milestones' order, M4, M2, M3, M5, and design §9.2 listed
its 33 slices in it. Four are done (M4-1 to M4-4). In that order the demo
reaches a host of its own only at M3-7, the twentieth of the 29 slices
left, after the bookings, the console and the handoff. Until then the
public name serves the MVP host, which the implementing session deploys
(ADR-0011's MVP amendment), on the dev/eval key, under a cap of US$ 10
(the runbook).

The owner wants to publish the demo for real before the showcase, once
what a public demo needs is done. Asked on 2026-11-19, the session sorted
the slices left into what a visitor sees (the showcase), the operator's
own tools, and what protects or runs the demo: security, spend, operation,
CI, infrastructure and the closes.

## Options

1. **ADR-0020's order:** all of M2 before M3's production cut.
2. **What publishing needs first**, ending with M3's production cut, and
   the showcase after it; the demo is publicised on the day of the cut.
3. **Publicise the MVP host** once Turnstile and the guardrail are in.
   The implementing session deploys that host, on the dev/eval key with a
   cap of US$ 10; ADR-0011's argument, production deployed by a human
   only, is what "for real" means here.

## Decision

Option 2 (the owner, 2026-11-19), with his three answers of the same day:
the demo is publicised on the day of the cut, the voice notes go to the
showcase, and the console comes after the publication.

**Block 1, what publishing needs**, in this order: M4-6 (the review of
M4's first four slices), M2-1 (Turnstile), M2-2 (the guardrail), M2-3 (the
economy model), M2-4 (the `injection` suite, without the fourth chip),
M2-11a (the full eval run on both models, the boundary at 100 % on both,
since M3-1 puts the economy model in front of visitors), M3-1 (the
budget's modes), M3-2 (the canary), M3-4 (a turn's hard edge, the
least-privilege role, the short log sweep), M3-5 (the CI furniture), M3-6
(the runbook and the cut prepared), M3-7 (the production cut, and the
publication the same day, so the soak's week runs with real visitors) and
M3-8 (M3's close, after the soak).

**Block 2, the showcase and V1's close**, written while the soak runs and
deployed to production by the owner after it: the data-contract
specification session (ADR-0018), M4-5 (the voice notes), M2-5 to M2-10
(the bookings, the calendar, the console, the handoff and the console's
tools), M3-3 (the status page, with the fourth chip), M2-11b (the rest of
M2's close) and M5-1 to M5-8.

**What moves between slices.**
- M4-6 leaves the voice note to M4-5; its real conversation on the demo
  stays, in text, and measures NFR-01's figures (design §10, M4-2's note).
  M4's "done when" is met when M4-5 lands.
- M2-4's fourth chip goes to M3-3, which already carried its link; the
  chip still comes after FR-20 and the `injection` suite (FR-21).
- M2-11 splits. M2-11a: the full eval run on both models with the unstable
  count, and the review at the close over M2-1 to M2-4. M2-11b:
  `bin/traceability`'s first report, the review at the close over M2-5 to
  M2-10 with the interface review in three languages, and J3 run for real.
- The operator's alert through the bot moves from M2-9 to M3-1, which
  needs it at the cap. Until the console exists, the operator links the
  chat once by a command the runbook names, run where the operator's
  commands run; the console's button, with M2-9, links it the same way
  later. SR-35 holds: only someone who can run a command in the
  application's container can link a chat.
- The console's kill switch moves from M3-1 to M2-10, with the budget and
  mode panel; until then the switch is the runbook's command, as it has
  been since the MVP.
- SR-33's check of the invented name, address and phone moves from M5-6 to
  M3-6, since it is due before the demo is publicised.

**At publication the demo has no console.** The operator pauses the demo
or forces a mode with the runbook's command and reads the conversations
and the dead letter by command too; no visitor identity can be blocked
until M2-7. Turnstile, SR-01's limits, the per-visitor caps and the
monthly pause bound an abuser (threat model R2).

## Consequences

- Block 1 is thirteen slices and block 2 seventeen, with the
  specification session; M2-11's split makes the plan 34 slices.
- After the cut every production deploy is the owner's, from the operator
  account, after SR-38's review of the deploy path (ADR-0011). In
  ADR-0020's order the bookings, the console and the handoff reached the
  public name through the session's deploys to the MVP host; now each
  reaches it through one of the owner's. The showcase is merged in groups,
  so that one deploy carries a group.
- The soak allows no deploy, and a failed day restarts its week (§9.2): a
  fix the first public week needs costs the week.
- The cut reissues the bot's token for the production set, so a showcase
  slice that needs the live bot (the voice notes, the offered slots as a
  reply keyboard, the handoff's alert) cannot use the demo bot from a
  rehearsal host. How such a slice is seen before the owner's deploy is
  his question before M4-5; a second bot for the rehearsal set is the
  likely answer.
- The data-contract gate leaves block 1: ADR-0018 is needed before M2-5,
  the first slice of block 2 that needs it, and its session can come any
  time before. The fallback §9.2 wrote for a gate still closed after M2-4
  (M3-2, M3-4 and M3-5 first) is now the plan.
- The requirements say it: design §9.2, §12, FR-10 and FR-14; threat model
  SR-35, R2 and §6; the runbook's kill switch; the README's next steps.
