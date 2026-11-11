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

Ruby on Rails 8 API · React + TypeScript (Vite) · PostgreSQL, whose trigram
and full-text search find the catalogue's products (no vector store) · Solid Queue
and Solid Cable (no Redis) · Anthropic Claude via the official Ruby SDK ·
WhatsApp Cloud API · Kamal 2 on one small VM.

Versions, current stable when the implementation started (2026-11-09):
Ruby 4.0.9 and Rails 8.1.4.1; PostgreSQL 18; Node.js 26 LTS; React 19.3,
Vite 8.3 (Rolldown), TypeScript 6.0, Vitest 5.1, i18next 27; RSpec 8.1
(rspec-rails); the `anthropic` gem 2.8, verified on 2026-11-11 with the model
ids and request parameters it uses (design §6.4). Two tools sit one major behind on purpose: TypeScript 6.0,
because typescript-eslint does not support TypeScript 7 yet, and ESLint 9,
because `eslint-plugin-jsx-a11y` does not support ESLint 10 yet. The
`.tool-versions` file pins Ruby and Node for local work and CI.

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
2026-11-09, the twelve-day MVP plan, all applied). The MVP is being built
(design §9.1): since day 2 the demo host serves a placeholder page at the
address above, with TLS; the chat arrives on day 6. See the delivery plan in
the design document.

## Running locally

You need Ruby and Node.js at the versions in `.tool-versions` (mise or asdf
read that file), PostgreSQL 18 running locally and reachable by your own
user (no password, no `DATABASE_URL`), and Git. No API key and no secret:
development and the test suite never call the model or any outside service.

```sh
bin/setup   # installs gems and npm packages, enables the secret-scan
            # pre-commit hook, prepares the databases, then starts bin/dev
bin/dev     # Rails on 127.0.0.1:3000 and the Vite dev server on
            # 127.0.0.1:5173; open http://127.0.0.1:5173
bin/ci      # the CI set, locally: RuboCop, bundler-audit, Brakeman,
            # RSpec, npm audit, ESLint, Prettier, TypeScript, Vitest, the
            # web build, actionlint and gitleaks
```

`bin/setup --skip-server` prepares without starting the servers. One suite
at a time: `bundle exec rspec`, and `npm test` inside `web/`. `bin/ci`
expects `actionlint` and `gitleaks` on your `PATH`.

`bin/deploy -d ensaio` deploys the demo host and nothing else; it needs that
destination's env file and SSH key, and production is never deployed from
here ([`docs/runbook.md`](docs/runbook.md), ADR-0011). `bin/evals`, which
runs the conversation against the real model with a key of your own,
arrives on day 8 of the MVP.

## Licence

MIT (design document OD-4, resolved 2026-11-04).
