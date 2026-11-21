# Architecture decision records

One file per decision that someone could reasonably question, in MADR
format: context, options considered, decision, consequences. Status is
`proposed`, `accepted`, `superseded by ADR-xxxx` or `deprecated`. From the
first commit of this repository, the decision text of an accepted ADR never
changes: a decision changes by writing a new ADR, and the old one's status
line gains the pointer ("superseded by", "extended by").

| Id | Title | Status |
|---|---|---|
| [0001](0001-rails-api-and-react-spa.md) | Rails API with a React SPA in one repository | accepted; its sentence on the OpenAPI document amended by ADR-0020 |
| [0002](0002-whatsapp-cloud-api-over-unofficial-clients.md) | Official WhatsApp Cloud API over unofficial clients | accepted; the Cloud API superseded by ADR-0016 (the rejection of unofficial clients stands) |
| [0003](0003-model-policy-opus-default-haiku-economy.md) | Opus 5.5 by default, Haiku 5.5 as economy mode, three-level budget | accepted; extended by ADR-0012; the normal mode's effort amended by ADR-0021 |
| [0004](0004-web-first-whatsapp-parallel-lane.md) | Web channel first, WhatsApp on a parallel lane | accepted; the lane amended by ADR-0016 |
| [0005](0005-voice-transcription-provider.md) | Voice note transcription through a hosted speech-to-text API, behind a port | accepted; the provider measurement becomes ADR-0014 at M4 |
| [0006](0006-single-vm-kamal-solid-stack.md) | One VM, Kamal 2, Solid Queue/Cable/Cache, no Redis | accepted; deploy consequence superseded by ADR-0011 |
| [0007](0007-public-design-docs-adrs-threat-model.md) | Design doc, ADRs, threat model and evals are public | accepted |
| [0008](0008-no-styled-component-library.md) | No styled component library; design tokens first, headless primitives allowed | accepted |
| [0009](0009-no-retrieval-augmented-generation.md) | No retrieval-augmented generation in V1 | accepted |
| [0010](0010-trace-recorder-shaped-after-opentelemetry.md) | Trace recorder shaped after OpenTelemetry; SDK adoption deferred | accepted |
| [0011](0011-rehearsal-destination-and-human-only-production-deploys.md) | Rehearsal destination, production VM from M3, human-only production deploys | accepted; amended 2026-11-09 (the `ensaio` destination serves the demo until M3); its words on the demo's secrets amended by ADR-0016; its operator account on a VM of its own since ADR-0023 |
| [0012](0012-daily-budget-slice-per-ip-limits-and-turnstile.md) | Daily budget slice, per-IP limits and Turnstile at session creation | accepted; amended 2026-11-09 (Turnstile in M2's first slice, which the ADR calls "the first slice after the MVP"); its WhatsApp line amended by ADR-0016 |
| [0013](0013-review-policy-own-finder-verifier-reach-triage.md) | Review policy: the project's own finder, a verifier on risk-list PRs, triage by reach, the PR as the record | accepted; the risk list amended by ADR-0016; extended by ADR-0019 |
| [0015](0015-cable-limits-at-the-gate-and-in-the-driver.md) | The cable's limits: a gate before the takeover, a size in the driver, a count per connection | accepted; its sentence on the 21st command amended by ADR-0019 |
| [0016](0016-telegram-bot-api-as-the-messaging-channel.md) | Telegram's Bot API as the messaging channel | accepted; extended by ADR-0017 |
| [0017](0017-the-telegram-bot-stays-a-text-channel.md) | The Telegram bot stays a text channel: one update type in, plain text out | accepted; its question on the operator's alert answered, and the place of the bot's finish in M4 amended, by ADR-0020 |
| [0019](0019-the-review-at-a-close-and-four-amendments-to-the-review-policy.md) | The review at a close, and four amendments to the review policy | accepted |
| [0020](0020-what-v1-leaves-out-the-plan-after-the-mvp.md) | What V1 leaves out: the plan after the MVP, cut to what the demo needs | accepted; its order and the operator chat's link amended by ADR-0022 |
| [0021](0021-the-normal-route-at-low-effort.md) | The normal route at low effort | accepted |
| [0022](0022-what-publishing-the-demo-needs-first-the-showcase-after.md) | What publishing the demo needs comes first, the showcase after | accepted |
| [0023](0023-the-operator-account-on-a-vm-of-its-own.md) | The operator account on a VM of its own | accepted |

Two numbers are reserved and have no file yet: 0014 for the
transcription provider's measurement at M4 (ADR-0005), and 0018 for the
data a pharmacy would hand Balcão (the data contract, which the owner
writes; design §10).
