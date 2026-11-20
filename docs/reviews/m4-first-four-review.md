# The review of M4's first four slices: every line left for the owner, and what became of it

The review at a close of
[ADR-0019](../adr/0019-the-review-at-a-close-and-four-amendments-to-the-review-policy.md),
run in slice M4-6a (design §9.2) on 2026-11-19 over two sets of lines: those
the MVP review's own pull requests left (#36 to #42, which
[`mvp-review.md`](mvp-review.md) does not hold) and those of M4's first four
slices (#44, #45, #47 and #48; #46 changed only documents). Each pull
request's Review section stays the record of its own review; this file is
the record of the close, one row per line, generated once from its ledger
and read through by hand.

How it ran:

1. **The ledger:** 101 lines from the twelve Review sections (#36 to #48),
   each with its kind and where its recommendation sent it.
2. **The triage against the code** at `8fbdb83`, by one read-only agent: of
   17 recommended changes that named a destination already past, 15 were
   made, each cited at its line, and one more was read by hand; one was
   not made (#40's twelfth line, a standing trigger still open). Of 21 items
   for later, 11 are named in the plan, 9 were accepted by the threat model
   or ADR-0020 since, and 1 had no home (#47's C5).
3. **The close's extra finder** (ADR-0019's fourth amendment) read five
   fixes made after their pull request's last review instrument, one test,
   and the production code earlier finders named as unread: two claims,
   one of them a claim #48's verifier had already judged.
4. **No new verifier:** every dismissal and every reach on the risk list
   (#40, #41, #42, #45, #47, #48, and #39's dismissals) had been judged by
   its pull request's verifier; the lines that only their author judged
   (#36, #37, #38, #39 and #44) touch no money, privacy, data or security.
   The extra finder's first claim is a phrase list, which a red test
   settles, so by the owner's rule he was asked first and chose to fix it
   without a verifier; its second is #48's C7 and H2 again.
5. **The owner decided once,** in four questions: the lots as recommended,
   a slice of its own for the fixes (M4-6b, before Turnstile), no fallback
   line for a delete command (#48's H4), and the bare "sim, pode" anchored
   on its verb.

The interface review, the eval audit and the docs reader test were not run:
M4 closes when M4-5 lands, in block 2 (ADR-0022), and they run there. The
extra finder did not reach six of the Telegram path's spec files example by
example, three files of the evals' command line, and two of Solid Queue's
process files; the owner was told.

How to read a row: *Pull request* is where the line was written (`close`
for the extra finder's own claims); *Line* is the id that pull request's
Review section gave it (`—` where it gave none); *What it said* is the line
cut to one clause; *Outcome* names where it went.

| Outcome | Rows |
|---|---|
| To fix in M4-6b | 13 |
| Made | 16 |
| Closed before the review | 4 |
| Planned | 13 |
| Accepted in the documents | 9 |
| Read by the close's extra finder | 10 |
| Kept | 28 |
| Noted | 9 |
| Dismissed | 4 |
| **All** | **106** |

## To fix in M4-6b (13)

The owner gave these a slice of their own, the next one, before Turnstile (M2-1).
All thirteen were fixed there, in pull request #52, each with its failing
example first; its Review section and design §10's note of M4-6b are their
record. #48's V5 turned out not to occur as it was read (the note says why);
the run is counted first all the same.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #48 | — | C1 stop the pass over earlier unread updates at the first still unread after its read | to fix in M4-6b (the owner's word, 2026-11-19) |
| #48 | — | C3/H5 classify the earlier turn's command before building its processor; hold when unclassifiable; give_up keeps no reply while an earlier deletion has none | to fix in M4-6b (the owner's word, 2026-11-19) |
| #48 | — | C5/H6 given-up update: read chat and line, strip with update_columns, then send | to fix in M4-6b (the owner's word, 2026-11-19) |
| #48 | — | C6/H8 rescue broadcast_reply's reads after commit; broken leaves a turn with its reply | to fix in M4-6b (the owner's word, 2026-11-19) |
| #48 | — | C7/H2 given-up update's line sent through `sending` | to fix in M4-6b (the owner's word, 2026-11-19) |
| #48 | — | V5 count the run first; deletion? false for an unreadable body | to fix in M4-6b (the owner's word, 2026-11-19) |
| #48 | — | H3 delivered: pass the turn's id, load inside the rescue | to fix in M4-6b (the owner's word, 2026-11-19) |
| #48 | — | H4 no fallback line for a delete command; does "never given up" cover an update that never became a turn (owner's call) | to fix in M4-6b: no fallback line for a delete command; the "try again" of one never read stays (the owner's word, 2026-11-19) |
| #48 | — | H9 close_interrupted with the same rescue as every span write | to fix in M4-6b (the owner's word, 2026-11-19) |
| #48 | — | fix review sisters: span closed in the status's own write (or sweep closes); unreadable loads message.turn outside rescue | to fix in M4-6b (the owner's word, 2026-11-19) |
| close | C1 | the bare "sim, pode" in three boundary cases fails a correct "e sim, pode reservar" | to fix in M4-6b, anchored on the verb, no verifier (the owner's word, 2026-11-19) |
| close | C2 | since 828ad32 a given-up update's line goes and tell logs "its line not sent" (= #48's C7/H2) | the same claim as #48's C7 and H2 (teorico, #48's verifier); to fix in M4-6b with it |
| close | C2s | sister: sending writes "replies not sent" after the fixed line went | with #48's C7 and H2, in M4-6b |

## Made (16)

Read in the code at `8fbdb83`, the line cited in the triage's report.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #36 | — | SR-03: four kinds of answer lacked Rails' default headers and Permissions-Policy; owner SIM; fix in first server PR | made in #40 |
| #39 | — | AdvisoryLock.acquire ends its wait with a rollback, not a commit (timeouts lifted inside eval attempts) | made in #40 |
| #39 | — | SR-27 sentence: v2 score when no v3/v4 | made in #42 |
| #39 | — | "never on duty" rule on every reply of every case | made in #41 |
| #39 | — | boundary-pt-01 rubric: decline in one or two sentences, store facts and offer may follow (owner's word) | made in #42 |
| #40 | — | H6 reply and turn state in one transaction (#11 V2) | made in #48 |
| #41 | — | C3/H1 deletion at dead letter writes a line naming it, keeps no reply, run again | made in #48 |
| #41 | — | H2 "deleted all the same" line after erase! | made in #48 |
| #41 | — | H3 third part: stranded deletion run by the sweep | made in #48 |
| #41 | — | final "¿" read as a question mark at the close | made in #42 |
| #41 | — | FR-02 clause: conversation opened by a reset or after 24 h takes ... language | made in #42 |
| #41 | — | R1 hold later turns on any break of an earlier deletion | made in #48 |
| #45 | — | V4 trace reads "mensagem enviada" for every stored reply | made in #48 |
| #47 | — | C6 stored reply attempts count non-Telegram errors; fail at third | made in #48 |
| #47 | — | fix review sister: lock lost with connection; named in R11 | made in #48 (threat model R11) |
| #47 | — | flaky seed 9419: nightly spec Solid Cache expiry_method :job (pulled in #48) | made in #48 |

## Closed before the review (4)

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #40 | — | Postgres log settings applied by reboot (done 2026-11-15) | done on 2026-11-15, the demo's database rebooted (#41's session) |
| #42 | — | NFR-01 first measure; effort sweep at M4's first slice (done, ADR-0021) | measured in M4-2 (#45); the normal route at low effort (ADR-0021) |
| #42 | — | question 20's reading (answered in M4-2) | answered in M4-2 (#45, design §10) |
| #48 | — | V2 closed by C2's fix | closed by #48's fix of C2 |

## Planned (13)

Named in design §9.2 or a standing trigger of §10.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #36 | — | NFR-10's 300 KB read as compressed transfer when the gate is set at M3 | planned in M3-5 |
| #38 | — | aria-relevant=additions on three live regions at M5, with a screen reader's test | planned in M5-5 |
| #39 | — | rubrics for boundary-pt-02 and boundary-es-02 at M5's growth to fifteen boundary cases | planned in M5-4 |
| #39 | — | injection-hostile-product-name-01 list and rubric agree | planned in M2-4 |
| #40 | — | non-text YAML key raises ArgumentError in sort | §10's standing trigger, still open: `config/commands.yml` changed in #42, before the trigger was written |
| #40 | — | robots.txt and static files' cache | planned in M3-6 (the rehearsal flow) |
| #41 | — | H5 cause: nil on Telegram::Client's three raises | planned in M3-4 |
| #41 | — | sisters and notes; keep; on-duty list grows at M5 Spanish review if a run shows one | planned in M5-3 (the Spanish review pass) |
| #42 | — | X1 Action Cable error lines write the error's message | planned in M3-4 |
| #42 | — | X2/V1 token under /api/trace/<token> or a prefix unmasked | planned in M3-4 |
| #42 | — | judge's reason without double quotes or retried, at M5's calibration | planned in M5-4 |
| #42 | — | reader test leftovers: from-zero setup at M5 README; terms at M5/M3 runbook | planned: the README half in M5-6; the runbook's terms given to M3-6 (the owner's word, 2026-11-19) |
| #47 | — | C5 Openers#check refuses commands but not agreement phrases | given a home: §10's standing trigger for `config/openers.yml` (the owner's word, 2026-11-19) |

## Accepted in the documents (9)

Accepted by the threat model or ADR-0020 since the line was written.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #40 | — | C2 Puma low-level 500 and Thruster 502 lack SR-03 set; lowlevel_error_handler at M3 (later accepted by ADR-0020) | accepted in SR-03 and ADR-0020 |
| #40 | — | C4 Thruster's proxy-error line may name a path with a token; one SR-30 sentence at M3 | accepted in SR-30 and ADR-0020 |
| #40 | — | H1 webhook first-refusal line and alert at eleven unwritten while cache fails; M3 SR-30 review | accepted in SR-30 and ADR-0020 |
| #40 | — | H2 "not counted" line names StatementInvalid without cause; a flood writes ~4 lines/request; name cause chain, one line a minute at M3 | accepted in SR-30 |
| #42 | — | IpSpoofAttackError message quotes address headers; M3 SR-30 | accepted in SR-30 and ADR-0020 |
| #42 | — | deploy spec examples reach real docker; a docker shim for every example | accepted in ADR-0020 |
| #42 | — | R1 registry_left? reads any failed inspect as gone | accepted in threat model R11 and ADR-0020 |
| #42 | — | R2 a failed volume read ends the script before docker is asked | accepted in threat model R11 and ADR-0020 |
| #42 | — | X3 sister: drawer turn focus; keyboard check at M5's NFR-10 gate | accepted in threat model R11 and ADR-0020 |

## Read by the close's extra finder (10)

ADR-0019's fourth amendment: what earlier reports named as unread, and fixes made after a pull request's last review instrument.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #39 | — | finder unread: agent_runner.rb and spec files | read by the extra finder (M4-6): `agent_runner.rb` and its history, no defect; the specs sampled |
| #41 | — | finder unread: specs, lib/evals judge/report/scorecard/pipeline, history.rb, TelegramUpdateJob | read by the extra finder (M4-6): `lib/evals` and the runner's history, no defect; the specs scanned only |
| #42 | — | extra finder did not reach: specs of #17 #29 #32 #33, 677291a, GlassBox.tsx, prerender RateContext, #29 state readers, bin/evals and lib/evals as callers, #41 specs | read in part by the extra finder (M4-6): the glass box, the rate's context, `bin/evals` and `lib/evals`, no defect; the specs not reached |
| #45 | R1 | 7c9e8f3 fixed after fix review, unreviewed | read by the extra finder (M4-6): `7c9e8f3`, no defect |
| #47 | — | finder gaps: buttons_spec, chat_spec, typing_spec, openers_spec | not reached by the extra finder (M4-6): scanned only |
| #47 | R1 | 828ad32 fixed after fix review, unreviewed | read by the extra finder (M4-6): `828ad32`, one claim, XF-C2 |
| #48 | — | finder gaps: six specs via diffs, retry_on exhaustion, solid_queue fail_all_with/prunable, Telegram::Client NETWORK, intake.rb | read in part by the extra finder (M4-6): Active Job's and Solid Queue's exhaustion paths, no defect; the specs sampled |
| #48 | — | 5ff927d test added after fix review | read by the extra finder (M4-6): `5ff927d` asserts what it claims |
| #39 | — | 90fb2ad fixed after the verifier's second step, never reviewed | read by the extra finder (M4-6): `90fb2ad`, one claim, XF-C1 |
| #40 | — | 204690f and f84dfea fixed after the fix review, never reviewed | read by the extra finder (M4-6): `204690f` and `f84dfea`, no defect |

## Kept (28)

The line's recommendation was to keep it as it is.

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #36 | — | three details past owner's words (FR-02 detector, FR-05 third attempt, FR-19 three fields); keep (Q35 later reversed the detector) | kept (the owner's word, 2026-11-19, on the lot) |
| #37 | — | file response cut after 10 s stalled write; accept | kept (the owner's word, 2026-11-19, on the lot) |
| #38 | — | refused message's new text; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #38 | — | thread a tab stop at 390 px; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #38 | — | Korean IME in Safari Enter 229; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #38 | — | two lint rules off for one line each; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #38 | — | 320 px clip past ~33 chars; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #39 | — | D1 after_commit inside a not-joinable attempt; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #40 | — | C3 EdgeLimits.count rescues every StandardError; keep (owner's words) | kept (the owner's word, 2026-11-19, on the lot) |
| #40 | — | H5 skipped purge reads 0; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #40 | — | finder B notes; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #40 | — | finder A note slow confirmations reconnect; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #40 | — | search exception narrowed; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #40 | — | fix review's notes; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #41 | — | H4 allowed_updates compared in order; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #41 | — | a refusal ends with the emergency line, not the offer; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #41 | — | agreement as written ("Concordo 👍" no longer agrees); keep | kept (the owner's word, 2026-11-19, on the lot) |
| #41 | — | confirmation retries on 4xx and 429 wait unread; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #41 | — | on-duty rule would fail a correct negation; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #42 | — | C3's other reading on reset language vs page switch; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #44 | — | psql by hand keeps jit on; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #45 | — | C2 latency written after sent mark; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #45 | — | C3 deploy overlap loses a figure; keep (query given) | kept (the owner's word, 2026-11-19, on the lot) |
| #47 | — | finder's notes: markup refusal; label language; greeting before deploy | kept (the owner's word, 2026-11-19, on the lot) |
| #47 | — | fix review sisters: confirmation drain race keep; IOError/Timeout; SystemCallError as network | kept (the owner's word, 2026-11-19, on the lot) |
| #48 | — | V1 delivery span broadcast even when its row was not written; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #48 | — | C8 second half: row waits while reply on its way; keep | kept (the owner's word, 2026-11-19, on the lot) |
| #48 | — | finder's six notes; keep | kept (the owner's word, 2026-11-19, on the lot) |

## Noted (9)

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #37 | — | Thruster SIGTERM and idle connections rest on recall; none needed | noted |
| #38 | — | 2a reproduction for 18-L-notsent green on main as written; for the close's table | noted |
| #38 | — | GlassBox.test.tsx flaky once; a timing test to watch | noted: §10's standing trigger for its next failure |
| #40 | — | notes on how rows were read | noted |
| #41 | — | judge failed boundary-en-01 attempt 3 against its own reason; the close's run shows whether it recurs | measured: `boundary-en-01` passed its three attempts in M4-6's scorecard |
| #41 | — | prompt's emergencies list names self-harm | noted |
| #42 | — | two Docker lines were the session's own | noted |
| #45 | — | PR-10's §10 note is history | noted |
| #47 | — | V3 perform_now with retry_on passes on first attempt; write tests that assert state | noted |

## Dismissed (4)

| Pull request | Line | What it said | Outcome |
|---|---|---|---|
| #39 | D2 | "You are" vs "You aren't" in injection-prompt-extract-01; verifier: not real | dismissed: not real (that pull request's verifier) |
| #45 | C1 | trace root ends at stored reply; verifier: not real | dismissed: not real (that pull request's verifier) |
| #48 | C4 | parts_sent write fails on third try; verifier: not real | dismissed: not real (that pull request's verifier) |
| #48 | H10 | AND order in AdvisoryLock::TRY; not real; CASE in anyway | dismissed: not real (that pull request's verifier) |
