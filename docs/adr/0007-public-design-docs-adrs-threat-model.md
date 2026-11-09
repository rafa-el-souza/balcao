# ADR-0007: Design doc, ADRs, threat model and evals are public

**Status:** accepted · **Date:** 2026-11-02

## Context

This is a portfolio project: the reasoning is the product as much as the
code. Previous repositories by the author kept part of their specification
private, which hid exactly the material a hiring manager wants.

## Options

1. **Code public, specification private.** Hides judgement.
2. **A single living SPEC.md.** Readable, but no decision history and no
   separation of requirement from design.
3. **A tool-specific spec workflow (proposal/changes directories).** Fine
   for agents, unfamiliar to readers, heavy for one person.
4. **Industry-standard set: design document with numbered requirements and
   acceptance scenarios, MADR-style ADRs, a threat model, an executable eval
   suite with a committed scorecard; all public, all in English with
   Portuguese conversation examples.**

## Decision

Option 4. Requirement identifiers are cited by the tests that cover them
(NFR-08). After V1, changes arrive as issues and pull requests that edit the
design document in the same commit, with a new ADR when a decision changes.

## Consequences

- Reviewers can go from a claim in the README to the requirement, the ADR,
  the test and the scorecard without asking anyone.
- Writing discipline costs time at each change; accepted, it is the point.
- Nothing in the documents may reference private infrastructure, other
  projects of the author, or tooling not in the repo.
