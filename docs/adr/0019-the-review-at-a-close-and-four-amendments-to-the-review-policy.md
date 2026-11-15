# ADR-0019: The review at a close, and four amendments to the review policy

**Status:** accepted · **Date:** 2026-11-15 (decided with the owner in
three sessions that day: the plan and the triage, the close's instruments,
the decisions; the owner named the work "the MVP review") · Extends
[ADR-0013](0013-review-policy-own-finder-verifier-reach-triage.md); amends
one sentence of
[ADR-0015](0015-cable-limits-at-the-gate-and-in-the-driver.md).

## Context

ADR-0013 leaves two kinds of line in every pull request for the owner, in
one batch at each close: the claims the author dismissed, each with its
reason, and the `teorico` findings with a recommendation. That batch is the
owner's round of ADR-0013; at the MVP close it is what the owner called the
MVP review. ADR-0013 also asks to be revisited at the MVP close "from the
pull request descriptions", with numbers.

What the MVP close found, counted on 2026-11-15:

- **The lines.** The 28 pull requests reviewed by then held 326 such lines.
  Read one pull request at a time, a line that a later pull request
  resolved still looks open.
- **The triage against the code** (at `84554da`): of 102 recommendations
  that named a change, 48 had been made, 3 in part, 50 not, and 1 was moot.
  A recommendation that named a later pull request as its destination had
  been carried only where that slice's brief repeated it. Of 22 items left
  for a later milestone, 3 were named in the plan.
- **The author's dismissals.** Of nine dismissals that only the author had
  judged (pull requests off the risk list), an independent verifier
  confirmed two as not real; the other seven were facts of the code, two of
  them defects by the documents.
- **Two pull requests that changed only CSS** (#34, #35) were reviewed by
  looking and measuring instead of a finder, on the owner's word each time.
- **Gaps.** Six finder reports named files they had not read, and four pull
  requests carried fixes made after their fix review, which nothing
  reviewed.
- **The close's own instruments** added 32 lines: the interface review 12
  findings and two calls for the owner, its verifier 15 claims (after the
  comparison 12 real, 1 in part, 2 not real, and two more found while
  verifying), the eval audit 8 findings, and the docs reader test, five of
  whose five answers were inferred rather than read.
- **The numbers ADR-0013 asks for**, from the descriptions of pull requests
  #1 to #41 (39 merged, 9 of them with nothing to review): 377 findings,
  `cliente` 97, `dono` 81, `atacante` 30, `teorico` 165 and 4 that could
  not be told; by the instrument that raised each first, the finder 182,
  the verifier's own finds 89, the fix review 62, the silent-failure hunter
  43 and another session 1; 52 claims dismissed. Defects met on the demo
  that no review had caught: four, all on the page and none on money, data
  or security: the site had no icon (#22), every streamed reply fetched the
  whole conversation again (#24, reported by readers of the demo), four
  faults of the landing at other window sizes (#34) and a long link that
  pushed the trace page sideways on a phone (#35).

## Options

1. **ADR-0013 as written**: the owner reads every pull request's lines in
   order at the close. At 326 lines, read in isolation, resolved lines look
   open and open ones look resolved.
2. **A method for the review at a close, and four amendments** that move
   into each pull request what the MVP close had to catch afterwards.
3. **No owner's review**: the author's dismissals stand. Two of nine were
   wrong, so the dismissal rule of ADR-0013 stays.

## Decision

Option 2.

**The review at a close has a method.** It runs in this order, and its
working files stay outside the repository:

1. **A ledger**, one row per line, written from every pull request's
   Review section: the line, its recommendation, its kind and its theme.
2. **Triage against the code** by read-only agents: was each recommended
   change made (the line cited), and is each deferred item named in the
   plan. Every "not made" is read again by hand.
3. **A verifier over the claims that carry weight**: what was not made and
   touches money, privacy, data or security; what "nobody drives" until a
   later slice opened the path; every dismissal and every reach that only
   the author judged. Claims only, then the comparison with the reasons of
   the time.
4. **The close's instruments before any decision**: the interface review
   with its verifier, the eval audit and the docs reader test. Their
   findings are new rows.
5. **Each new row weighed against the documents**: a fact of the code, a
   defect with the document's line, or a question for the owner.
6. **The owner decides once**: a question for each line that is his alone
   to settle, with one recommendation, drawn where it is a matter of look
   or wording; and one word for each lot (accept, give a home in the plan,
   fix at the close, drop).
7. **The record is tracked**: a table in `docs/reviews/`, one row per line
   with its outcome, written by the pull request that closes the milestone
   (for the MVP, [`docs/reviews/mvp-review.md`](../reviews/mvp-review.md)).
   The pull requests stay the record of each review; the table is the
   record of the close.

**Four amendments to ADR-0013.**

1. **A recommendation with a destination is carried by the destination.**
   A line that says "in PR-n", "at M-n" or "when X first happens" enters
   that slice's brief when the slice opens (from design §9.2's row or §10's
   standing triggers) and is ticked or answered in that slice's Review
   section. A slice that leaves one undone says why.
2. **The author's dismissals are verified.** On a pull request off the risk
   list, the claims the author dismisses go in one batch to one verifier,
   claims only, before merge; a dismissal the verifier finds real is fixed
   or written for the owner as real. (On the risk list the verifier already
   reads every claim.)
3. **A pull request that changes only CSS** is reviewed by looking and
   measuring in place of the finder: screenshots of the branch at the
   widths and languages the change touches, each looked at; a measure of
   what the change is about (overflow, the fold, an overlap) before and
   after; axe-core and a keyboard walk when a control moves; one test that
   reads the rule from the sheet. The Review section says so and carries
   the measures.
4. **At a close, one extra finder** reads what the finders' reports named
   as unread and the fixes made after a fix review, once, in the pull
   request that closes the milestone; its claims go to that pull request's
   verifier.

**One sentence of ADR-0015 changes.** The 21st command on a connection
closes it with `reconnect: true`, not `false`: the browser's client sends a
subscribe again every half second until it is confirmed, so a confirmation
ten seconds late took an honest page to the limit, and with `reconnect:
false` that page stopped for good. A client that reconnects meets the
gate's count per source again, which is the limit that holds a flood (the
first server pull request of the MVP review, #40).

## Consequences

- The table and the ledger's scripts stay outside the repository; the table
  is generated once from the ledger and read through by hand.
- The cost of the MVP's review is the figure the M5 revisit compares: three
  sessions before any fix (the triage 1.5 h, the instruments 0.8 h, the
  decisions 1.1 h with the owner's time), four agents in the triage and
  three at the instruments, then six pull requests of fixes (#36, #38, #39,
  #40, #41 and the close, #42) of 0.75 h to 1.85 h each.
- Amendment 2 costs one verifier run on a pull request that dismisses a
  claim; amendment 4 one finder per close.
- The working agreement's review rules follow these four amendments; this
  ADR is where their reason lives.
- At M5, ADR-0013's revisit starts from these numbers: findings per
  instrument and reach, dismissals, defects met on the host.
