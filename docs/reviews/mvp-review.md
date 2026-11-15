# The MVP review: every line left for the owner, and what became of it

ADR-0013 leaves two kinds of line in each pull request for the owner, read
in one batch at each close: the claims the author dismissed, each with its
reason, and the `teorico` findings, each with a recommendation. At the MVP
close (2026-11-15) the pull requests merged until then held 326 such lines;
the triage and the close's own instruments (the interface review and its
verifier, the eval audit, the docs reader test) added 41. This file is the
record of that review, one row per line, generated once from its ledger and
read through by hand.
[ADR-0019](../adr/0019-the-review-at-a-close-and-four-amendments-to-the-review-policy.md)
is its method and the four amendments it made to the review policy.

How it ran:

1. Every line was read against the code at `84554da`; 67 had already been
   made.
2. The owner answered 51 questions, which covered 67 lines, each with one
   recommendation, and gave one word to each of four lots: accept or keep
   (137 lines), a home in the plan (38), fix at the close (51), drop (7).
3. Six pull requests applied the answers: #36 (the documents), #38 (the
   page), #39 (the evals and checks), #40 and #41 (the server), and #42,
   which closes the MVP and writes this table.

| Outcome | Rows |
|---|---|
| Fixed | 74 |
| Amended (a requirement's sentence) | 10 |
| Planned (a milestone, or a standing trigger) | 44 |
| Measured | 1 |
| Waits for the data-contract ADR | 1 |
| Reviewed by the close's extra finder | 10 |
| Kept (the owner's word on a question) | 16 |
| Accepted | 137 |
| Closed before the review | 67 |
| Dropped | 7 |
| **All** | **367** |

How to read a row: *Pull request* is where the line was written (`close`
for the close's instruments, `triage` for what the triage itself found);
*Line* is the id that pull request's Review section gave it (`—` where it
gave none); *What it said* is the line cut to one clause; *Outcome* names
the pull request that fixed it, the requirement whose sentence changed, the
milestone that carries it, or the owner's question, numbered as he answered
them.

## Fixed (74)

Changed by one of the six pull requests that followed the decisions.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #1 | — | The web parity test imports the three locale files rather than deriving them from i18n resources | fixed in #38 |
| #1 | — | The web locale parity test compares keys, not {{placeholders}} | fixed in #38 |
| #1 | R6 | Which CVSS version "above low" means | fixed in #39 (question 18) |
| #7 | C7 | identity_hash is not checked to be a 64-character lowercase hex digest | fixed in #40 |
| #8 | D-N2 | A non-string YAML key raises ArgumentError rather than Invalid | fixed in #40 (question 39) |
| #8 | D-N5 | The fact checks are Portuguese-formatted exact substrings and saturday_hours reads the closing time only | fixed in #39 |
| #8 | D-N8 | "apagar meus dados" followed by an emoji is not a command | fixed in #41 (question 36) |
| #9 | — | A language tag in capitals or as [pt-BR] shows raw to the visitor | fixed in #41 |
| #10 | — | "losartana 100 mg" finds nothing | fixed in #40 (question 38) |
| #11 | C4 | A command that raises is never marked failed and its span closes without error.type, so /trace is re-run by … | fixed in #40 |
| #14 | — | After a language switch, the back-forward cache can show the previous page in the old language | fixed in #38 |
| #14 | — | Safari reports isComposing false on the Enter that ends an IME composition, so that Enter sends | fixed in #38 (question 45) |
| #14 | — | A 422 (an opener removed while a tab stayed open) or a 409 offers a retry that the server refuses every time | fixed in #38 |
| #18 | — | Every reveal scrolls smoothly whatever prefers-reduced-motion says | fixed in #38 |
| #18 | — | The "não enviada" line inside the last message is not brought into view | fixed in #38 |
| #18 | — | At 1280 px a thread long enough to scroll is a scrollable region that cannot take the keyboard's focus | fixed in #38 |
| #20 | C6 | An eval key skipped until M2 counts as a rule key, so a boundary case with only that key is judged by the … | fixed in #39 |
| #20 | — | Inside the eval attempt's transaction the app's own transaction blocks join it instead of nesting, so a … | fixed in #39 |
| #20 | — | The eval's visitor starts in Portuguese, so a system-written reply without a language tag … | fixed in #41 (question 35) |
| #23 | C5 | The browser's client re-sends a subscribe every 0.5 s until confirmed, so a confirmation 10 s late makes an … | fixed in #40 (question 26) |
| #25 | — | No spec reads the README's links, so a file moved later breaks one silently | fixed in #39 |
| #26 | — | No spec holds the README's third badge's pattern to the scorecard's row | fixed in #39 |
| #26 | — | At the MVP close, weigh whether the README needs an update (the owner's word of 2026-11-14) | fixed in #36 |
| #27 | C4 | A block that opens with a line tag before the language tag shows the visitor "[pt]" and reads no language | fixed in #41 |
| #27 | FN1 | The emergency line comes only from the model's tag, so a refused, failed or timed-out turn gets the decline … | fixed in #41 (question 33) |
| #27 | FN6 | A refusal of a non-clinical message gets a decline that names the pharmacist and the phone | fixed in #41 (question 33) |
| #27 | — | A message about self-harm gets the emergency line (192 and the poison line), but CVV (188) is the service for … | fixed in #41 (question 34) |
| #28 | J2 | J2 holds a booking, which ships at M2 | fixed in #36 |
| #28 | — | "The first slice after the MVP" names two slices | fixed in #36 |
| #29 | — | The price table is read on first use, after the first model call is paid | fixed in #40 |
| #29 | S5 | One purge DELETE past the 5 s statement timeout fails the nightly job, and the stock reset after it | fixed in #40 |
| #29 | S9 | The JSON log formatter matches a tag before scrubbing it, so a tag with bytes that are not UTF-8 would raise | fixed in #40 |
| #29 | V1w | " ms", " s", "k" and the " · " separators are written in code, not in the locale files | fixed in #38 |
| #29 | — | The pause's text in three languages says "this month's limit" for a pause the operator forced too | fixed in #40 (question 37) |
| #30 | C4 | A turn that fails for good leaves a failed execution in Solid Queue whose error message is stored as raised … | fixed in #40 (question 21) |
| #31 | C1 | The catalogue search spec's eightfold bound between 50 and 200 products misses a small square term | fixed in #40 |
| #31 | V1 | The spec measures only "dipirona", which matches exactly, so the close and partial paths never run in the … | fixed in #40 |
| #32 | D-L2 | telegram:setup exits 0 whatever getWebhookInfo reports | fixed in #41 (question 27) |
| #32 | M4 | Solid Cache's failsafe swallows six error classes without logging the class, and any other cache error raises | fixed in #40 (question 30) |
| #32 | — | The limit counters' purge runs on the cache database before the catalogue reset, so a cache outage at 03:00 … | fixed in #40 |
| #33 | C8 | The deletion's confirmation is lost if the send breaks with a non-client error after erase! commits, with no … | fixed in #41 |
| #33 | H3 | A 5xx in Telegram's JSON fails the reply at once, as FR-19's text says, while an HTML 5xx is retried | fixed in #41 (question 29) |
| #33 | R1 | A reply that is not stored (the deletion's confirmation, the ask, the fixed lines) is tried once, so one blip … | fixed in #41 (question 25) |
| #33 | R3 | The three send attempts count per reply, not per part, so a long reply whose parts each meet a 429 fails at … | fixed in #41 |
| #35 | — | Money and duration strings join figure and unit with a plain space, so "R$" parts from its figure at 320 px | fixed in #38 |
| close | EA-1 | The boundary floor of 100% rests on 12 cases run once: a model that holds on 95% of attempts shows 12/12 in … | fixed in #39 (question 46) |
| close | EA-2 | Some boundary must_not_include phrases fail a correct decline that echoes or negates them | fixed in #39 (question 47) |
| close | EA-8 | The eval prices nothing: console and results carry tokens only, though config/prices.yml exists since PR-16 | fixed in #39 |
| close | EA-O1 | Spanish replies mix "usted" in the model's words | fixed in #41 (question 48) |
| close | IR-OC2 | The composer's resting edge (--color-rule #b3c8b5) is about 2.8:1 against the paper outside it and 3.2:1 … | fixed in #38 (question 42) |
| close | IR-S2 | The 390 px bar's accessible name always ends with "abrir a caixa de vidro", also while the drawer is open and … | fixed in #38 |
| close | IR-U1 | When the first session request fails at load (network, 5xx, timeout, or a 429 at the edge), the composer … | fixed in #38 |
| close | IR-V1 | A price in the attendant's reply breaks between "R$" and its figure at 390 px with no zoom | fixed in #38 (question 44) |
| close | IR-V2 | A retry after the cookie is lost mints a new visitor, and the stored message's id then answers 409 on every … | fixed in #38 |
| close | IR-W1 | At 390 px the glass box's one-line bar does not wrap and nothing clips it … | fixed in #38 |
| close | IR-W11 | The glass box's rows list has no live region | fixed in #38 |
| close | RB-1 | The runbook uses "the development account", "the workstation", "both accounts", "the rehearsal project" … | fixed in #36 |
| close | RB-2 | The runbook's bump day is a list of reviews | fixed in #36 |
| close | RB-4 | No runbook section starts from "the monitor says the demo is down" | fixed in #36 |
| close | RB-5 | The runbook's smoke conversation names the three API requests but gives no command line | fixed in #36 |
| close | RM-1 | README Status still says "The MVP is being built" while it lists day 12 | fixed in #42 |
| close | RM-2 | README "Try it" keeps the forecast "live from the MVP, about two weeks of work after the first commit" and … | fixed in #36 |
| close | RM-3 | The README's Portuguese and Spanish summaries say it books services now … | fixed in #36 |
| close | RM-4 | The README tour names no file for the way back to the page (the reply and spans over the cable) nor how … | fixed in #36 |
| close | RM-5 | README Running locally does not say the key is a paid Anthropic key, nor that bin/setup starts bin/dev, so … | fixed in #36 |
| close | RM-6 | README "Where things live" names two jobs | fixed in #36 |
| close | RM-7 | README terms used before they are explained that cost the reader an answer | fixed in #36 |
| close | RM-8 | README tour stop 2's "the visitor is never left waiting" fails in the runbook's bump-day reboot of Postgres … | fixed in #36 |
| triage | — | The nightly job seeds the catalogue before the plain-body encryption sweep, so a seed failure skips the sweep … | fixed in #40 |
| triage | — | The deletion phrase asked as a question ("apagar meus dados?") deletes at once with no confirmation | fixed in #41 (question 36) |
| triage | — | The runbook's bump-day step reboots the Postgres accessory while the web and job containers keep serving | fixed in #36 |
| triage | — | config/database.yml's comment points at conversation_lock.rb for the SET LOCAL that lives in advisory_lock.rb | fixed in #40 |
| triage | — | The runbook says Dependabot proposes new digests for the Postgres accessory, while dependabot.yml covers only … | fixed in #36 |
| triage | — | spec/rails_helper.rb still lists Meta among the services the suite fakes | fixed in #40 |

## Amended (10)

A requirement's sentence changed instead of the code.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #9 | D-C2s | A retry that starts before the deadline runs its step's full timeout | amended: SR-20 (question 22); its fix planned for M3 |
| #9 | — | The refused seventh tool call emits no tool event | amended: FR-12 (question 4) |
| #11 | C1s | An earlier turn that failed with no reply is skipped, the later turn's model answers both messages, and the … | amended: design §6.3 (question 23) |
| #18 | — | When an earlier turn breaks again inside the later turn's job, its next attempt answers it after the later … | amended: design §6.3 (question 23) |
| #19 | N1 | At the cap the reply lists the visitor's open reservations from any conversation of theirs, and the trace … | amended: FR-12 (question 10) |
| #29 | C4 | FR-12 says cost in BRL "at a configured rate with its verification date" | amended: FR-12 (question 19) |
| #32 | R2 | The webhook's answers, a Rack endpoint's, lack Rails' default headers and the Permissions-Policy | amended: SR-03 (question 31) |
| #32 | T7 | FR-19 says a body that is not an update is "counted" | amended: FR-19 (question 28) |
| #33 | W1q | Whether NFR-10's AA contrast covers forced colours | amended: NFR-10 (question 32) |
| #34 | — | Whether CSS-only pull requests take the lean visual review as a rule | amended: ADR-0019 (question 15) |

## Planned (44)

Given a home in design §9.2, at a milestone, or in §10, as a standing trigger.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #1 | — | .githooks and SR-38: bin/setup in the operator checkout would turn on repository hooks | planned for M3 |
| #1 | — | The skill's zizmor CI job was not added | planned for M3 |
| #1 | F6 | WebMock lives in rails_helper; a spec that requires only spec_helper, run alone, could reach the network | a standing trigger (design §10) |
| #1 | — | actionlint runs in bin/ci but not in CI until M3 | planned for M3 |
| #1 | — | A blanket eslint-disable with no rule list still mutes SR-03's rule | a standing trigger (design §10) |
| #1 | — | Whole-tree scanners (bundler-audit, npm audit) on a schedule, gating a PR only on what it introduces | planned for M3 |
| #4 | — | The app connects as the image's superuser | planned for M3 |
| #4 | FR2 | The shell has no meta description or og | planned for M5 |
| #4 | FR4 | The image spec's guard reads only line 1 and lowercase syntax | a standing trigger (design §10) |
| #4 | R4 | bin/deploy only warns and exits 0 when kamal registry remove fails after a successful setup | planned for M3 |
| #7 | RN5 | "Every inbound message has an id" lives only in record_inbound! | a standing trigger (design §10) |
| #7 | RS1 | The canary's system visitor has no marker, so the purge cannot exclude it | planned for M3 |
| #7 | RS3 | On a re-run a booking keyed by turn and slot can meet a different slot | planned for M2 |
| #8 | — | The invented address "Rua dos Boticários, 120, Floresta" and phone "(31) 1234-5678" | planned for M5 (question 13) |
| #8 | — | SR-33: a company is registered as "Farmácia Vida Longa" in another state, trading under another name | planned for M5 (question 13) |
| #11 | C3 | run_earlier rescues a connection failure and goes on | planned for M3 |
| #11 | — | A turn that kills its worker on every run holds its conversation, since every later job runs it first | planned for M4 |
| #11 | V2 | The reply is stored before the turn's state, so a run killed between the two leaves a replied turn running | planned for M4 |
| #14 | C9 | The build plugin inserts rendered text with string replacements, so $& or $' in a text would be expanded | planned for M5 |
| #14 | — | The build is about 319 KB raw, 99 KB gzip | planned for M3 |
| #18 | — | run_earlier goes on to its own turn after an earlier turn's lost connection (same as #11 C3) | planned for M3 |
| #18 | R4 | A turn left without any reply (its fallback failing too) is run again, billed, before every later message of … | planned for M4 |
| #18 | V3 | A turn left without any reply keeps pending true, so the page shows "pensando…" until the next message or a … | planned for M4 (question 24) |
| #19 | — | An operator's reply (M2) is stamped like the attendant's | planned for M2 |
| #22 | C1s | public/robots.txt also gets the year's cache, pinned on purpose by spec/requests/response_headers_spec.rb | a standing trigger (design §10) |
| #29 | C5 | formatMoney adds one decimal only, so a tiny economy call would print "US$ 0,0000" | planned for M2 |
| #29 | — | Solid Queue's "Error enqueuing recurring task" line, Solid Cache's failsafe line and Action Cable's own error … | planned for M3 |
| #29 | S1 | A charge that fails rolls back the spend with the usage records and writes no line with the amount | planned for M3 |
| #29 | S2 | An answer whose usage the pinned SDK cannot read is never charged and the job retries into more paid calls | planned for M3 |
| #29 | S6 | A malformed evals/economy_allowed.yml would answer 500 instead of pausing while economy is forced | planned for M2 |
| #29 | V4 | Solid Cache's failsafe logs an error's message (they name the database, not visitors) | planned for M3 |
| #31 | V2 | The pair subquery is pulled up, so alike is evaluated twice per pair (a constant factor) | waits for the data-contract ADR |
| #31 | — | Products tied on match, near, score and name come in plan order | waits for the data-contract ADR |
| #32 | — | An update left unread after a failure path … | planned for M4 (question 24) |
| #32 | L7 | Cannot tell: a silent reconnect inside the advisory lock's block would lose the lock | planned for M3 |
| #33 | C5 | Telegram::Chat hides its fields from inspect only | planned for M4 |
| #33 | H6 | The order wait spends a later update's first two attempts while an earlier one keeps breaking, and an update … | planned for M4 (question 24) |
| #33 | H7 | The Telegram client's rescue StandardError makes a local bug or a certificate failure look like a network … | planned for M4 |
| #33 | R4 | Under forced colours the QR's light margin is 2 modules where ISO 18004 asks 4 | planned for M5 |
| close | EA-O2 | Case balance: 26 pt, 7 en, 6 es | planned for M5 |
| close | — | Each run uses the real hour and weekday, so replies about the store being open and the pickup day follow the … | planned for M2 |
| close | — | The rubric judge (Haiku 5.5) has not been calibrated against human labels | planned for M5 |
| close | IR-OC1 | The landing has no fourth chip, "tente me enganar", which FR-21 and the §6.8 sketch specify … | planned for M2, the link at M3 (question 43) |
| triage | — | Action Cable's "Started GET /cable" line still carries the visitor's address | planned for M3 |

## Measured (1)

Measured at the close.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #29 | S8 | An attempt the turn's 60 s cut is charged zero | measured at the close (question 20, design §10) |

## Waits (1)

Waits for the data-contract ADR (0018, the owner's).

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #8 | N10 | Delivery area names are not checked for uniqueness | waits for the data-contract ADR (question 40) |

## Reviewed (10)

Parts that earlier reviews left unread, or fixes made after a fix review: read once by the close's extra finder.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #12 | NO2 | The last two fixes (R1, V4) came after the fix review and were not reviewed again | read by the extra finder (#42): no defect |
| #14 | NO2 | ff08e76, 351e732 and 85d97bb (second round of fixes) were not reviewed | read by the extra finder (#42): no defect |
| #17 | GAP | The trace-token log spec drives CableLogger with written lines, not a live subscription | read in part by the extra finder (#42): one claim, X2, planned for M3 |
| #18 | GAP | The fix review read Chat.test.tsx only to line 480 | read in part by the extra finder (#42): the test file past line 480 not reached |
| #18 | NO2 | 677291a and 945fc1b (fixes of the fix review's findings) had no review | read in part by the extra finder (#42): one claim, X3, fixed in #42 |
| #19 | NO2 | 0b4edbe (the fix of the fix review's finding) had no review | read by the extra finder (#42): no defect |
| #29 | GAP | Unread by the Rails finder: the cable's caller of EdgeLimits.over?, Intake and the messages endpoint, the … | read in part by the extra finder (#42): one claim, X1, planned for M3 |
| #30 | GAP | Unread by the finders: Postgres's own log on a constraint violation, Thruster's request log | read by #40's finder (one defect, fixed in #40) and #42's extra finder (no defect) |
| #32 | GAP | Unread by the Telegram finder: the client's, the task's, the phrases' and the fixed texts' specs, Net::HTTP's … | read in part by the extra finder (#42): the proxy, no defect; the specs not reached |
| #33 | GAP | Unread by the Rails finder: client_spec.rb, setup_spec.rb, system_prompt_spec.rb | not reached by the extra finder (#42); named in #42's Review |

## Kept (16)

The owner's word on a question kept the behaviour as it is.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #1 | F3b | Does SR-27's "toolchain advisories do not block unrelated pull requests" also cover Ruby dev and test gems? | kept (question 1) |
| #7 | N4 | A job that dies between storing a reply and sending it leaves it pending | kept (question 5) |
| #7 | R4 | A forced normal mode carried into the next month keeps the new month's economy and pause off | kept (question 2) |
| #8 | D-N3 | No upper bound on a seeded price or stock | kept (question 12) |
| #17 | N1 | The trace page says "could not load" for a 429 rather than the limit's text | kept (question 9) |
| #17 | — | The trace link's form: /trace#token instead of the drawn /trace/:token, and GET /api/trace with a header | kept (question 8) |
| #17 | — | Phrases to approve in three locales | kept (question 37) |
| #18 | C3 | Each of the job's attempts is a run with its own 60 s and six tool calls, so a turn can make up to 18 tool … | kept (question 3) |
| #18 | — | Phrases to approve in three locales | kept (question 37) |
| #23 | V2 | atacante: each junk cable command writes a log line of up to 2 KB | kept (question 11) |
| #23 | V6 | dono: a client that vanishes without FIN or RST keeps its place at the gate for about 15 minutes, so a flaky … | kept (question 11) |
| #24 | — | When a second message's 202 arrives before the first's, the second is drawn above the first until the first's … | kept (question 49) |
| #32 | D-C2 | The nightly purge restarts a limit counter still counting, at most once a week | kept (question 7) |
| #32 | T4 | Forged requests to the webhook pass no Rack::Attack rule | kept (question 6) |
| close | IR-S1 | Prices and fees reach the model already in the Brazilian format | kept (question 51) |
| close | IR-W12 | Spacing and type values outside tokens.css: "margin-bottom: 5px", "bottom: -9px" | kept (question 50) |

## Accepted (137)

The line's recommendation was to keep things as they are, or its claim had been dismissed with a reason, and the owner's word on the lot accepted that.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #1 | — | bin/bundler-audit with arguments but without check drops --config | accepted |
| #1 | — | C2's document.write part | accepted |
| #1 | — | .envrc, a root .npmrc and *.p12 are not ignored | accepted |
| #1 | — | Merge-commit diffs and commit messages possibly unscanned for secrets (cannot tell) | accepted |
| #1 | — | No pre-push hook | accepted |
| #1 | F5 | The .gitignore merge anchored log/ and tmp/ at the root, so nested ones are no longer ignored | accepted |
| #1 | — | Helpers that Vite injects into the bundle come from devDependencies and are not audited | accepted |
| #1 | — | spec/ci/brakeman_spec.rb does not run the no-answer-from-rubygems path and duplicates the CI gate | accepted |
| #1 | — | Dependabot's single actions group mixes major bumps with minor ones | accepted |
| #1 | — | The project lint rules apply to .ts/.tsx only | accepted |
| #1 | — | RSpec xit/skip/pending and Vitest .skip/.todo pass CI silently | accepted |
| #1 | V5 | The server locale parity spec reads only *.yml | accepted |
| #4 | — | The first kamal setup may restart the web container until Postgres finishes initdb | accepted |
| #4 | FR3 | With stty tostop set, Vite's first output stops it with SIGTTOU and bin/dev waits forever | accepted |
| #4 | FV3 | A stop signal between setting the traps and starting Rails is lost, and bin/dev then starts both servers | accepted |
| #4 | RV2 | bin/dev exits 0 when a server dies by a signal on its own (an OOM kill), against its comment (also FV2) | accepted |
| #7 | FV2 | A force committed after the new month's first row is not carried (sub-second race) | accepted |
| #7 | N10 | One outbound row per turn against the channel's 4,096 characters | accepted |
| #7 | N11 | A trace token collision (about 2^-140) would raise instead of retrying | accepted |
| #7 | N3 | messages.body NOT NULL against audio messages | accepted |
| #7 | N6 | Usage records cascade away with the visitor | accepted |
| #7 | N7 | The 10-unit cap is not in the schema | accepted |
| #7 | RS5 | Turn.for_inbound! and Message.record_outbound! have no owner check | accepted |
| #7 | S1 | Booking key (sister of C1): a duplicate booking | accepted |
| #8 | D-C2s | boundary-pt-02 and boundary-es-02 forbid naming a strength or a drops product in a dose answer | accepted |
| #8 | D-N1 | Two dipirona products make "reserva duas caixas" ambiguous | accepted |
| #8 | D-N6 | The FR-10 MVP note's counter hours are not in the contact topic | accepted |
| #8 | D-N7 | The threat model's MVP row said the hostile product is "in the catalogue" | accepted |
| #9 | — | The economy route's cacheable minimum | accepted |
| #11 | — | A turn whose 60 s run out between steps has no model span with error.type | accepted |
| #11 | — | TurnTrace.prompt_summary memoises the first prompt and ignores a later argument | accepted |
| #11 | — | Editing the notice in a locale file leaves older first replies with a notice the history no longer strips | accepted |
| #11 | — | "/reset" as a conversation's first message is confirmed in Portuguese | accepted |
| #11 | — | A reset's confirmation carries a turn of the old conversation, so purging that conversation deletes it | accepted |
| #12 | — | A conversation silent for 24 hours is still answered as current by the session and polling endpoints | accepted |
| #12 | — | Every RecordNotUnique under MessagesController#create maps to 409 id | accepted |
| #12 | — | MODEL_ADAPTER is checked at boot and read by nothing | accepted |
| #12 | — | The CSP's style-src self blocks inline style attributes in the server-rendered shell | accepted |
| #12 | — | The 5 s and 2 s timeouts apply to db:prepare at boot, so a migration that waits over 2 s for a lock fails the … | accepted |
| #12 | V3 | Two concurrent first increments of a new counter both write 1, so a burst from a new source loses a few counts | accepted |
| #14 | — | /chat.json answers with the chat shell (an optional format segment) | accepted |
| #14 | — | The opener is dropped if the load's session fails, because the address was already cleaned | accepted |
| #14 | — | The e-mail subject is a constant in code (the owner's identity decision) | accepted |
| #14 | — | /chat.%FF fails in the router | accepted |
| #14 | — | A refused session on a language switch says nothing | accepted |
| #14 | — | SpaController#process_action is public, but no route reaches it | accepted |
| #14 | — | /api/* and /up with an unparseable query still answer an empty 400 | accepted |
| #14 | — | A message the server stores more slowly than 15 s shows as not sent | accepted |
| #14 | — | Two /chat tabs opened at once on a first visit still mint two visitors | accepted |
| #17 | C10 | A socket still connecting is not closed by disconnect() | accepted |
| #17 | C4 | A trace lookup counts in the anonymous minute without the cookie and in the other bucket with it, so one … | accepted |
| #17 | C6 | After a reset, the old conversation's span can show in the next one's glass box for one frame | accepted |
| #17 | C8 | The connection's invalidation joins the first fetch, which has no data yet | accepted |
| #17 | D-C1 | //api/... was said to reach the API uncounted by the edge (C1, its sisters S1-S3, and V1, V2) | accepted |
| #17 | — | In development the debug-level SQL lines show the trace token inline | accepted |
| #17 | — | A trace link given before PR-11 leaves its one request in the proxy's log | accepted |
| #17 | — | A page whose subscription was refused sends, every 30 s, an unsubscribe the server no longer knows, one … | accepted |
| #18 | C4 | If the retry itself cannot be enqueued, the dead letter's line and fallback do not run | accepted |
| #19 | — | The cap's list is added on the model's reply only, not to a fallback or a decline | accepted |
| #19 | — | The stream's codes are not read by the page, which fetches on every reply | accepted |
| #19 | — | The eval cases' fix shows the request names one product, not that the model settles on it | accepted |
| #19 | — | A model that lists the held reservations anyway can only invent codes | accepted |
| #19 | — | The raise after a stock re-read that holds the units is run by no test | accepted |
| #19 | — | The over-limit refusal of reservation-too-many-pt-01 needs the tablets' stock at ten or more, which no spec … | accepted |
| #19 | — | A reservation and a deletion running at once for one visitor could deadlock … | accepted |
| #19 | — | A seed run that removes a product while one of its reservations is being made fails on the foreign key | accepted |
| #19 | — | After a seed run raises the stock between the decrement and the re-read, the tool fails the call rather than … | accepted |
| #19 | — | The code stamp's word boundary counts only ASCII letters, so a code touching an accented letter is still … | accepted |
| #19 | — | Two runs of one turn at once could meet the key only inside the transaction … | accepted |
| #20 | — | A judge call that raised after spending tokens is not in the totals | accepted |
| #20 | — | A malformed cases.yaml exits 1, which the README leaves open | accepted |
| #20 | — | The scorecard's line on the preflight assumes a rubric case was selected | accepted |
| #20 | — | Two eval runs started in the same second at one commit write one results file | accepted |
| #20 | — | tool_args: {} loads and checks nothing, and an _includes given a list always fails | accepted |
| #20 | — | The language detector cannot tell the language of the trace command's confirmations | accepted |
| #21 | FV1 | The proxy's way back reboots onto the older version by the tag the host holds, and would pull by tag if … | accepted |
| #22 | — | A request that reads no page keeps a cached /favicon.ico for up to a year after the mark changes | accepted |
| #22 | — | A turn whose last run dies without a rerun keeps the trace tab's icon dim | accepted |
| #22 | — | The finder dismissed eight candidates itself … | accepted |
| #23 | — | The token filter's pattern on a 16 KB line | accepted |
| #23 | — | A client that never reads still piles up its own pings and broadcasts | accepted |
| #23 | — | A client sending unsolicited pongs as a heartbeat is now cut | accepted |
| #23 | — | A last line ending in a rare separator got it doubled in the per-line cut | accepted |
| #23 | V4 | A routes reload in development builds a new gate with an empty count | accepted |
| #23 | V5 | A server that offered only rack.hijack_io would never have its sockets counted | accepted |
| #23 | — | The cable slice's fifteen items left out and seven accepted risks (ADR-0015's alternatives) | accepted |
| #23 | — | The race behind R2 and S1 is fixed on Rails' main branch, not on 8.1 | accepted |
| #24 | C2 | A span whose broadcast failed now waits for the next connection or load, so the glass box may show it running … | accepted |
| #25 | — | The docs reader asked for more than a tour holds (what a fallback says, where identity comes from) | accepted |
| #27 | D-C2s | boundary-pt-01's phrase check on "farmacêutic", which the fixed line carries | accepted |
| #27 | D-C3 | offered_last? compares with the newest stored reply, which for an earlier turn answered after a later one is … | accepted |
| #27 | FN2 | An emergency as a conversation's first message gets the demo notice before "call now" | accepted |
| #27 | FN3 | With the no-repetition rule, a second "quero falar com o farmacêutico" right after a reply with the line gets … | accepted |
| #27 | FN4 | An edit of config/store.yml between two turns repeats the offer line once | accepted |
| #27 | FN5 | boundary-pt-03-mixed lets "Pode dar, sim" past its phrase check | accepted |
| #29 | D-S10 | The by-hand nightly run hides a failure | accepted |
| #29 | — | An error of an anonymous class logs a nil class | accepted |
| #29 | — | During a deploy that changes the cap, the old and the new container each write their line once | accepted |
| #29 | — | A kill inside a call's own charge transaction (milliseconds) still loses that charge | accepted |
| #29 | — | Budget.mode writes on a read that finds the mode changed, so a failed write there fails that request | accepted |
| #29 | — | A poll answered before a root closed but delivered after it can overwrite the root's newer mode until the … | accepted |
| #29 | — | Test honesty: the spec that breaks a run between two calls also passed before the fix | accepted |
| #30 | — | EMAIL_SUBJECT is a constant in code (NFR-09) | accepted |
| #31 | C2 | The spec's settings cannot force which side of a join is outer, so a one-sided square search could pass | accepted |
| #31 | C3 | The spec's count sees the rows the plan reads, not work inside an expression | accepted |
| #32 | D-L3 | An absent and a wrong webhook secret share one log line | accepted |
| #32 | D-M2 | Every SR-42 drop logs one name, so a leaked secret is not told apart | accepted |
| #32 | D-N1 | The encryption migration's lock_timeout | accepted |
| #32 | — | An error raised while refusing a webhook request lets Rails' error page read the parameters | accepted |
| #32 | — | Visitor.identify! on the web has the same window as T1 (a 500, no row without consent) | accepted |
| #32 | — | While the cache does not answer, each refusal still writes the "not counted" line, and the alert cannot fire | accepted |
| #32 | L6 | perform_later's false return is ignored | accepted |
| #32 | N2 | A plain body shaped like an encryption envelope is skipped by the migration and the nightly step | accepted |
| #32 | N3 | The privacy wording "between 7 and 8 days" holds on the normal schedule | accepted |
| #32 | T9 | The agreement's span is broadcast inside its transaction | accepted |
| #32 | VT2 | A message refused by the minute limit is not counted toward the day, as on the web's edge | accepted |
| #33 | C4 | The typing thread waits at most 2 s for a status already on its way, so "typing…" can show for up to 5 s … | accepted |
| #33 | D-C6 | A body that does not decrypt is sent as its envelope | accepted |
| #33 | — | A drain that loaded its replies keeps sending them after a concurrent deletion, to the person's own chat | accepted |
| #33 | — | The migration runs under the 2 s lock_timeout during the deploy's window | accepted |
| #33 | — | Inside an over-long line, runs of spaces collapse | accepted |
| #33 | — | A fixed reply can go more than once when a read is retried | accepted |
| #33 | — | The bot's username lives in web/src/identity.ts and Telegram::Bot::USERNAME, unchecked against each other | accepted |
| #33 | — | The renamed migration kept its version, which matters only to a development database that ran the old file | accepted |
| #33 | — | An old job container could pick up a TelegramReplyJob during a rolling deploy, the reply then waiting for the … | accepted |
| #33 | — | An outage still costs a client timeout (5 to 15 s) per send under the person's lock | accepted |
| #33 | — | A fixed line overtakes a reply waiting for its time | accepted |
| #33 | — | A slow send holds the conversation's next turn for up to one timeout | accepted |
| #33 | — | Test honesty: C3's examples show no sleep but not the threads' property, H8's never runs the retry job, W1's … | accepted |
| #33 | L13 | An ok:false without error_code is logged as "()" | accepted |
| #34 | — | At 1366 x 650 the chips' second row stays below the fold | accepted |
| #34 | — | At 1440 x 790 "Como é feito" ends 39 px below the fold | accepted |
| #34 | — | On a desk the Tab reaches the e-mail button before the links of "Como é feito", which now sit higher | accepted |
| close | — | tools is an exact list in order, so store-hours-pt-01 fails a model that calls get_store_info for hours the … | accepted |
| close | — | Other text decided in code, outside t() | accepted |
| triage | — | A deletion overlapping a reservation it cannot see deletes it with its units not returned until the 03:00 seed | accepted |
| triage | — | erase! and the catalogue seed lock products in different orders | accepted |

## Closed before the review (67)

Already made in the code when the triage read it at `84554da`.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #1 | — | BALCAO_DATABASE_PASSWORD is unchecked at boot | closed before the review |
| #1 | F4 | No Rails base translations for pt-BR and es (validation messages, l(), number formats) | closed before the review |
| #1 | V3 | bin/setup enables the pre-commit hook after bundle install and npm ci, so a failed install leaves the hook off | closed before the review |
| #1 | — | A string constant declared outside JSX has no per-PR check (NFR-09) | closed before the review |
| #1 | V4 | With transactional fixtures every thread shares one Postgres session, so a two-thread advisory-lock spec … | closed before the review |
| #1 | WebV1 | The i18n.ts comment justified escapeValue false by a ban narrower than it said | closed before the review |
| #1 | WebV2 | The html lang attribute is static | closed before the review |
| #4 | — | The Postgres accessory's digest is outside Dependabot's scan | closed before the review |
| #4 | — | Kamal starts its local registry from registry:3 by tag, with no setting to pin it | closed before the review |
| #7 | C4 | A key conflict returned another visitor's reservation | closed before the review |
| #7 | C5 | The visitor cascade drops open reservations without releasing stock | closed before the review |
| #7 | C6 | Conversation.current_for! returns an open conversation however old | closed before the review |
| #7 | — | F4 of #1 became real with this PR's first validations | closed before the review |
| #7 | FV1 | Cascade deletions by the purge release no stock | closed before the review |
| #7 | FV3 | An id longer than the index tuple limit fails with a 500 | closed before the review |
| #7 | N1 | A webhook event's raw payload holds the body and the sender's identifiers | closed before the review |
| #7 | N5 | If the enqueue fails after the event is stored, the platform's redelivery is dropped | closed before the review |
| #7 | N8 | On the race path inside an open transaction Rails locks the found row FOR UPDATE | closed before the review |
| #7 | R2 | A client id is not checked for form, so ids like 1, 2 would collide across visitors | closed before the review |
| #7 | S2 | A client-chosen web id could return another visitor's message | closed before the review |
| #7 | V1 | create_once! leaves the stock decrement to the caller | closed before the review |
| #7 | V2 | Resetting stock to the seed at 03:00 frees units that open reservations hold | closed before the review |
| #8 | C5 | A store sheet with all seven days closed loads, leaving "next business day" without a bound | closed before the review |
| #8 | N4 | An opener whose text is a command phrase would let a shared /chat?say= link reset or delete on page load | closed before the review |
| #9 | C3 | AgentTool reports a successful call inside the rescue for tool bugs | closed before the review |
| #9 | — | A crashing tool's e.message is logged unmasked | closed before the review |
| #10 | C4 | search_products reads control characters as spaces but the ToolCall event keeps the raw input, and jsonb … | closed before the review |
| #10 | C5 | No statement_timeout or lock_timeout, so a tool's query waiting on a lock could hold the turn past its 60 s | closed before the review |
| #11 | C5 | A message the intake commits into the old conversation between a reset's move and its commit is answered in … | closed before the review |
| #11 | — | The /apagar confirmation exists only on the cable stream, so a polling page would miss it | closed before the review |
| #11 | — | A turn that breaks outside the model raises with no retry and no reply | closed before the review |
| #11 | V3 | A moved turn's reply goes out on the new conversation's stream while the page may still follow the old one | closed before the review |
| #12 | C4 | Solid Cache's increment answers nil when its failsafe swallows an error | closed before the review |
| #12 | C5 | The 411 branch could never fire | closed before the review |
| #12 | — | A message posted while /apagar runs can answer 500 | closed before the review |
| #12 | — | A turn that broke without a reply shows pending true | closed before the review |
| #12 | — | SR-30 names the messaging channel's user-id keys and the phone, and the log filter list has none of them | closed before the review |
| #12 | — | app/agent/agent_tool.rb logs an unexpected tool error's message, which can quote the visitor's text | closed before the review |
| #12 | — | Whether kamal-proxy forwards a path with // as is was unverified from source | closed before the review |
| #14 | C2 | Nothing compares the shells the build writes (pages x locales) with the server's routes x available locales | closed before the review |
| #14 | R4 | A slow-failing load request put the "could not open" stamp on a working page | closed before the review |
| #14 | — | A turn that broke keeps pending, so its tab polls every 3 s | closed before the review |
| #17 | C7 | A crashed run's root and its retry's tie on started_at, and array order decides which the panel shows | closed before the review |
| #17 | — | A trace link answers past the seven days | closed before the review |
| #17 | — | Action Cable's "Registered connection" line logs the visitor's identity hash and address on every connection | closed before the review |
| #17 | N2 | The trace and polling answers load every turn of the conversation, unbounded | closed before the review |
| #18 | — | A message text with a NUL would be refused by the webhook event's jsonb payload | closed before the review |
| #18 | — | Active Job's own retry lines (Retrying, Stopped retrying, Error performing) carry the error's message | closed before the review |
| #19 | C2 | The tool gives the pickup deadline as an ISO timestamp, so the model could copy the timestamp to the visitor … | closed before the review |
| #20 | C8 | The evals README's default guardrail_replaced | closed before the review |
| #20 | — | The judge's prompt puts the reply between tags without escaping them, which matters with the injection suite | closed before the review |
| #21 | — | Three finder notes became doc precisions in 63c33a0 | closed before the review |
| #24 | — | The per-IP request limit of 60 a minute was kept | closed before the review |
| #25 | — | The README's "What it does" lists the budget cap and the messaging channel in the present tense while Status … | closed before the review |
| #28 | — | The README's "Answers on Telegram too" was in the present tense before day 12 | closed before the review |
| #29 | V1r | The charge's ensure could replace the run's error | closed before the review |
| #30 | — | The logs keep a visit past seven days | closed before the review |
| #32 | — | The log's bot-token mask needs 5 digits and a 30-character key, while the boot check accepts any token | closed before the review |
| #32 | L1 | The Telegram client's errors keep the library's error as their cause, which Rake prints | closed before the review |
| #32 | M1 | give_up strips the update before it logs | closed before the review |
| #32 | M3 | A kind of content Telegram adds later would be taken for a service message | closed before the review |
| #32 | R1 | The order of a person's updates fails when the earlier one's read fails | closed before the review |
| #32 | — | An agreement read again after its strip failed names a turn, not the greeting, and each retry counts the … | closed before the review |
| #32 | — | A name=value log tag skips the token mask and the scrub | closed before the review |
| #33 | H2 | After a long 429, the person's later replies were all failed | closed before the review |
| #33 | V1 | The deletion's confirmation waited under the conversation's lock | closed before the review |
| close | EA-7 | The committed scorecard (837996c) predates the system prompt of a4e1ce9, the budget gate in the pipeline … | closed before the review |

## Dropped (7)

No change and no home, by the owner's word on the lot.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #9 | — | The history re-sends earlier replies without their language tags, which could teach the model to drop the tag … | dropped |
| #18 | C3w | If the query that builds a stored reply's stream payload fails, the outbound span closes with an error and … | dropped |
| #18 | V3w | The same with the database still down when the spans are closed leaves them open, the turn drawn as running | dropped |
| #32 | T6 | An update_id past bigint from a secret holder answers 500 | dropped |
| #32 | T8 | give_up runs outside the lock and can mark failed an update another job read | dropped |
| #33 | C7 | The status thread's death by a non-StandardError, or Thread.new raising ThreadError, would fail the turn | dropped |
| #33 | C9 | A single grapheme cluster longer than 4,096 units makes an oversized message part | dropped |
