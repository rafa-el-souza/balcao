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

## A sixty-second tour of the code

Follow one message from the chat to its reply. Each stop starts at a file
whose opening comment says what it does and why.

1. **It arrives.** [`app/models/edge_limits.rb`](app/models/edge_limits.rb)
   counts it against the limits per address and per visitor; then
   [`app/controllers/api/messages_controller.rb`](app/controllers/api/messages_controller.rb)
   checks it, stores it once however often it is sent, queues a job and
   answers at once.
2. **A job takes it.**
   [`app/jobs/process_turn_job.rb`](app/jobs/process_turn_job.rb) answers one
   message at a time per conversation, in order. When something breaks it
   tries three times, then sends a fallback reply: the visitor is never left
   waiting.
3. **The model is called.**
   [`app/agent/agent_runner.rb`](app/agent/agent_runner.rb) runs the official
   Anthropic SDK's tool loop inside three limits: six tool calls, 1,500
   output tokens per call, sixty seconds.
   [`app/agent/model_policy.rb`](app/agent/model_policy.rb) is the one place
   that names a model.
4. **The prompt draws a line.**
   [`app/agent/system_prompt.rb`](app/agent/system_prompt.rb) holds the
   attendant's instructions, nothing secret among them, and the rule that
   matters most: no clinical advice, which is the pharmacist's to give. The
   `boundary` cases of [`evals/cases.yaml`](evals/cases.yaml) test that rule
   in three languages, and the [scorecard](evals/scorecard.md) is the last
   run against the real model.
5. **A tool does the work.**
   [`app/agent/tools/create_reservation.rb`](app/agent/tools/create_reservation.rb)
   takes nothing on the model's word: it checks every argument again, and a
   reservation asked for twice is made once.
   [Its tests](spec/agent/tools/create_reservation_spec.rb) prove both.
6. **Every step is recorded.**
   [`app/models/trace_recorder.rb`](app/models/trace_recorder.rb) stores each
   model call, tool call and reply as a span in OpenTelemetry's shape,
   carrying only the attributes on a fixed list.
   [`web/src/chat/GlassBox.tsx`](web/src/chat/GlassBox.tsx) draws them beside
   the chat as the answer is made.
7. **It runs on one small VM.** [`config/deploy.yml`](config/deploy.yml) says
   what runs there, the [`Dockerfile`](Dockerfile) builds it and
   [`ops/cloud-init.yml`](ops/cloud-init.yml) sets up the host.

The ids in those files (FR-07, SR-16) are numbered requirements: FR and NFR
in the [design document](docs/design.md), SR in the
[threat model](docs/threat-model.md). Not at home in a Rails repository?
[Where things live](#where-things-live) says what each folder holds.

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
Vite 8.3 (Rolldown), TypeScript 6.0, Vitest 5.1, i18next 27, TanStack Query 5
and the Action Cable client of the same Rails release; RSpec 8.1
(rspec-rails); the `anthropic` gem 2.8, verified on 2026-11-11 with the model
ids and request parameters it uses (design §6.4). Two tools sit one major behind on purpose: TypeScript 6.0,
because typescript-eslint does not support TypeScript 7 yet, and ESLint 9,
because `eslint-plugin-jsx-a11y` does not support ESLint 10 yet. The
`.tool-versions` file pins Ruby and Node for local work and CI.

### Where things live

Most folders are the ones Rails gives every application, so their names say
little about this one. What each holds here:

- [`app/controllers/`](app/controllers) — the HTTP endpoints: the JSON API
  under `api/`, and the controller that sends the web app's pages.
  [`config/routes.rb`](config/routes.rb) lists every address and the code
  behind it.
- [`app/jobs/`](app/jobs) — work done after a request is answered; here, the
  job that answers a message.
- [`app/agent/`](app/agent) — everything that talks to the model: the runner,
  the system prompt, the model policy, the tools, and the fake model the
  tests run on.
- [`app/models/`](app/models) — the database's tables as classes
  (conversation, message, turn, product, reservation) and, beside them, plain
  Ruby objects with the rules, such as
  [`turn_processor.rb`](app/models/turn_processor.rb): one turn, from a
  message to its reply.
- [`app/channels/`](app/channels) — the WebSocket side: the streams that take
  replies and trace rows to the page, and the gate that caps the sockets.
- [`config/`](config) — settings: the pharmacy's facts in `store.yml`, the
  deploy in `deploy.yml`, the server's texts in three languages under
  `locales/`.
- [`db/`](db) — [`schema.rb`](db/schema.rb) is the database at a glance;
  `seeds/catalogue.yml` is the invented catalogue.
- [`spec/`](spec) — the server's tests, in the folders of `app/` (the
  endpoints under `requests/`), plus checks on the deploy files, the host's
  definition and the CI. Each says first which requirement or design section
  it proves.
- [`web/`](web) — the React and TypeScript app: `src/chat/` is the chat and
  the glass box, `src/trace/` the trace page, `src/landing/` the landing.
  Tests sit beside what they test, and those of the whole build under
  `test/`.
- [`evals/`](evals) and [`lib/evals/`](lib/evals) — the conversation's cases,
  and the runner that plays them against the real model.
- [`docs/`](docs) — the design, the decisions (ADRs), the threat model and
  the runbook; `prototype/` holds the screens as static HTML, which the React
  follows.
- [`bin/`](bin) — the commands of [Running locally](#running-locally).
- [`Dockerfile`](Dockerfile), [`ops/`](ops) and
  [`.github/workflows/`](.github/workflows) — the image, the host's
  definition and the CI.

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
(design §9.1): since day 2 the demo host answers at the address above, with
TLS; since day 5 a conversation runs there over the HTTP API; since day 6 the
landing and the chat page are there, in three languages; since day 7 the reply
and the glass box's rows arrive live over the cable, polling only when the
socket is down, and each conversation has its trace page, the chat says
"pensando…" while a turn runs and that the answer is taking longer past ten
seconds, and a turn that breaks is tried again twice and then answered with
the fallback, never left waiting; since day 8 the attendant reserves products
for pickup until the end of the next business day, once per turn and product
however often the turn runs, and refuses a prescription product, more than
ten units, a fourth open reservation and more than the stock, each refusal
worded in the glass box, while the reply stamps the reservation's code. See
the delivery plan in the design document.

## Running locally

You need Ruby and Node.js at the versions in `.tool-versions` (mise or asdf
read that file), PostgreSQL 18 running locally and reachable by your own
user (no password, no `DATABASE_URL`), and Git. No secret: the test suite
never calls the model or any outside service. A conversation in development
calls the real model, with the `ANTHROPIC_API_KEY` of the shell that starts
`bin/dev`.

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
here ([`docs/runbook.md`](docs/runbook.md), ADR-0011). `bin/evals --all`
runs the conversation's eval cases against the real model, with a key of
your own in `ANTHROPIC_API_KEY`, through the app's own pipeline on the test
database (`bin/evals --list --all` shows them without a key); the last
committed result is the [scorecard](evals/scorecard.md), and
[`evals/README.md`](evals/README.md) says how to run and read it.

## Licence

MIT (design document OD-4, resolved 2026-11-04).
