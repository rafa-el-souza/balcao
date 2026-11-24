## Summary

<!-- What changes and why, in a few lines. Deviations from the spec name the
design §10 note or the ADR written in this pull request. -->

## Requirements touched

<!-- FR, NFR and SR ids, each with the tests or CI steps that cover it. When
evals changed: the scorecard delta, with reps and the noise floor. -->

<!-- Merge danger: only for a one-way door (a migration that drops data, a
secret's name, the deploy path). Say the blast radius; otherwise delete. -->

## Review

<!-- ADR-0013. Required on every pull request that changes executable code
(everything except docs/, config/locales/, evals/recordings/,
evals/scorecard.md and Markdown; workflow and configuration YAML count). The
agents' reports are kept outside the repository; this section is the record. -->

**Instruments run:** finder (scope) · verifier (risk list only) · fix review (risk list only) · screenshots at 390 px and desktop in pt-BR (screens only)

**Findings by reach:** cliente 0 · dono 0 · atacante 0 · teorico 0 · dismissed 0

### Fixed

<!-- One line per finding: id, reach, one sentence, the fix commit. -->

### Dismissed

<!-- One line per dismissed claim: id, the claim, the written reason. -->

### For the owner

<!-- One line per teorico finding and per cannot-tell claim settled by a
green test: id, the finding, the recommendation. Read at the MVP close and
at milestone closes; the pull request does not wait for it.

ADR-0024. A finding that stays open and that someone outside the system
could trigger, with no internal failure first, goes to the private record
with its scenario; here it is counted under its reach and replaced by one
line: "One finding an outside party could trigger is kept private until it
is fixed (ADR-0024)." A dependency's defect is described only after its
maintainers release a fix. The owner's decisions are written by role and
date, with the reason, in the third person: no quotation of his words or of
the options he was shown. -->
