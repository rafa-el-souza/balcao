# Balcão

[![The demo, online or offline](https://img.shields.io/website?url=https%3A%2F%2Fbalcao.rafasouza.dev.br%2Fup&label=demo&up_message=online&down_message=offline)](https://balcao.rafasouza.dev.br)
[![CI on main](https://img.shields.io/github/actions/workflow/status/rafa-el-souza/balcao/ci.yml?branch=main&label=CI)](https://github.com/rafa-el-souza/balcao/actions/workflows/ci.yml?query=branch%3Amain)
[![The clinical boundary's eval cases, as last committed](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fraw.githubusercontent.com%2Frafa-el-souza%2Fbalcao%2Fmain%2Fevals%2Fscorecard.md&search=%5C%7C%20boundary%20%5C%7C%20%5Cd%2B%20%5C%7C%20(%5Cd%2B%2F%5Cd%2B)&replace=%241&label=clinical%20boundary%20evals)](evals/scorecard.md)

> An AI attendant for a neighbourhood pharmacy, on the web and on Telegram,
> built to be used, watched and audited.

**Try it:** [balcao.rafasouza.dev.br](https://balcao.rafasouza.dev.br), live
— talk to the attendant of *Farmácia Copaíba* (a fictional pharmacy) and
watch, beside the chat, every model call, tool call, token and cent it took
to answer you. On Telegram the same attendant is
[@BalcaoDemoBot](https://t.me/BalcaoDemoBot).

*Português:* Balcão é um atendente de IA para uma farmácia de bairro
fictícia. Ele consulta estoque, reserva produtos, encaminha para o
farmacêutico quando a pergunta é clínica, e mostra ao lado da conversa tudo
o que fez para responder (agendamento de serviços, em breve). *Español:*
Balcão es un asistente de IA para una farmacia de barrio ficticia: consulta
stock, reserva productos, deriva al farmacéutico cuando la pregunta es
clínica y muestra junto al chat todo lo que hizo para responder (reserva de
servicios, próximamente).

## A sixty-second tour of the code

Follow one message from the chat to its reply. Each stop starts at a file
whose opening comment says what it does and why.

1. **It arrives.** The request is first counted against rate limits, per IP
   address and per visitor
   ([`app/models/edge_limits.rb`](app/models/edge_limits.rb)). Then
   [`app/controllers/api/messages_controller.rb`](app/controllers/api/messages_controller.rb)
   validates the message, stores it once however often the browser sends it,
   queues a job and answers at once; the reply will come over a WebSocket.
   From Telegram,
   [`app/transports/telegram/webhook.rb`](app/transports/telegram/webhook.rb)
   checks the secret Telegram sends before it reads the update, and
   [`app/transports/telegram/inbound.rb`](app/transports/telegram/inbound.rb)
   asks a new person to agree before anything of theirs is kept.
2. **A job takes it.**
   [`app/jobs/process_turn_job.rb`](app/jobs/process_turn_job.rb) runs the
   turn (a message and everything done to answer it), one at a time per
   conversation, in order, through
   [`app/models/turn_processor.rb`](app/models/turn_processor.rb), which
   answers a command itself and hands anything else to the model's runner
   (the next stop). When something breaks it tries three times in all, then
   sends a fallback reply: the visitor is never left waiting. On Telegram,
   [`app/transports/telegram/outbound.rb`](app/transports/telegram/outbound.rb)
   then sends the stored reply to the chat, as plain text and in order.
3. **The model is called.**
   [`app/agent/agent_runner.rb`](app/agent/agent_runner.rb) runs the official
   Anthropic SDK's tool loop inside three limits: six tool calls, 1,500
   output tokens per model call, sixty seconds in all.
   [`app/agent/model_policy.rb`](app/agent/model_policy.rb) is the one place
   that names a model: Claude Opus 5.5, and Claude Haiku 5.5 as the cheaper
   model of the budget's economy mode.
4. **The prompt draws a line.**
   [`app/agent/system_prompt.rb`](app/agent/system_prompt.rb) holds the
   attendant's instructions, nothing secret among them, and the rule that
   matters most: no clinical advice, which is the pharmacist's to give. The
   `boundary` cases of [`evals/cases.yaml`](evals/cases.yaml) are evals
   (evaluations: a scripted message, with what a right reply must and must
   not say). They put that rule to both real models in three languages,
   the [scorecard](evals/scorecard.md) is the last run's result, and the
   cheaper model may serve only while it passed every one of them, which
   the run writes to [`evals/economy_allowed.yml`](evals/economy_allowed.yml).
5. **A tool does the work.**
   [`app/agent/tools/create_reservation.rb`](app/agent/tools/create_reservation.rb)
   takes nothing on the model's word: it checks every argument itself, and
   however often a turn is retried, its reservation is made once.
   [Its tests](spec/agent/tools/create_reservation_spec.rb) prove both.
6. **Every step is recorded.**
   [`app/models/trace_recorder.rb`](app/models/trace_recorder.rb) stores each
   model call, tool call and reply as a span in OpenTelemetry's shape, with
   attributes from an allow-list only, so no secret and no identity can ride
   along. The way back to the page is a WebSocket:
   [`app/channels/conversation_channel.rb`](app/channels/conversation_channel.rb)
   streams the reply and each span to the conversation's own visitor, and
   [`web/src/chat/GlassBox.tsx`](web/src/chat/GlassBox.tsx) draws the spans
   as they happen in the glass box, the panel beside the chat.
7. **Every call is paid for, and capped.**
   [`app/models/budget.rb`](app/models/budget.rb) charges each model call to
   the month and the day at the dated prices of
   [`config/prices.yml`](config/prices.yml), moves new turns to the cheaper
   model once the month passes 70 % of its cap or the day its slice, and
   pauses the demo with a fixed reply once the month's spend reaches its
   cap, before any further model call, telling the operator through the
   bot; the glass box shows each call's cost in dollars and reais.
8. **It runs on one small VM.** [`config/deploy.yml`](config/deploy.yml) says
   what runs there, the [`Dockerfile`](Dockerfile) builds it and
   [`ops/cloud-init.yml`](ops/cloud-init.yml) sets up the host.

The ids in those files (FR-07, SR-16) are numbered requirements: functional
(FR) and non-functional (NFR) in the [design document](docs/design.md),
security (SR) in the [threat model](docs/threat-model.md). The stops are
what is built so far, and [Status](#status) says how far that is. Not at
home in a Rails repository? [Where things live](#where-things-live) says
what each folder holds.

## What it does

- Answers in Portuguese, English or Spanish, whichever you write.
- Looks up stock and prices, reserves products for pickup, books in-store
  services into a live calendar (bookings after the MVP, the minimum viable
  product: the first version, which is the one live now).
- Refuses clinical advice (doses, interactions, diagnoses) and points to
  the store's pharmacist with a fixed line of phone and counter hours, or,
  when a message may be an emergency, to SAMU's 192 and the poison line —
  a boundary checked by an eval suite at 100% and re-checked on every
  reply by a second, cheaper model, which replaces a reply that gives
  clinical advice with that decline (the glass box shows each check).
- Answers on Telegram too, since WhatsApp's business policy rules out a
  pharmacy without a licence
  ([ADR-0016](docs/adr/0016-telegram-bot-api-as-the-messaging-channel.md)),
  and as a plain text channel on purpose, with a few plain buttons: a
  reservation's code to copy, the trace to open, and the suggested first
  messages under the greeting
  ([ADR-0017](docs/adr/0017-the-telegram-bot-stays-a-text-channel.md));
  voice notes after the MVP.
- Shows the **glass box**: a live trace of your conversation with model,
  tools, latency, tokens and cost.
- Runs unattended under a monthly budget cap with three levels (normal,
  economy on a cheaper model, paused) and a daily slice that keeps one bad
  day from eating the month; at the cap the bot tells the operator.

## How it is built

Ruby on Rails 8 API · React + TypeScript (Vite) · PostgreSQL, whose trigram
and full-text search find the catalogue's products (no vector store) · Solid Queue
and Solid Cable (no Redis) · Anthropic Claude via the official Ruby SDK ·
Telegram Bot API · Kamal 2 on one small VM.

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
little about this one; `app/agent/`, `app/transports/`, `evals/`, `ops/`,
`web/` and `docs/` are the project's own. What each holds:

- [`app/controllers/`](app/controllers) — the HTTP endpoints: the JSON API
  under `api/`, and the controller that sends the web app's pages.
  [`config/routes.rb`](config/routes.rb) lists every URL and the code behind
  it.
- [`app/jobs/`](app/jobs) — work done outside a request, four jobs: the one
  that answers a message (`process_turn_job.rb`), the Telegram bot's two,
  which read an update and send a reply that had to wait
  (`telegram_update_job.rb`, `telegram_reply_job.rb`), and the nightly reset
  of the demo's data (`nightly_reset_job.rb`).
- [`app/transports/`](app/transports) — the Telegram bot's side: the
  webhook, the Bot API client, what an update makes of the conversation, how
  a reply leaves for the chat, and the task that sets the bot's webhook,
  command menu and profile.
- [`app/agent/`](app/agent) — everything that talks to the model: the runner,
  the system prompt, the model policy, the tools, and the fake model the
  tests run on.
- [`app/models/`](app/models) — the database's tables as classes
  (conversation, message, turn, product, reservation) and, beside them, plain
  Ruby classes with no table behind them, which hold the app's rules, such
  as [`turn_processor.rb`](app/models/turn_processor.rb): one turn, from a
  message to its reply.
- [`app/channels/`](app/channels) — the WebSocket side: the streams that
  carry each reply and each trace span to the page, and the gate that limits
  the open sockets.
- [`config/`](config) — settings: the pharmacy's facts in `store.yml`, the
  rate limits' rules in `initializers/rack_attack.rb`, the deploy in
  `deploy.yml`, the server's texts in three languages under `locales/`.
- [`db/`](db) — [`schema.rb`](db/schema.rb) is the database at a glance;
  `seeds/catalogue.yml` is the invented catalogue.
- [`spec/`](spec) — the server's tests. It mirrors the folders of `app/` (the
  endpoints' tests are under `requests/`) and adds checks on the deploy
  files, the cloud-init file and the CI. Each test says first which
  requirement or design section it proves.
- [`web/`](web) — the React and TypeScript app: `src/chat/` is the chat and
  the glass box, `src/trace/` the trace page, `src/landing/` the landing,
  `src/privacy/` the privacy page.
  Tests sit beside what they test; `test/` holds the checks on the build as
  a whole, and `e2e/` the accessibility and size gate over the built pages.
- [`evals/`](evals) and [`lib/evals/`](lib/evals) — the conversation's cases,
  and the runner that plays them against the real model; CI replays a
  fast subset from its recordings, with no key.
- [`docs/`](docs) — the design, the decision records (ADRs), the threat model
  and the runbook; `prototype/` holds the screens as static HTML, which the
  React follows.
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
at each milestone close from M2; the ones a step, a CI step or a
measurement covers say where in [`docs/traceability.yml`](docs/traceability.yml)). Pull requests that change code are
reviewed before merge by the project's own read-only finder agent, with an
independent verifier on the risk list; the policy is
[ADR-0013](docs/adr/0013-review-policy-own-finder-verifier-reach-triage.md)
and each pull request's Review section is the record.

## Status

Design complete and independently reviewed (2026-11-02, 30 findings;
2026-11-04, the amended deploy model, the bot gap and the testing strategy;
2026-11-09, the twelve-day MVP plan, all applied). **The MVP is complete**
(design §9.1), closed on 2026-11-15 after a review of all its pull requests
([`docs/reviews/mvp-review.md`](docs/reviews/mvp-review.md),
[ADR-0019](docs/adr/0019-the-review-at-a-close-and-four-amendments-to-the-review-policy.md)):
the demo answers at the address above, on the web and on Telegram. The
review read the 367 lines that the reviews of the pull requests had left
for the owner: 74 were fixed, 10 changed a requirement's sentence instead
of the code, 45 wait in a later milestone or for a decision, 10 were read
again by one more reviewer, and the other 228 were accepted, kept by the
owner's word, already made, measured or dropped (the table has each line);
ADR-0019 adds four rules to the review policy. What each day brought:

- **Day 2:** the demo host at the address above, with TLS.
- **Day 5:** a conversation over the HTTP API.
- **Day 6:** the landing and the chat page, in three languages.
- **Day 7:** the reply and the glass box's rows live over the cable, a
  trace page per conversation, "pensando…" while a turn runs, and a turn
  that breaks tried again twice, then answered with the fallback, never
  left waiting.
- **Day 8:** reservations for pickup until the end of the next business
  day, once per turn and product however often the turn runs, refused for
  a prescription product, more than ten units, a fourth open reservation
  or more than the stock.
- **Day 9:** the clinical boundary at 100% of its eval cases, the
  pharmacist's offer as a fixed line, every model call charged to the month
  at a dated price table, a fixed reply at the monthly cap, and the nightly
  reset of the stock and deletion of what is older than seven days.
- **Day 10:** the privacy page, which is also the bot's own policy.
- **Day 11:** the Telegram bot takes messages in, asks a new person to
  agree before it keeps anything of theirs, and what visitors send is
  encrypted at rest.
- **Day 12:** the bot answers in plain text, with the typing status;
  `/trace` sends the conversation's trace page; the bot has its own command
  menu and profile in three languages, and the landing's QR opens it.

Done since the MVP (M4's first four slices): a turn's latency, which the
first real conversation measured above its target, is measured and cut;
the bot has its buttons; and a sweep, every minute, answers a message left
without a reply, or gives it a fixed line (design §10). A review of those
four slices and of the MVP review's own pull requests read the 101 lines
they left for the owner: 16 already made, 10 fixed in the next slice with
the review's own two findings, the rest kept, planned or accepted
([`docs/reviews/m4-first-four-review.md`](docs/reviews/m4-first-four-review.md)).
Then the first slice of what publishing needs: a new web visitor is created
only after Cloudflare Turnstile, a check that a visitor is a person, which
the chat runs as it opens and which only asks a person to tick a box when
Cloudflare wants one (threat model SR-39). And a second model now reads
every reply the first one writes and replaces one that gives clinical
advice with the fixed decline, keeping the prices and reservations the turn
found (FR-20); on 464 replies of earlier eval runs it replaced none, and it
caught all 24 clinical replies written to test it. The cheaper model the
budget falls back to now runs the same evals, and the judge of their
rubrics reads the system's fixed lines (the notice, the pharmacist's offer,
the emergency numbers) as the system's, since it once took the emergency
line for a method the reply named: on the last full run the cheaper model
met the clinical boundary in every case, so the file that lets it serve is
open. Ten prompt-injection eval cases now try what a visitor is likely to
throw at the demo, chosen from about sixty attacks run against both models,
none of which worked; the one slip the attacks found, a reservation the bot
counted several times when a visitor asked for separate ones, is fixed.
The clinical boundary's eval cases then grew from 13 to 33, from a study of
the Brazilian norms, which give the pharmacist the orientation on a
medicine's benefit and risk, use, storage and adverse reactions, and say
that a blood pressure taken at a pharmacy is never a diagnosis: the prompt
and the second model's check now name what a medicine is for, how to use
and store it and what a reading means, a medicine for an animal goes to a
veterinarian, and the bot never judges an amount someone took, after a new
case found it telling a visitor that an overdose "may be dangerous". On the
full run that followed, both models met all 33. Then the bot's memory of a
conversation: it rereads its earlier replies as it wrote them and the
reservations it made, so it no longer doubts a reservation code it gave,
and none of the system's fixed lines, which it once took for its own;
where the system answered for it, one sentence says so, and a product it
looked up before is looked up again, since the stock may have changed. A
reply the second model replaces now lists only the products the visitor
named, and an emergency's opens with the call for help. On the full run
that followed, both models met the whole boundary and every injection case
again; the cheaper model failed one reservation case by asking which of two
products the visitor meant, as it does one time in five on the code before
this change too. A review of those seven slices read the 84 lines they left
for the owner and added 17 of its own: 10 already made, 20 fixed in the
next slice (among them the bot's memory of a reservation when the system
answered for it, and a note the bot sometimes wrote to itself before
looking something up, which reached visitors; a line of the prompt, chosen
of seven measured, stopped it, and the evals now fail one), the rest kept,
planned or accepted
([`docs/reviews/m2-first-seven-review.md`](docs/reviews/m2-first-seven-review.md)).
Then the budget's modes: past 70 % of the month's cap, or once a day's
spend reaches its slice of the cap, new turns go to the cheaper model, and
while that model may not serve the demo pauses instead, until midnight for
a day; at the cap the bot sends the operator one line, to a chat the
operator links by opening a one-time link a command prints. Then the
canary: every ten minutes the app asks its own attendant where the
pharmacy is, through the same path as a visitor's message and on the
cheaper model, and tells an external monitor whether the answer came in
time, or whether the visitors' own recent turns all failed; beside it, a
look at the bot's webhook tells the monitor when Telegram fails to
deliver. The monitor also e-mails when either goes silent.
Then a turn's hard edge: every model call and tool of a turn fits in its
sixty seconds, a call the edge cuts is charged as the provider bills it,
and the app reaches its database as a role that reads and writes rows and
nothing else. Then CI's furniture: the fast evals replayed from their
recordings with no key, and a gate of accessibility and size over the four
public pages. Then the runbook was completed for the move to production:
the operator's checklist, roll back, the rotations of every secret, the
rehearsal hosts and the cut itself, with each container limited in memory
and CPU, the visitor cookie made one that only the demo's own host can
set, and the fictional pharmacy renamed Farmácia Copaíba, after a check
found its old name on a real company and on a stranger's Telegram bot.

Next, in two blocks (design §9.2, where a milestone's number is a label for
its content, not its place in the order;
[ADR-0022](docs/adr/0022-what-publishing-the-demo-needs-first-the-showcase-after.md)
says why):

- **First, what publishing the demo needs:** the rehearsal hosts' own
  mode, and production on a host of its own (until then the demo runs on
  the rehearsal host). The demo is publicised the day it moves there.
- **Then the showcase:** voice notes; service bookings and their calendar;
  the operator's console and a conversation handed over to a person; the
  status page; three example traces kept as files, a count of where
  visitors come from, the landing's final copy, a review of the Spanish
  texts and the README's final tour.

Design §9.2 lists the 40 slices of that plan in order, and
[ADR-0020](docs/adr/0020-what-v1-leaves-out-the-plan-after-the-mvp.md)
says what V1 leaves out and why: backups of fictional data, an OpenAPI
document, a workflow for the full eval run and a push service among them.

## Running locally

You need Ruby and Node.js at the versions in `.tool-versions` (mise or asdf
read that file), PostgreSQL 18 running locally and reachable by your own
user (no password, no `DATABASE_URL`), and Git. The test suite needs no
secret: it never calls the model or any outside service. A conversation in
development calls the real model, with the `ANTHROPIC_API_KEY` of the shell
that starts `bin/dev`: a paid Anthropic API key of your own, a cent or two
a turn. `bin/setup` ends by starting `bin/dev`, so export the key first, or
run `bin/setup --skip-server` and start `bin/dev` once it is set. Without
the key the chat still opens, and every turn ends, after its three attempts
(some twenty seconds), in the fallback reply. The chat's anti-bot check
loads Cloudflare's Turnstile script there too, with Cloudflare's published
test keys, which always pass.

```sh
bin/setup   # installs gems and npm packages, enables the secret-scan
            # pre-commit hook, prepares the databases, then starts bin/dev
bin/dev     # Rails on 127.0.0.1:3000 and the Vite dev server on
            # 127.0.0.1:5173; open http://127.0.0.1:5173
bin/ci      # the CI set, locally: RuboCop, bundler-audit, Brakeman,
            # RSpec, the recorded evals, npm audit, ESLint, Prettier,
            # TypeScript, Vitest, the web build, the accessibility and
            # size gate, actionlint and gitleaks
```

One suite at a time: `bundle exec rspec`, and `npm test` inside `web/`.
`bin/ci` expects `gitleaks` and `shellcheck` on your `PATH`; `bin/setup`
installs actionlint at the release `bin/actionlint` pins, and `npm run
e2e:browser` inside `web/` installs the browser the accessibility and size
gate runs in.

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
