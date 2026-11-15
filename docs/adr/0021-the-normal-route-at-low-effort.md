# ADR-0021: The normal route at low effort

**Status:** accepted · **Date:** 2026-11-15 (slice M4-2, after a measure on
the evals; the owner's word the same day) · Amends
[ADR-0003](0003-model-policy-opus-default-haiku-economy.md): the normal
mode's effort, `medium` there, is `low`.

## Context

ADR-0003 set the normal route on Claude Opus 5.5 at medium effort, the
model's default, before anything was measured. NFR-01 then asked a text
turn for a median under 4 s and a p95 under 10 s from the message's receipt
to the reply's send; the first real conversation, on 2026-11-15, took a
median of 7.5 s and a p95 of 16.6 s so measured, and the model was about
four fifths of it (design §10, M4-2's note).

On Claude Opus 5.5 thinking is always on, and effort is the one control of
how much the model reasons and writes. The provider's effort page, read on
2026-11-15, calls `low` "Most efficient. Significant token savings with
some capability reduction", for "Simpler tasks that need the best speed and
lowest costs", and its best practices say "Use low for speed-sensitive or
simple tasks". The attendant's work is short: a greeting, a product's price
and stock, a store fact, a reservation, a decline. The clinical boundary is
the part where capability matters most, and the evals measure it (FR-09:
the `boundary` suite at 100 %).

## Options

1. **Medium, as ADR-0003 set it.**
2. **Low.**
3. **Low, raised per message for the hard turns.** The per-message effort
   keeps the cache, but something must tell a hard turn from an easy one
   before the model reads it, and a turn at the clinical boundary is the
   one where a wrong guess costs most; a classifier would add its own wait
   and its own mistakes.

## The measure

Every eval case of the MVP through the app's own pipeline, the `boundary`
suite three times, four runs one after the other from one machine,
alternating medium, low, low, medium (2026-11-15, 20:17 to 20:39 UTC; the
runs' records are kept outside the repository):

| | Medium | Low |
|---|---|---|
| Cases passed | 33 of 33, both runs | 33 of 33, both runs |
| `boundary` attempts passed | 77 of 78 (the one failure is the judge reading the system's fixed emergency line as the attendant's words) | 78 of 78 |
| A turn: median, p90 (124 turns each) | 3.70 s, 5.47 s | 3.44 s, 4.87 s |
| Output tokens a call, of them thinking (means) | 180, 65 | 145, 34 |
| The attendant's dollars a run | US$ 0.446 | US$ 0.377 |

Paired over the same turns, each low run took 0.89 to 0.91 times a medium
run's seconds, every 95 % interval below 1 (0.84 to 0.96), while two runs at
the same effort differed by 0.2 and 0.6 % (intervals 0.95 to 1.05 and 0.94
to 1.07). The visible text is about the same at both levels, 110 to 115
tokens a call: effort moved the thinking, not the length of the reply.

## Decision

Option 2. `ModelPolicy`'s normal route runs Claude Opus 5.5 at `low`
effort; the economy route and the judge stay at `medium`. The owner chose
it on 2026-11-15, from the measure above.

## Consequences

- A turn takes about a tenth less time and the normal route's calls cost
  about a sixth less, on what the evals hold; the first real conversation
  after the change tells whether real turns, which wrote longer replies,
  move as much.
- Capability is traded for it, as the provider says. The evals are the
  guard: the `boundary` suite at 100 % stays the release floor, and a
  failure at low effort that medium passes reopens this decision.
- The committed scorecard is the run of `3e89c51`, at medium, until M4's
  close (M4-6) runs it again at low.
- ADR-0003's other choices stand: the models, the modes and the budget's
  gates.
