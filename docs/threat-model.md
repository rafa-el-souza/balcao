# Balcão — threat model

**Status:** v1.11, 2026-11-14 (ADR-0016, the messaging channel is Telegram, and ADR-0017, what the bot uses of the platform: A2, A3, A4b, T1, T2, S2, S6, SR-06, SR-07, SR-09, SR-10, SR-12, SR-22, SR-30, SR-31, SR-32, SR-33, R2, R5 and the verification plan follow them; SR-08 retired; SR-41, SR-42 and SR-43 added; R9 accepted); v1.10, 2026-11-14 (PR-16: SR-30 says an error's message never reaches a log line and production's lines are JSON; SR-31 names the nightly job that enforces it); v1.9, 2026-11-13 (the cable slice, ADR-0015: SR-03 and SR-04 cover the cable's handshake and messages, SR-40 added, SR-32 names the cable's copies; R8 accepted); v1.8, 2026-11-13 (the edge pull request: SR-03 names the headers beside the policy, SR-27 the pinned kamal-proxy; R6 and R7 accepted); v1.7, 2026-11-09 (night: A3, SR-10, SR-12 and SR-30 cover the WhatsApp BSUID); v1.6, 2026-11-09 (the MVP amendment: A4b, SR-37, SR-38, SR-39 and R5 note the single host until M3; the verification plan has an MVP row); v1.5, 2026-11-04 (night, after three independent reviews:
SR-01, SR-02, SR-11, SR-24, SR-25, SR-26, SR-27, SR-29, SR-31, SR-37,
SR-38, R3 and the verification plan rewritten; the workstation recipe moved
to the runbook; v1.4 the same day, testing-strategy review: SR-21 names the
`injection` suite size, SR-24 and SR-26 named the hardening script, SR-38
gained a guard spec; v1.3 the same day, bot gap closed: SR-01 rewritten, SR-39 added,
SR-03 exception; v1.2 after the final independent review: SR-38
added, SR-24/25/26/29/36/37 and R5 rewritten, A4b enumerated, S10/S11
ordered; v1.1 the same day added T8, SR-37, R5 and split A4). v1 2026-11-02. Companion to `design.md`; the SR-identifiers here
are requirements by reference (NFR-07). Method: assets → actors → surfaces →
threats → mitigations, STRIDE used as a checklist, not a ceremony. Reviewed
at every milestone; a change in surface (new channel, new tool) reopens it.

## 1. What we protect

| Asset | Why it matters | Worst case |
|---|---|---|
| A1 Model API key and its credit | Real money; monthly credit is finite | Drained credit, service paused, bill |
| A2 Telegram bot token and webhook secret (ADR-0016) | The token lets anyone send as the pharmacy's bot, read its pending updates or move its webhook; the secret lets anyone post updates the webhook accepts | Impersonation, spam from our bot, the bot banned |
| A3 Visitor messages and identities | Strangers' words and Telegram user ids, which are the chat ids a reply needs (a phone number arrives only when a visitor shares a contact, and is dropped); LGPD applies even to a demo | Leak, doxxing, legal exposure, reputation |
| A4a The production VM and its credentials (production SSH key, the production secret set, database password, the model key, the Turnstile secret key; a registry token only if the Docker Hub fallback of design §8 is used) | Everything else lives there | Takeover, pivot to other accounts, cryptomining |
| A4b What the development account can reach, where the coding agent runs: the rehearsal cloud-project token, the rehearsal SSH key (a registry token only under the Docker Hub fallback), the throwaway env set, the dev/eval model key and its spend limit, the fine-grained GitHub token (contents, pull requests, workflows on this repo), the agent's own token, the cloud and GitHub CLI config files, the shell history, and the owner's private notes kept beside the spec; **until M3, also the bot token and webhook secret of the demo bot** (the single host of design §8 is deployed from this account). No DNS credential and no production credential | The agent (T8) can be steered | The dev/eval workspace credit drained; rehearsal resources up to the project limit; a rehearsal host reached; private notes pasted into a tracked file |
| A5 Operator console | Can read conversations, reply as the pharmacy, flip modes | Impersonation of the pharmacist, harassment of visitors |
| A6 The project's reputation | The whole point of the project | A screenshot of the bot giving dosage advice or insulting someone |
| A7 Fictional data integrity | Stock, prices, bookings | Nonsense in the demo; low impact, nightly reset |

## 2. Who might attack

| Actor | Capability | Motive |
|---|---|---|
| T1 Curious visitor | Browser, Telegram, prompt tricks | Fun, testing limits (this is the common case) |
| T2 Scripted abuser | Scripts against the public API or the bot | Free model access, denial of wallet |
| T3 Prompt injector | Crafted messages, pasted documents, voice notes | Make the bot misbehave, extract the prompt, trigger tools |
| T4 Network attacker | Scanning, exploits against exposed services | Takeover of the VM |
| T5 Supply chain | Malicious or vulnerable dependency | Takeover, exfiltration |
| T6 Webhook forger | Can reach the public webhook URL | Inject fake messages, replay events |
| T7 Insider mistake | The operator or the implementer | Secret in a commit, PII in a log, debug route left open |
| T8 Coding agent in the development account | Runs unsandboxed in the development account; can be steered by untrusted content it reads (prompt injection) or run away | Spend on rehearsal servers, reach a rehearsal host, read whatever that account can read |

## 3. Attack surfaces

S1 Web chat API and Action Cable · S2 Telegram webhook endpoint · S3 Trace
pages · S4 Operator console · S5 The model and its tools · S6 Media download
from Telegram's file host and transcription · S7 SSH and the host · S8 CI and deploy
pipeline · S9 Logs, backups and traces at rest · S10 The repository itself ·
S11 Notifications to the operator.

## 4. Threats and mitigations

Each mitigation is a requirement (SR-xx) with a test or a verification step.

### S1 Web chat API

| Threat | STRIDE | Mitigation |
|---|---|---|
| Unbounded model calls from a script (T2 → A1) | DoS | **SR-01** Visitor token required on every call; the per-visitor and per-IP limits of FR-14 (the single home of the numbers), via Rack::Attack, with IPv6 aggregated by /64 and the IP taken from the trusted proxy (SR-36); the operator console is exempt (the canary runs in-process and never crosses the HTTP edge, FR-17); responses to over-limit are static and cheap, and nothing is stored beyond the counter. Tests: the 21st session from one IP in an hour is refused; the 201st turn in a day is refused; two addresses in one /64 count as one source. **SR-02** Global budget gates (FR-14) apply before any model call, including the daily slice (economy until midnight at cap ÷ 30 × 1.5; with `economy_allowed` false the slice pauses until midnight instead; only the monthly cap pauses the month); tests: reaching the slice switches mode with no model call; with `economy_allowed` false it pauses until midnight and the month continues. |
| Free visitor identities minted by a script (T2 → A1) | Spoofing / DoS | **SR-39** (ships in the first slice after the MVP, ADR-0012; until then SR-01 alone gates session creation) `POST /api/session` requires a Cloudflare Turnstile token, verified server-side against the `siteverify` endpoint with a 10 s timeout; failure or timeout refuses the session with a retry hint. The site key is public, the secret key is a per-destination Kamal env secret (A4a in production); development, CI and rehearsal hosts use Turnstile's published test keys, so no real verification and no real traffic to Cloudflare happen there. Turnstile needs no Cloudflare DNS. Tests: a session request without a valid token is refused; the test-key path is exercised in CI. Re-verify at implementation: the free tier and widget limits, the test keys, the endpoint, the data the widget collects, and that the widget's frame needs no browser feature SR-03's Permissions-Policy denies (a denied one warns in the console). |
| Token theft via XSS | Spoofing | **SR-03** Visitor token in an HttpOnly, Secure, SameSite=Strict cookie read by the API and the cable; state-changing requests checked by Origin, and the cable's handshake by the exact public origin alone (Action Cable's same-origin-as-host path is off); strict Content-Security-Policy (no inline scripts; the only third-party origin is `https://challenges.cloudflare.com` in `script-src` and `frame-src`, for SR-39) on every answer a controller writes, which also carries a `Permissions-Policy` denying the browser features the web app does not use; `X-Content-Type-Options: nosniff` on those answers and on the static files; no `X-Runtime` on any answer; React escapes by default and `dangerouslySetInnerHTML` is forbidden by lint; bot text, operator text and transcripts are rendered as plain text. |
| Opener key abused via shared links (FR-21) | Tampering | **SR-34** `{say: key}` is resolved server-side against a fixed allow-list; any other value sends nothing. |
| Per-IP limits defeated behind the proxy | DoS | **SR-36** The app trusts only kamal-proxy's forwarded header (trusted proxies configured), so Rack::Attack and the console lockout see the client IP; `/api/status` and `/api/calendar` are served from Solid Cache with a 60-second TTL so public hits cost no aggregation; the calendar cache key is busted when a booking is created or cancelled, so FR-08's 5-second visibility holds. |
| Oversized or malformed payloads | DoS | **SR-04** Body limit 16 KB on the API, message length 1,000 characters, JSON schema validation at the controller. On the cable (ADR-0015): a handshake of another WebSocket version than 13, or of none, gets 426 and one without a key 400, before Action Cable takes the socket over; a message over 16 KiB closes the socket (1009). |
| Cable sockets, commands or log lines from a script exhaust the one web process (T2) | DoS | **SR-40** (ADR-0015) At most 500 cable sockets per process and 20 per source (the client's address as SR-36 reads it), counted from Action Cable's takeover until it closes the socket, and refused before the takeover with a plain 429 or 503 the page's client retries; 20 commands per connection a minute, the 21st closing it for good; each line of the cable's log cut at 2 KB; a connection whose socket closed while it opened is held neither in Action Cable's own list of connections nor in its pub/sub, which kept it before (a slow leak), and a channel's stream goes once its subscribe is done if the channel or its socket is gone by then. Tests: the 21st socket of a source is refused, and so is one past the process's cap whatever its source, and a closed socket frees its place; the 21st command closes; a long line is cut; a connection closed while it opened is in neither Action Cable's list nor its pub/sub; a stream whose channel closed before its subscribe was done is let go. |
| Reading another visitor's conversation | Information disclosure | **SR-05** Every query is scoped by the visitor derived from the token; no id-based lookup without that scope; test proves cross-visitor access returns 404. |

### S2 Telegram webhook and bot (ADR-0016, ADR-0017)

| Threat | STRIDE | Mitigation |
|---|---|---|
| Forged events (T6) | Spoofing | **SR-06** The `X-Telegram-Bot-Api-Secret-Token` header compared in constant time with the configured secret, before parsing; failures 401, counted and alerted above 10/min. Telegram sends a shared secret, not a signature of the body, so a leaked secret works until the webhook is registered again with a new one: the runbook does it with every rotation of the bot token, and alone when only the secret is in doubt. Whoever holds the secret can write as any Telegram user (a message, a reset, a deletion, model calls up to SR-02's cap) but reads nothing: a reply goes through Telegram to that user's own chat (SR-42). Telegram's published source ranges are not enforced: Telegram says they "might change", and the secret already gates the endpoint. |
| Replayed events | Tampering | **SR-07** The raw update keyed by its `update_id` and each message by its visitor and its message id, both unique; duplicates return 200 and do nothing. (`update_id` restarts at a random value after a week without updates, so it is a key, not a counter.) |
| Webhook registration | Spoofing | **SR-08** Retired 2026-11-14 (ADR-0016): Telegram has no verification handshake; the webhook is registered by an API call made with the bot token (A2). The id is not reused: it is kept so that references resolve, and is outside the traceability set. |
| Slow processing makes Telegram retry | DoS | **SR-09** Webhook stores and enqueues only; returns inside 2 s; processing in Solid Queue. An authenticated update is answered 200 whatever it holds, so one the application cannot use is never sent again; the webhook is registered with a small `max_connections`, so Telegram opens few connections at a time to the one web process. |
| Unbounded model calls through the bot (T2 → A1) | DoS | The per-visitor limits of FR-14 count a Telegram visitor by its identity (SR-01's per-IP limits see only Telegram's addresses, and a Telegram account costs a phone number to mint, ADR-0012); `/start`, `/help`, the ask for agreement, the answer to a message that is not text or is too long and a limit's own line call no model, and the limit's line goes to a visitor at most once a minute; SR-02's gates apply as on the web. |
| Visitor ids leak (A3) | Information disclosure | **SR-10** Identity is `sha256(pepper ‖ Telegram user id)`. The raw id, which a reply needs as the chat to send to, is kept in one place, the visitor's row, encrypted (SR-41), and goes when the row goes (FR-05, FR-15); messages are keyed by the visitor and the message id, so no other row holds it; it is never logged (SR-30) and never in a trace (SR-12). Before a person agrees to the bot's ask, the application keeps nothing of that person but the limits' counter under the hashed identity: no row, no message, and no model reads a word (FR-19). The bot never asks for a phone number (no contact-request button), and a contact a visitor shares anyway is answered like any message that is not text and dropped with its update, so its number reaches no message, log or trace. A stored update keeps only its `update_id` and its kind once its job has read it, and is deleted after seven days (SR-31). The pepper lives in secrets. Tests: a message before the agreement leaves no visitor, no message and no model call; the row's chat id is ciphertext in the database; a read update holds neither its text nor an id of its sender. |
| A group, a channel or another bot reaches the bot; a forged update points a reply at another chat (T1, T6) | Information disclosure / Spoofing | **SR-42** (ADR-0017) An update is used only when it is a `message` in a private chat whose id is its sender's and whose sender is not a bot; anything else is dropped, with no visitor, no turn and no reply. In a group one conversation would mix several people's words and a reply would show one person's reservation to all; with the chat's id tied to the sender's, a reply only ever goes to the visitor it answers. The webhook asks Telegram for `message` updates alone (`allowed_updates`), and the application drops the other kinds all the same, since that list is kept on Telegram's side; the bot is also kept out of groups in BotFather (runbook). Tests: a group's message, a message whose chat is not its sender's, a bot's message and a `callback_query` each leave no turn and no reply, and every update recorded from a private chat with the demo bot passes the rule. |
| What the model writes becomes markup, a link or a preview in the visitor's app (T3) | Tampering | **SR-43** (ADR-0017) A reply leaves as plain text: `sendMessage` with no parse mode over any text the model or a visitor wrote, and with link previews disabled, so no link hides behind a word and no stranger's page draws its card in the chat. Telegram's apps still draw a URL or a `/command` in any text as a link: the URL shows whole, and the only commands are the visitor's own (FR-04, FR-05, FR-12, FR-19), which a tap sends as the visitor and which act on that visitor's own data alone. Tests: a reply that carries Markdown and HTML link syntax is sent unparsed, and every send disables the preview. |

### S3 Trace pages

| Threat | STRIDE | Mitigation |
|---|---|---|
| Enumeration of traces | Information disclosure | **SR-11** 128-bit random token, lookups rate limited, 404 on miss, no listing endpoint; the exhibits (FR-22) are committed static files, not database traces, and carry no identity (tested on the fixture). |
| Trace reveals secrets or the system prompt | Information disclosure | **SR-12** Trace events are built from an allow-list of fields; the system prompt is summarised as "system prompt (N tokens, cached)"; tool results truncated; a test asserts no secret value, no raw phone and no Telegram user or chat id can appear in any event payload. |

### S4 Operator console

| Threat | STRIDE | Mitigation |
|---|---|---|
| Credential guessing | Spoofing | **SR-13** Rails 8 authentication generator (bcrypt), long random password from a manager, lockout after 5 failures per IP per 15 minutes, no password reset by email in V1. |
| CSRF on console actions | Tampering | **SR-14** Rails CSRF protection on, SameSite cookies, console on its own cookie name. |
| Operator reply impersonates the bot to harass | Repudiation | **SR-15** Operator replies are attributed (`author = operator`, shown as "Farmacêutico(a)") and logged with the operator's session id; one operator in V1; operator text is rendered as plain text (SR-03) and bypasses the guardrail by design. |

### S5 The model and its tools

| Threat | STRIDE | Mitigation |
|---|---|---|
| Prompt injection makes the model call a tool with harmful arguments (T3) | Elevation of privilege | **SR-16** Tools are the whole privilege surface: typed, strict schemas; every argument re-validated server-side; quantities and counts capped (10 units, 3 open reservations, 1 open booking per service); the visitor, the conversation and the turn, which keys the side effect with the validated product or slot (NFR-02), are injected by the runner, never taken from the model. No tool can delete data (FR-05 is a pre-model command), read other visitors, change prices or set stock (`create_reservation` takes the units it reserves and nothing else, FR-07), send messages to third parties, fetch URLs, or run code. |
| Prompt extraction | Information disclosure | **SR-17** Nothing secret in the prompt; the prompt is treated as public (it may well be published). Trace summarises it (SR-12). |
| Clinical advice slips through (A6) | — | **SR-18** FR-09 boundary enforced in the prompt, checked by the eval suite at 100% before any release, and re-checked on every reply by the FR-20 guardrail (economy model, structured verdict). A message that may be an emergency gets no first aid and the fixed line with the public emergency numbers (FR-09, its two `boundary` cases). |
| Toxic or off-brand output | — | **SR-19** Same eval discipline; refusal stop reasons are mapped to the decline text, never shown raw. |
| Runaway tool loops | DoS | **SR-20** Max 6 tool calls per turn, `max_tokens` 1,500, per-turn wall clock 60 s, then a fallback reply. |
| Injected content in tool results (e.g. a product name crafted to look like instructions) | Tampering | **SR-21** Catalogue is seed data under our control; tool results are rendered as data, never as instructions; the `injection` eval suite (10 cases at M2, 15 at M5, the seven families of `evals/README.md`) includes the hostile-product-name seed. |

### S6 Media and transcription

| Threat | STRIDE | Mitigation |
|---|---|---|
| SSRF through a media URL | Tampering | **SR-22** Media is fetched only by its file id, through `getFile` and Telegram's file host, never by a URL from the payload; the HTTP client allows only `api.telegram.org` and calls only the methods design §6.6 lists; the file URL carries the bot token, as every Bot API URL does, so no URL of the client is logged (SR-30) or stored. |
| Oversized or malicious audio | DoS | **SR-23** 2 MB and 60 s caps enforced before download completes; content type checked; the transcription adapter runs with a timeout. |
| Transcript used as injection | — | Same as SR-16; transcripts are visitor text. |

### S7 Host

| Threat | STRIDE | Mitigation |
|---|---|---|
| Exposed services | Elevation of privilege | **SR-24** The cloud provider's firewall admits TCP 22, 80, 443 and ICMP inbound, nothing else (a host firewall would be bypassed by Docker's own rules, so none is relied on); Postgres bound to the Docker network; SSH key-only, no root login, fail2ban; unattended security upgrades; Docker containers run as non-root with a read-only root filesystem where the framework allows. The host is defined once, in `ops/cloud-init.yml`, with declarative cloud-init modules only (no script): `users` (the `deploy` user in group `docker` with its key; `ssh_pwauth: false`), `apt.sources` (Docker's repository with its signing key inline), `packages` (`docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, fail2ban, unattended-upgrades), `write_files` (the sshd drop-in `/etc/ssh/sshd_config.d/00-balcao.conf`, named to sort before cloud-init's own because sshd keeps the first value it reads, with `PasswordAuthentication no`, `PermitRootLogin no`, `KbdInteractiveAuthentication no` and TCP forwarding left enabled because Kamal's local registry tunnels through it; `/etc/sudoers.d/deploy`, mode 0440, no dot in the name, allowing `deploy` exactly `/usr/sbin/sshd -T` and `/usr/bin/fail2ban-client status` for the runbook checks), list-form `runcmd` (`sshd -t` as a log line, `systemctl try-reload-or-restart ssh.service` and `fail2ban.service`). The deploy waits for `cloud-init status --wait` before `kamal setup`. The same file creates every rehearsal host and the production host, and is verified by the runbook host checklist (`ss -ltn` inside, a port scan from outside at M3). Kamal's SSH user is `deploy`, non-root, in the host's `docker` group, which is root-equivalent on that host by design: the deploy key is treated as a root credential. |
| Secrets on disk | Information disclosure | **SR-25** No Rails credentials file; every runtime secret is injected as environment at deploy from a mode-600 env file of the operator account (SR-37); the rehearsal destination has its own throwaway set in the development account; never in the image, never in the repo. `.kamal/secrets` and `.kamal/secrets.ensaio` are tracked and contain only `VAR=$VAR` references (so the deploy-path review of SR-38 sees them); value-bearing files are gitignored (`.env`, `.env.*` except `.env.example`, `config/master.key`, `config/credentials/*.key`) and `.dockerignore` mirrors them; a pre-commit hook and a CI scan for secret patterns; a static CI check that every secret pattern of `.gitignore` appears in `.dockerignore` and that the Dockerfile declares no `ARG` or `ENV` with a secret-like name; the app refuses to boot when a required secret is blank (dotenv renders an unset `$VAR` as an empty string), spec cited here. |
| Lost VM | — | **SR-26** Everything reproducible from the repo plus the secrets; every rehearsal host is created from `ops/cloud-init.yml` itself with the provider's CLI, so the production host definition is exercised throughout the project and a lost VM is recreated the same way; backup restore documented in the runbook and drilled once at M3 into a throwaway Postgres container in the operator account (production data never enters the rehearsal project). |
| Coding agent (T8) reaches production credentials | Elevation of privilege, information disclosure | **SR-37** (from M3; until then no production credential exists, see R5) On the operator's workstation, production credentials (A4a) live in a separate operating-system account (the operator account) that the development account cannot read or enter: the development account has no sudo at all, the operator account is entered only through a real login session and never from the development session, and neither account is root-equivalent through Docker group membership. The development account holds exactly the A4b list. The GitHub account uses 2FA (and the registry accounts, if the fallback registry of design §8 is used); `main` is protected. Production deploys are run only by a human from the operator account (SR-38). The workstation recipe (console root, rootless Docker, user services at boot, no SSH agent forwarding) is in the runbook's operator checklist, not here. |

### S8 CI and deploy

| Threat | STRIDE | Mitigation |
|---|---|---|
| Malicious dependency (T5) | Tampering | **SR-27** `bundler-audit`, `npm audit --omit=dev --omit=optional --audit-level=high` (optional is omitted too because npm keeps toolchain packages that runtime packages list as optional peers; design §10, 2026-11-09) and Dependabot; lockfiles committed; CI fails on known vulnerabilities above low on the Ruby side and at high or above in the runtime npm tree (toolchain advisories do not block unrelated pull requests). The kamal-proxy image, which no audit covers, is pinned by `proxy.run.version` in `config/deploy.yml` (Kamal 2.12's own default, v0.9.2, is affected by GHSA-g8jf-9mcc-x4f2, high), with the digest its tag resolved to written beside it: Kamal takes only a tag there, and a tag can be pushed again, so `bin/deploy` puts the image on the host by that digest, under the tag, before every `kamal setup`, refusing an image whose own version label names another release (the operator checklist does the same for production from M3), and the swap checks the content and the release it runs (runbook); the pin is checked against kamal-proxy's published advisories on the monthly bump day. |
| Static issues | — | **SR-28** Brakeman in CI, zero high/medium warnings. |
| Credentials in CI | Information disclosure | **SR-29** CI holds no cloud or deploy credential and never deploys; the test suite runs on a fake model and recorded responses. The only CI secret is the dev/eval model key (its own Console workspace and spend limit, A4b), stored as a GitHub Environment secret (`evals`, required reviewer the owner, `main` only); the full-eval workflow runs on `workflow_dispatch` only, started by the owner (the agent's token has no Actions permission) at milestone close and on the bump day, never on `pull_request`, and writes the scorecard and `evals/economy_allowed.yml` to a branch; it never deploys and never touches recordings. The agent's GitHub token has no `secrets` or `administration` permission. |
| Operator executes agent-written code at production deploy (T8) | Elevation of privilege, information disclosure | **SR-38** (from M3; the `bin/deploy` guard spec from the MVP) The production deploy path runs no repository code outside the reviewed deploy-path files: Kamal is installed as a pinned global gem in the operator account (the version recorded in the runbook) and invoked directly, never through `bundle exec` or `bin/` scripts of the repo; `bin/deploy` itself accepts only `-d ensaio` (a spec cited to this identifier shows that any other invocation exits non-zero without invoking `kamal`); the repo ships no `.kamal/hooks` directory (CI fails if one appears). Before each production deploy the operator fetches, reviews the diff of `config/deploy.yml`, `.kamal/`, `Dockerfile`, `.dockerignore`, `package.json`, `package-lock.json`, `.mise.toml`/`.tool-versions` between the deployed SHA and `origin/main`, fast-forwards, and only then runs `kamal deploy`. The runbook carries the checklist; `kamal audit` on the host and `.last-deployed-sha` in the operator checkout are the deploy record. |

### S9 Data at rest and logs

| Threat | STRIDE | Mitigation |
|---|---|---|
| PII in logs | Information disclosure | **SR-30** Structured logs (one JSON object per line in production, NFR-05) with parameter filtering for phone numbers, a Telegram update's `message` as a whole (its text, its caption, its sender, its chat and whatever else a visitor sent: an update is logged as its `update_id` alone), the message (`text` on the API, `body` in the database), the bot token wherever it appears (every Bot API URL carries it), token and secret-like keys; an error's message never reaches a line, since it may quote the visitor (a database error quotes the row it refused): the app's lines, Active Job's and Solid Queue's lines of a failed job and a request's error line name an error and its causes by their classes. Tests: a message containing a phone number leaves no trace of it in the log; a job and a request that fail with a message quoting one are logged by class alone. |
| Visitors' words at rest (A3) | Information disclosure | **SR-41** (ADR-0016) Every column that stores what a visitor sent (message bodies, transcripts, stored webhook payloads, trace attributes that quote a message) and the Telegram chat id a reply needs (SR-10) is encrypted with Active Record Encryption; the keys live in secrets, never in the database. Telegram's developer terms ask that "user data is always encrypted at rest and stored separately from its encryption key"; that the rows the application writes about a visitor (a reservation's product and code, a conversation's language), which hang from the hashed identity, are not that user data is the project's reading (R9). Test: the stored value is ciphertext and the model reads the plain text. |
| Retention | — | **SR-31** Messages, traces and stored Telegram updates deleted after 7 days, reservations 7 days after their pickup deadline, and visitors not seen for 7 days with everything under them (FR-15, by the nightly job at 03:00 São Paulo from the MVP); backups rotate at 7 days; aggregates carry no identity; no exemption: the exhibits (FR-22) are committed files outside the database, exported with identities stripped (test: the export of a conversation with a phone and a cookie yields neither). |
| Visitor's right to deletion | — | **SR-32** FR-05 deletion is a deterministic command matched before any model call (no tool, so no injection path); synchronous and complete, releasing stock and slots; the rate counter lives outside the deleted rows; a test deletes and asserts zero rows for that identity. One exception: the copies the cable's pub/sub keeps of each broadcast (a conversation's replies, spans and deletion word, in the cable database) are kept 5 minutes and trimmed every 5, so they outlive a deletion by about 10 minutes at most (ADR-0015). On Telegram the command erases what the server holds, the agreement with it; the chat shown in the visitor's app is the visitor's own copy, and the confirmation and `/privacy` say so (FR-05). |

### S10 Repository

| Threat | STRIDE | Mitigation |
|---|---|---|
| Secret committed | Information disclosure | SR-25 hooks and scan; rotation procedure in the runbook. |
| Private data in fixtures | — | **SR-33** All seed and fixture data is invented; names checked against no real business of that name before publication. The Telegram updates recorded from the demo bot for the specs are committed with invented ids, names and usernames in place of the real ones. |

### S11 Notifications (push and email to the operator)

| Threat | STRIDE | Mitigation |
|---|---|---|
| Push topic guessed: visitor words leak, alerts spoofed (A3, A5) | Information disclosure / Spoofing | **SR-35** The push payload carries only a conversation id and a console link, never message text; the topic name is a 128-bit random secret; if the push service is a public instance, the topic is additionally protected with the service's access token where available, otherwise self-hosted. Handoff and budget emails carry a link, never a transcript. |
| Notification flood from a scripted abuser | DoS | Handoff requests are capped per visitor by SR-01/SR-16; at most one notification per conversation per 10 minutes. |

## 5. Accepted risks

- **R1** One VM, no high availability. Accepted: a demo; the canary and
  monitor limit the blind time.
- **R2** The public bot can receive abuse from anyone. Accepted: Telegram's
  own limits plus SR-01/SR-02 bound the cost; the operator can block an
  identity from the console (M2) and pause the channel.
- **R3** A trace link, once shared, shows that conversation to anyone
  holding it. Accepted and disclosed in the trace page itself; expires with
  the conversation; the exhibits are static files with no identity (OD-3).
- **R4** (downgraded 2026-11-02) The clinical boundary has two layers:
  the prompt plus evals, and the FR-20 guardrail check on every reply. The
  check fails open on its own errors; the residual risk is a reply sent
  during a guardrail outage, traced and visible.
- **R5** (added 2026-11-04) A runaway or steered coding agent (T8) can
  spend the rehearsal cloud project up to its resource limits (servers,
  load balancers, volumes, IPs, snapshots: at the project's default
  server limit and the cheapest type, on the order of €60 for a full
  month), reach rehearsal hosts, spend the dev/eval workspace up to its
  limit, and change any file in the repository, including the code the
  operator would execute at a production deploy. Accepted because: the
  project split keeps production out of reach (SR-37); SR-38 controls the
  deploy path; the rehearsal flow ends with destroy-all and an
  end-of-session check that servers, load balancers, volumes and floating
  IPs and snapshots are empty and that the reserved primary IP and the
  cloud firewall are the only standing items; the owner glances at the rehearsal project's cost
  monthly. **MVP extension (2026-11-09, owner-approved):** until M3 the
  demo itself runs on one host of this project, deployed from the
  development account with the rehearsal-grade secret set, the
  spend-limited dev/eval model key and the demo bot's token (A4b).
  So a steered agent can also deface the demo, read seven days of visitor
  messages on that host, or send as the demo bot until the owner
  revokes the token in BotFather. Accepted because the exposure is
  bounded by the two spend limits, the seven-day retention, the token
  rotation and the owner's daily glance at the host, and because the
  alternative (the operator account and the production key inside the
  MVP) costs the owner hours the MVP does not have. At M3 the production
  host, the operator account and a fresh token take over, and this
  extension ends.
- **R6** (added 2026-11-13) Compression and BREACH. Thruster compresses
  the answers, and `GET /api/conversations/current` holds a secret, the
  trace token, beside the conversation's text: an observer of the traffic
  who could make the visitor's browser repeat that request many times, with
  guesses of the attacker's inside the conversation, would read the secret
  from the compressed lengths. Accepted, compression kept, because nobody
  else can place the guesses: the cookie is `SameSite=Strict`, so no page
  of another site sends it, and text enters a web conversation only by a
  `POST` from the exact public origin (SR-03), which no other origin
  passes, a sibling subdomain's included. Thruster also pads each
  compressed answer with up to 32 random bytes (its default), and its
  `GZIP_COMPRESSION_DISABLE_ON_AUTH` would turn compression off for every
  request with a cookie, the static files' included, if this is reopened.
- **R7** (added 2026-11-13, until M3) A cookie planted by a sibling
  subdomain. `dev.br` is a public suffix, so every name under
  `rafasouza.dev.br` is same-site with the demo and may set a cookie for
  the whole domain. A compromised sibling could plant a valid
  `balcao_visitor` cookie of its own with `Path=/api`: the browser sends
  the cookie with the longer path first and Rack keeps the first of a
  name, so the visitor would write under an identity the attacker also
  holds and reads (session fixation). Accepted until M3 because every name
  under the domain is the owner's and the demo's data is fictional and
  lives seven days. At M3 the cookie becomes `__Host-balcao_visitor`,
  which only the demo's own host can set, cut cleanly with no migration
  (a migration would read the old name and reopen the attack), since the
  MVP host's data dies with it (design §9.2).
- **R8** (added 2026-11-13) Many sources filling the cable's 500 sockets
  (SR-40). Each source holds at most 20, so it takes 25 addresses, each
  within the edge's 60 handshakes a minute. Accepted: it costs live
  updates, never data or spend; the demo keeps answering, the chat polls
  while a turn waits and every page's cable client keeps trying, so the
  updates come back as the sockets go. Turnstile (SR-39) gates sessions,
  not sockets, so this stays open until a challenge reaches the handshake.
- **R9** (added 2026-11-14, ADR-0016) The messaging channel is another
  company's platform, and three things can take it away or change its
  face.
  - **Telegram may read its terms against the demo.** They forbid a bot
    used "to provide, link to, aggregate, host, index, distribute, lend
    out, exchange, trade, rent, sell or facilitate the sale of illegal,
    pirated, regulated or questionable goods and services" and do not
    define "regulated". The project's reading is that a pharmacy which
    does not exist provides, indexes and sells nothing: its catalogue,
    its stock and its reservations are fiction, said so before the first
    message. The reach of "user data" in the rule on encryption is a
    reading too (SR-41). Both are the project's, not Telegram's.
  - **A court may suspend Telegram in Brazil again,** as courts ordered in
    2022 and in 2023.
  - **Telegram may show its own ads** in a bar above the chat with the
    bot. Its pages speak of popular bots and give no number, and they
    document no switch for a bot's owner.

  Accepted: nothing lives on Telegram alone, the bot's description and its
  ask say it is a demo, and the day the bot goes the project stands on the
  web channel, as ADR-0004 planned.

## 6. Verification plan

| Milestone | Security work |
|---|---|
| MVP (days 1–12, design §9.1) | SR-25 (gitignore, scan, boot check), SR-27, SR-28, SR-29 in place and visible in CI; SR-24 verified by the runbook host checklist on the MVP host, created from `ops/cloud-init.yml`; the `bin/deploy` guard spec of SR-38; the deploy green on `balcao.rafasouza.dev.br`; SR-01, SR-02 (the monthly pause), SR-03 (cookie, Origin, CSP without a third party, the headers beside it), SR-04, SR-05, SR-11, SR-12, SR-16, SR-17, SR-20, SR-27's pinned kamal-proxy, SR-30, SR-31's nightly purge, SR-32, SR-34, SR-36, SR-40 with tests; SR-06, SR-07, SR-09, SR-10, SR-41, SR-42 and SR-43 with tests against the update payloads recorded from the demo bot (SR-08 retired, ADR-0016), and SR-22's rules for the Bot API client (its one host, its closed list of methods, no URL logged); SR-21's hostile-product-name seed, an eval overlay on the catalogue (`evals/seeds/hostile_product_name.yml`) |
| M4 (voice, first after the MVP) | SR-22's media fetch and SR-23 with tests |
| M2 | SR-39 (the first slice), SR-13..15, SR-18, SR-19, SR-21 (`injection` at 10), SR-35 |
| M3 | SR-02 full (incl. the daily slice and the `economy_allowed` false case), SR-25's static secrets check and the `.kamal/hooks` check in CI, SR-26 (restore drill into a container), SR-31, SR-37 and SR-38 checklists in the runbook, `docs/traceability.yml` for the step-and-measurement ids; an external port scan recorded; the R5 MVP extension closed; R7 closed by the `__Host-` cookie |
| M5 | SR-33 (seed names checked); full re-read of this document; an "OWASP LLM Top 10" column added to the SR tables; accepted risks confirmed or closed |
