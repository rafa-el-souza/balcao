# ADR-0003: Opus 5.5 by default, Haiku 5.5 as economy mode, three-level budget

**Status:** accepted; the budget gates are extended by ADR-0012 (daily slice, per-source limits, challenge) · **Date:** 2026-11-02

## Context

The author's Console plan includes a monthly API credit (US$ 200 at the time
of writing); the owner's cap for this project is US$ 100/month with credit,
US$ 10 without. Demo conversations are short; quality of judgement at the
clinical boundary matters more than price per token. A public endpoint can
be driven by scripts, so spend must be bounded by code, not by hope.

Prices at the time of writing (first-party API, verify before changing the
price table): Opus 5.5 US$ 4 / 20 per million input / output tokens, cache
reads US$ 0.20; Haiku 5.5 US$ 0.10 / 0.50. A typical turn (cached system
prompt ~3k tokens, ~2k conversation tokens in, ~300 out, adaptive thinking)
costs roughly one to two US cents on Opus and well under a tenth of a cent
on Haiku.

## Options

1. **Opus 5.5 everywhere.** Best judgement; US$ 100 buys on the order of
   a few thousand short conversations once cache writes are counted; a
   script could burn it in a day without caps.
2. **Haiku 5.5 everywhere.** Cheapest; weaker at nuanced refusals and
   trilingual tone; no server-side refusal fallback.
3. **Opus by default, Haiku when spend nears the cap, pause at the cap.**
   Quality while affordable, graceful degradation, a visible demonstration
   of model tiering and budget engineering.

## Decision

Option 3. Model policy lives in one place (`app/agent/model_policy.rb`):

| Mode | Trigger | Model | Effort |
|---|---|---|---|
| normal | default | `claude-opus-5-5` | medium |
| economy | spend ≥ 70% of monthly cap, or forced | `claude-haiku-5-5` | medium |
| paused | spend ≥ 100% of cap, or forced | none; static reply | — |

Plus a per-visitor cap (40 turns / 24 h, 10 per minute) and a per-minute
rate; **ADR-0012 (2026-11-04) adds a daily slice of the cap, per-IP
limits and a challenge at session creation**, because the per-visitor cap
alone is defeated by minting identities. The cap is a configuration value (default US$ 100; set to 10 when
running without credit). The Console spend limit is set below the
application cap as an independent fence. The canary uses the economy model
always.

**Spend metering.** Computed from the API usage fields of every call
(model turns, guardrail checks, transcription minutes) and
a dated price table in configuration with these columns per model: input,
output, cache write (creation), cache read; plus the
transcription price per minute. Cache writes matter at demo traffic: the
default cache lifetime is short, so a conversation that starts after a
quiet spell pays a ~3k-token cache write before its first cached read.
Realistic model cost per short conversation is therefore closer to
US$ 0.05–0.08 on Opus, not the per-turn figure alone; the status page
reports the measured number.

**Economy mode gate.** The full eval run writes `economy_allowed` to the
committed file `evals/economy_allowed.yml`, which the app reads at boot: economy mode may serve only while the boundary suite last
passed at 100% on the economy model; otherwise reaching 70% goes straight
to `paused`.

## Consequences

- The status page and the trace show the mode and the model, so a visitor
  can see the degradation happen; that is a feature.
- Prompt caching is per model, so a mode switch costs one cache miss;
  negligible at this volume.
- The eval suite runs against both models; the boundary suite must pass at
  100% on both, or economy mode is not allowed to serve (it pauses instead).
- The price table must be re-verified when models or prices change; the
  table carries its verification date and the status page shows it.
