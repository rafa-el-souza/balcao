# Architecture decision records

One file per decision that someone could reasonably question, in MADR
format: context, options considered, decision, consequences. Status is
`proposed`, `accepted`, `superseded by ADR-xxxx` or `deprecated`. From the
first commit of this repository, the decision text of an accepted ADR never
changes: a decision changes by writing a new ADR, and the old one's status
line gains the pointer ("superseded by", "extended by").

| Id | Title | Status |
|---|---|---|
| [0001](0001-rails-api-and-react-spa.md) | Rails API with a React SPA in one repository | accepted |
| [0002](0002-whatsapp-cloud-api-over-unofficial-clients.md) | Official WhatsApp Cloud API over unofficial clients | accepted; the Cloud API superseded by ADR-0016 (the rejection of unofficial clients stands) |
| [0003](0003-model-policy-opus-default-haiku-economy.md) | Opus 5.5 by default, Haiku 5.5 as economy mode, three-level budget | accepted; extended by ADR-0012 |
| [0004](0004-web-first-whatsapp-parallel-lane.md) | Web channel first, WhatsApp on a parallel lane | accepted; the lane amended by ADR-0016 |
| [0005](0005-voice-transcription-provider.md) | Voice note transcription through a hosted speech-to-text API, behind a port | accepted; the provider measurement becomes ADR-0014 at M4 |
| [0006](0006-single-vm-kamal-solid-stack.md) | One VM, Kamal 2, Solid Queue/Cable/Cache, no Redis | accepted; deploy consequence superseded by ADR-0011 |
| [0007](0007-public-design-docs-adrs-threat-model.md) | Design doc, ADRs, threat model and evals are public | accepted |
| [0008](0008-no-styled-component-library.md) | No styled component library; design tokens first, headless primitives allowed | accepted |
| [0009](0009-no-retrieval-augmented-generation.md) | No retrieval-augmented generation in V1 | accepted |
| [0010](0010-trace-recorder-shaped-after-opentelemetry.md) | Trace recorder shaped after OpenTelemetry; SDK adoption deferred | accepted |
| [0011](0011-rehearsal-destination-and-human-only-production-deploys.md) | Rehearsal destination, production VM from M3, human-only production deploys | accepted; amended 2026-11-09 (the `ensaio` destination serves the demo until M3) |
| [0012](0012-daily-budget-slice-per-ip-limits-and-turnstile.md) | Daily budget slice, per-IP limits and Turnstile at session creation | accepted; amended 2026-11-09 (Turnstile in the first slice after the MVP); its WhatsApp line amended by ADR-0016 |
| [0013](0013-review-policy-own-finder-verifier-reach-triage.md) | Review policy: the project's own finder, a verifier on risk-list PRs, triage by reach, the PR as the record | accepted; the risk list amended by ADR-0016 |
| [0015](0015-cable-limits-at-the-gate-and-in-the-driver.md) | The cable's limits: a gate before the takeover, a size in the driver, a count per connection | accepted |
| [0016](0016-telegram-bot-api-as-the-messaging-channel.md) | Telegram's Bot API as the messaging channel | accepted |
