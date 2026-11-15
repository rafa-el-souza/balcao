# ADR-0020: What V1 leaves out: the plan after the MVP, cut to what the demo needs

**Status:** accepted · **Date:** 2026-11-15 (decided with the owner in the
planning session that followed the MVP close) · Amends one sentence of
[ADR-0001](0001-rails-api-and-react-spa.md) (the OpenAPI document) and the
place of the bot's finish in
[ADR-0017](0017-the-telegram-bot-stays-a-text-channel.md), whose question on
the operator's alert it answers.

## Context

The MVP closed on 2026-11-15 (design §9.1). What remained was design §9.2:
four milestones written before a line of code existed, with the items the
MVP review had sent to each (ADR-0019). The close left three measures to
plan from:

- **The estimates.** The slices of the MVP's day table ran at about a third
  of their estimates, and the work no table held (a drawing slice, side
  slices, the review at the close) took about as long again.
- **What reviews and use found.** Of the 377 findings of the MVP's reviews,
  165 were `teorico`: no visitor, operator or attacker drives them
  (ADR-0019's context). Four defects met on the demo had passed every
  review. And the first real conversation showed what no test had: a
  catalogue search of 1.4 to 2.0 s on the host, 12 % of the conversation's
  time, against about 10 ms with the database's JIT compiler off, which
  the development database never had on (design §10, note 2026-11-15, the
  plan after the MVP).
- **The plan's own weight.** Broken into slices, §9.2 came to 39. Some
  existed for the plan's sake (a slice for a measurement, one for drawings,
  one for a card no requirement describes); some served a real pharmacy
  rather than this demo (backups of fictional data that expires in seven
  days); and some carried `teorico` findings that the owner had sent to
  the plan in one lot.

## Options

1. **§9.2 as written**: 39 slices, every item kept.
2. **Cut to what the demo needs**, keeping what a visitor sees and what a
   threat-model row rests on.
3. **Cut deeper**: also Turnstile, the two-account production deploy, voice
   notes, the exhibits, the referrer counts, the calendar's live update,
   the pharmacist's presence toggle, the console's block list, the
   third-party audit at M5.

## Decision

Option 2. Sixteen things leave V1 or change shape; §9.2 lists the 33 slices
that remain, in order.

**Services outside the application.**

1. **No workflow for the full eval run.** The full run stays local work at
   each milestone close and on the bump day, as the MVP ran it, and its
   scorecard and `evals/economy_allowed.yml` are committed by hand. CI
   holds no secret at all (threat model SR-29). Lost: a scorecard produced
   by CI rather than by the author's machine; the recorded subset that CI
   replays from M3 still proves the prompt's and the tools' contract with
   no key.
2. **No push service and no e-mail for the operator.** A handoff's alert
   and the budget's alert at the cap go through the bot to the operator's
   own chat, which the operator links once from the console; an alert
   carries a conversation id and a console link, never a visitor's words
   (FR-10, threat model SR-35). This answers the question ADR-0017 left for
   M2, and resolves design OD-2 with no provider. Lost: an alert while
   Telegram is down; the external monitor's own e-mail still says when the
   demo is.

**Slices folded into others.**

3. **ADR-0005's comparison runs inside the voice slice**, which writes
   ADR-0014 in the same pull request. The hosted API is reached through
   OpenRouter's transcription endpoint (the owner, 2026-11-15), so the two
   candidates are two models behind one key. Audio then passes two
   companies, the router and the model's provider, and `/privacy` names
   both.
4. **No drawing slice.** The calendar page and the chat's handoff states
   are drawn inside their own slices, in Portuguese, before their code, and
   shown to the owner there; the console, which no visitor sees, is built
   from design §6.8's wireframe. Lost: the independent reviews a drawing
   slice ran in the MVP.
5. **No slice for the data contract applied to what exists.** Of the three
   items that wait for ADR-0018 (design §10), the unique names of delivery
   areas go with FR-08's slice; the fenced subquery and the sku as last
   sort key wait for a real catalogue, after V1.
6. **No QR card for profiles.** The plan named it and no requirement
   describes it; the landing's receipt carries the QR and the bot's link.

**Operation beyond the demo.**

7. **No backups in V1, and no restore drill.** The data is fictional and
   expires in seven days; a dump on the VM's own disk dies with the VM
   (threat model R1); and a dump keeps for seven more days what a visitor
   asked to delete. Lost: a rehearsed restore to show, and the status
   page's counters after a migration gone wrong. A real pharmacy's
   deployment would have backups; that is its contract, not this demo
   (design §2.2).
8. **No OpenAPI document.** ADR-0001's decision said "The API contract is
   generated into `docs/openapi.yaml`". The API is six endpoints that the
   project's own page alone calls, and generating the document means
   writing its request specs again in a generator's own form. Design §6.6
   stays the contract's description.
9. **No second workflow linter in CI and no scheduled whole-tree
   scanners.** actionlint enters CI at M3 as planned; SR-27's gate stays as
   written, where a new advisory turns `main` red until the bump.
10. **No 30-second video.** The README keeps its GIF.
11. **Traceability stays a report.** `bin/traceability` writes its table at
    each close from M2; no CI gate at M5.

**Findings accepted instead of fixed** (threat model R11 and SR-30 name
them; each stays in its pull request's Review section):

12. The advisory lock not checked again after a lost connection, with
    `run_earlier` going on after one (#11, #18, #32).
13. The budget's two loose ends: a charge whose records cannot be written,
    and an answer whose usage the SDK cannot read (#29).
14. Puma's own 500 and Thruster's bodiless 502 without SR-03's headers
    (#40).
15. Log lines of Solid Cache, Solid Queue and the proxies that carry an
    error's message or a path, the address check's error line, and two
    lines never written while the cache fails (#29, #40, #42). Action
    Cable's own error lines and a trace token on another path stay in M3's
    sweep, as the owner said the same day.
16. `bin/deploy`'s two half ends, with the docker shim for its spec, and
    the glass box's focus on a window turned twice (#42).

**What stays, though it was weighed.** Turnstile: the one third party on
the page, and the defence against the abuse a public model demo draws,
free model access. The two-account production deploy: the costliest item,
and what makes "built with a coding agent that cannot reach production"
true. Voice notes, the exhibits and the referrer counts. And four smaller
ones: the calendar's live update, the pharmacist's presence toggle, the
console's block list and the third-party audit at M5.

**The order.** M4, M2, M3, M5, as before. M4 opens with two slices on a
turn's latency; the bot's finish, which ADR-0017's table calls M4's first
slice, follows them.

## Consequences

- The requirements say it: design §2.2, J3, FR-10, FR-14, NFR-03, NFR-08,
  §6.1, §6.6, §6.9, §8, §9.2 and OD-2; threat model SR-03, SR-26, SR-29,
  SR-30, SR-31, SR-35, R1 and R11; `evals/README.md`, the README and the
  runbook's opening. The MVP review's table gains a closing section for
  the rows whose outcome this changes.
- The owner's steps that go: the GitHub Environment and its secret, the
  click and the approval at every close, a push topic, an e-mail provider
  and the restore drill.
- Each cut has its way back, and its trigger is use, not the calendar: a
  real client brings backups and the contract's importer; abuse that the
  limits do not hold brings whatever it calls for; a reader who asks for
  the API's description gets the document.
- The days of §9.2's table are the estimates of 2026-11-09 and were not
  revised: they stand as a ceiling.
- M5's ADR review reads this list again.
