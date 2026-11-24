# ADR-0024: What the public record holds back: open findings an outside party could trigger, a third party's issue before its fix, the owner's words

**Status:** accepted · **Date:** 2026-11-24 (the owner's choice the
same day, after a read-only audit of what the repository and its pull
requests publish) · Extends
[ADR-0007](0007-public-design-docs-adrs-threat-model.md): what of the
public record waits for a fix; and
[ADR-0013](0013-review-policy-own-finder-verifier-reach-triage.md): one
kind of finding leaves the pull request's Review section until it is
fixed.

## Context

ADR-0007 makes the design, the ADRs, the threat model and the evals
public; ADR-0013 makes each pull request's Review section the record of
its review, written before the merge. Together they publish every
finding with its scenario and its recommendation, those that stay open
included, on the day the pull request merges.

A read-only audit of 2026-11-20, done again on 2026-11-23 against the
pull requests merged since, sorted what that record publishes:

- Most open lines (`teorico`, accepted, deferred) need an internal failure
  first, a database, a worker or a deploy that fails, and give someone
  outside the system nothing to act on.
- All `atacante` findings but one were fixed in their own pull request, as
  ADR-0013 requires; the owner accepted the one left (threat model R10),
  and one found outside a diff waited for a later slice and was fixed
  there, with its scenario public meanwhile.
- The accepted risks an outside party can trigger are public with their
  numbers (threat model R8 and R10); they are common weaknesses of a
  small host, not rare paths.
- A dependency's defect found here was described in full on the day its
  pull request merged, as every finding is.

The common practice is coordinated disclosure. GitHub's page on it: "The
initial report of a vulnerability is made privately, and the full details
are only published once the maintainer has acknowledged the issue, and
ideally made remediations or a patch available". A public repository
says how to report privately in a `SECURITY.md`, and GitHub offers a
private reporting form a repository's owner turns on. This repository
had neither.

The same audit read how the owner's decisions appear: by role and date,
as MADR's template records a decision's makers and its date, but also as
his words quoted as he typed them in Portuguese, the labels of the options
he was shown included, and as pull request text addressed to him in the
second person.

What is already public cannot be taken back: the git history keeps every
version, GitHub shows a pull request's edit history to every reader, and
an accepted ADR's decision text never changes (the ADR index).

## Options

For open findings:

1. **Keep everything public at merge.** No cost; a finding an outside
   party could trigger stays readable, with its recipe, while it is open.
2. **An open finding an outside party could trigger, and a third party's
   issue before its fix, kept private until it is fixed or accepted; a
   `SECURITY.md`; private reporting turned on.** About an hour once, then
   one question per finding at triage.
3. **Every unfixed finding private,** `teorico` lines and dismissals
   included. The record loses most of its content for a small gain, since
   most open lines need an internal failure.
4. **The Review section published only after the fixes.** The record
   arrives later than the merge, and a close has two places to read.
5. **Rewrite what is already public.** The history keeps it all; small
   gain.

For the owner's decisions:

1. **As written so far.**
2. **Attributed by role and date with the reason, in the record's
   language and in the third person; no quotation of his words or of the
   options he was shown.**
3. **No attribution:** a decision reads as the project's, with its date.
   The record no longer shows who decided over the agent's work (threat
   model T8).

## Decision

Option 2 for open findings, option 2 for the owner's decisions; what is
already public stays as written.

**The question at triage.** Every finding that stays open after a pull
request (a `teorico` line, a finding accepted or deferred to a later
slice, one found outside the diff) is asked: can someone outside the
system trigger it, with no internal failure first? If yes:

- its scenario, reproduction and recommendation go to a private record
  kept outside the repository, read by the owner at the closes like the
  Review section;
- the Review section counts it under its reach and carries one line in
  its place: "One finding an outside party could trigger is kept private
  until it is fixed (ADR-0024)";
- the pull request that fixes it publishes it whole; if the owner accepts
  it instead, the threat model's accepted risks publish it with the
  acceptance.

**A third party's issue** (a dependency's defect found here, or one
reported to its maintainers) is described in the repository only after
its maintainers release a fix or publish it; until then the application's
own guard is described by what it does.

**`SECURITY.md`** at the root says how to report a vulnerability (GitHub's
private vulnerability reporting, which the owner turns on), what counts,
and that reports and open findings stay private until they are fixed.

**The owner's decisions** are written by role and date, with the reason,
in English and in the third person: "the owner chose on <date> to
…". His words are not quoted, nor the options he was shown; no text is
addressed to him in the second person.

**What is already public stays as written,** in the documents, the code
comments and the pull requests.

## Consequences

- One more question per open finding at triage, and a private record to
  keep; a close reads it with the Review sections and moves each of its
  lines to fixed, accepted or still open.
- The counts by reach stay complete; for the time a finding is open, its
  scenario is missing from the public record.
- A reader who finds a vulnerability has a private channel, and the
  repository says so.
- The record still shows that the owner decides and when, without his
  conversation.
- The pull request template's Review section and the working agreement's
  review rules follow this ADR.
