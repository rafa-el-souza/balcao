# Balcão

> An AI attendant for a neighbourhood pharmacy, on the web and on WhatsApp,
> built to be used, watched and audited.

**Try it** (live from the MVP, about two weeks of work after the first commit): `https://balcao.rafasouza.dev.br` — talk to the attendant of *Farmácia
Vida Longa* (a fictional pharmacy) and watch, beside the chat, every model
call, tool call, token and cent it took to answer you.

*Português:* Balcão é um atendente de IA para uma farmácia de bairro
fictícia. Ele consulta estoque, reserva produtos, agenda serviços, encaminha
para o farmacêutico quando a pergunta é clínica, e mostra ao lado da
conversa tudo o que fez para responder. *Español:* Balcão es un asistente de
IA para una farmacia de barrio ficticia: consulta stock, reserva productos,
agenda servicios, deriva al farmacéutico cuando la pregunta es clínica y
muestra junto al chat todo lo que hizo para responder.

## What it does

- Answers in Portuguese, English or Spanish, whichever you write.
- Looks up stock and prices, reserves products for pickup, books in-store
  services into a live calendar (bookings after the MVP).
- Refuses clinical advice (doses, interactions, diagnoses) and points to
  the human pharmacist — a boundary checked by an eval suite at 100% and,
  after the MVP, re-checked on every reply by a second, cheaper model (the
  glass box shows it).
- Answers on WhatsApp too; voice notes after the MVP.
- Shows the **glass box**: a live trace of your conversation with model,
  tools, latency, tokens and cost.
- Runs unattended under a monthly budget cap; after the MVP the cap gains
  three levels (normal, economy on a cheaper model, paused) and a daily
  slice that keeps one bad day from eating the month.

## How it is built

Ruby on Rails 8 API · React + TypeScript (Vite) · PostgreSQL · Solid Queue
and Solid Cable (no Redis) · Anthropic Claude via the official Ruby SDK ·
WhatsApp Cloud API · Kamal 2 on one small VM.

Read, in this order:

1. [`docs/design.md`](docs/design.md) — goals, numbered requirements with
   acceptance scenarios, architecture (C4 diagrams), data model, interfaces,
   operations, delivery plan.
2. [`docs/adr/`](docs/adr/README.md) — the decisions and their reasons.
3. [`docs/threat-model.md`](docs/threat-model.md) — what could go wrong on a
   public endpoint and what stops it.
4. [`evals/`](evals/README.md) — the executable specification of the
   conversation, and the [scorecard](evals/scorecard.md).

Every requirement identifier (FR-07, SR-16, …) is cited by the tests, CI
steps or runbook checks that cover it (`docs/traceability.md`, generated
at each milestone close from M2). Pull requests that change code are
reviewed before merge by the project's own read-only finder agent, with an
independent verifier on the risk list; the policy is
[ADR-0013](docs/adr/0013-review-policy-own-finder-verifier-reach-triage.md)
and each pull request's Review section is the record.

## Status

Design complete and independently reviewed (2026-11-02, 30 findings;
2026-11-04, the amended deploy model, the bot gap and the testing strategy;
2026-11-09, the twelve-day MVP plan, all applied); implementation starting
with the MVP (design §9.1). See the delivery plan in the design document.

## Running locally

To be written in the MVP's first days: `bin/setup`, `bin/dev`,
`bin/deploy`, and how to run with the fake model (no API key needed for the
test suite); `bin/evals` on day 8.

## Licence

MIT (design document OD-4, resolved 2026-11-04).
