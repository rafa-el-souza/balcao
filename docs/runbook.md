# Runbook

How the host is made, checked and deployed (design §8, ADR-0011, threat
model SR-24, SR-26, SR-38). Started on day 2 of the MVP with the host
contract, the host checklist and the MVP deploy flow; completed during M3
with the operator checklist for production (SR-37, SR-38), roll back, the
rotations, the modes, reset, the canary's failure and the per-slice
rehearsal flow with the Certificate Transparency count (no restore: V1
keeps no backup, ADR-0020).

Until M3 there is one host: the Kamal destination `ensaio`, which serves
the demo itself at `https://balcao.rafasouza.dev.br` and is deployed from
the development account with `bin/deploy -d ensaio` (ADR-0011's MVP
amendment, threat model R5). Nothing here deploys production.

Two roles appear below. The **development account** is where the code is
written and from where the MVP host is deployed, on a **workstation** with
rootless Docker; its cloud project, the **rehearsal project**, holds the MVP
host until M3 and only rehearsal hosts after it. The **operator account**,
from M3, deploys production and holds its secrets, and the development
account can neither read nor enter it (SR-37). "Both accounts" means these
two.

## Pinned tools

| Tool | Version | Where it is pinned |
|---|---|---|
| Kamal | 2.12.0 | A global gem in each deploying account, the same version in both; not in the Gemfile, no `bin/kamal`. `bin/deploy` prints `kamal version` first. |
| kamal-proxy | v0.10.2 | `proxy.run.version` in `config/deploy.yml`, by tag: Kamal reads the running version back from the image tag, so a digest there stops every deploy. A tag can be pushed again, so the digest it resolved to when pinned is written beside it, and a host gets the image by that digest, under the tag, before Kamal boots the proxy (the swap below). Kamal 2.12 alone boots v0.9.2, which GHSA-g8jf-9mcc-x4f2 (high) affects. A deploy never swaps a running proxy. |
| Docker on the workstation | rootless | Kamal builds with the engine's own builder (`builder.driver: docker` in `config/deploy.yml`), which fetches no BuildKit image. |
| Base images | by digest | Those of the `Dockerfile`, which Dependabot proposes, and the Postgres accessory's in `config/deploy.yml`, checked by hand on bump day. |

## The host contract

What every host is, the MVP host now and the production and rehearsal hosts
from M3.

- **Made from `ops/cloud-init.yml` and nothing else**, with the cloud
  provider's CLI: a temporary copy outside the repository has the deploying
  account's public key in place of `<DEPLOY_PUBLIC_KEY>`; Ubuntu 24.04;
  type CX23 (2 vCPU, 4 GB, 40 GB, x86). The image Kamal builds is amd64, so
  the type is never an Arm one.
- **On the reserved IPv4 and behind the cloud firewall.** The reserved IP
  carries the `A` record, so a new host on it needs no DNS change. The
  cloud firewall admits TCP 22, 80, 443 and ICMP inbound, nothing else;
  there is no host firewall (Docker's rules would bypass it). The host has
  no public IPv6: it is created without one (the provider would otherwise
  add a free IPv6 /64 as a second primary IP), because no `AAAA` record
  points at it and an address nobody uses is one door fewer.
- **The reserved IP belongs to one location**, and a host can use it only
  in that location. When the type is out of stock there, the owner decides
  between waiting and moving: a reserved IP in another location is a new
  address, so the `A` record changes and its TTL (one hour) passes before
  the certificate can be issued. ADR-0011: "the location changes, not the
  plan". (On 2026-11-09 the MVP host's location moved for this reason.)
- **What cloud-init leaves.** The user `deploy`, in the group `docker` and
  so root-equivalent on the host by design: its key is a root credential.
  No password login, no root login, no keyboard-interactive login; TCP
  forwarding stays on, because Kamal's local registry reaches the host
  through a remote port forward. Docker from Docker's own repository,
  fail2ban on sshd, unattended security upgrades, and `sudo` for exactly
  the two checks below.
- **What Kamal adds.** `kamal-proxy` on ports 80 and 443, at the release
  the table above pins (its image put on the host by digest before Kamal
  first boots it), with a Let's Encrypt certificate obtained on the
  first HTTPS request for the name;
  the `web` and `job` containers as uid 1000 on a read-only root filesystem
  with `tmp/` and `/tmp` in memory; Postgres as the accessory `balcao-db`
  on the Kamal network with no published port, its data in
  `~/balcao-db/data` on the host.
- **Host keys.** The deploying account's ssh config pins a host key on first
  contact and refuses a changed one, in a known-hosts file of its own. Every
  new host on the reserved IP presents a new key, so the IP's old entry is
  removed (`ssh-keygen -R <ip> -f <that file>`) right after the host is
  created.

## Creating the MVP host (once, until M3)

1. Check that the type is in stock in the reserved IP's location (the
   provider's CLI: `hcloud server-type describe cx23`). If it is not, see
   the host contract above.
2. Create the server from the temporary copy of `ops/cloud-init.yml`: type
   CX23, image Ubuntu 24.04, the reserved IP as its primary IPv4, no IPv6
   (`--without-ipv6`), the cloud firewall attached. The provider still
   generates a root password; keep the command's output to the server's id
   and status, so the password is never printed (root cannot log in
   anyway).
3. Remove the reserved IP's old host key (host contract, last item).
4. Wait for cloud-init, retrying until SSH answers:
   `kamal server exec -d ensaio 'cloud-init status --wait'`. Docker is
   installed in cloud-init's final stage, and `kamal setup` cannot install
   it as `deploy`. On this provider the command exits **2** ("degraded
   done") because the provider's own vendor data uses deprecated keys; it
   is finished when `cloud-init status --long` says `status: done` and
   `errors: []`, with only deprecation notices under `recoverable_errors`.
5. Run the host checklist.
6. Deploy (next section). `bin/deploy` puts the pinned kamal-proxy on the
   host by its digest before the first `kamal setup` boots it, so the
   registry is never asked what the tag means.

## Host checklist (SR-24)

Inside the host, as `deploy`, through
`kamal server exec -d ensaio '<command>'`:

| Check | Command | Expected |
|---|---|---|
| cloud-init finished | `cloud-init status --long` | `status: done`, `errors: []` |
| sshd as configured | `sudo sshd -T \| grep -E '^(passwordauthentication\|permitrootlogin\|kbdinteractiveauthentication\|allowtcpforwarding) '` | `passwordauthentication no`, `permitrootlogin no`, `kbdinteractiveauthentication no`, `allowtcpforwarding yes` |
| fail2ban watches sshd | `sudo fail2ban-client status` | `Jail list: sshd` |
| services up | `systemctl is-active unattended-upgrades docker fail2ban` | `active` three times |
| listeners | `ss -ltn` | on every address only 22, and after the first deploy 80 and 443; the resolver on 127.0.0.53 and 127.0.0.54; during a deploy, the registry tunnel on 127.0.0.1:5555; never 5432 |
| containers | `docker ps -q \| xargs docker inspect --format '{{.Name}} user={{.Config.User}} ro={{.HostConfig.ReadonlyRootfs}} published={{json .HostConfig.PortBindings}}'` | `web` and `job`: `user=1000:1000 ro=true published={}`; `balcao-db`: `published={}`; only `kamal-proxy` publishes 80 and 443 |

From outside: the cloud firewall shows exactly TCP 22, 80, 443 and ICMP
inbound, applied to this server (`hcloud firewall describe <firewall>`).
At M3 an external port scan is recorded as well.

## MVP deploy flow (until M3)

Only a green `main` is deployed to the MVP host.

1. `git switch main && git pull --ff-only`, then check that the CI of that
   commit is green:
   `gh api repos/rafa-el-souza/balcao/commits/$(git rev-parse HEAD)/check-runs --jq '.check_runs[] | "\(.name): \(.conclusion)"'`.
2. Load the destination's env file into the same shell as the deploy (with
   `set -a`), never from a shell start-up file, so its keys reach only the
   deploy. It holds the host address, the key and ssh config paths, and the
   secrets that `.kamal/secrets.ensaio` references. A missing secret is
   generated with `bin/secrets-example` (it prints only the names not yet
   set) and appended to that file, except those an outside console holds:
   the model key, the bot's token and, since M2-1, `TURNSTILE_SECRET_KEY`,
   the secret of the owner's Turnstile widget in Cloudflare's dashboard
   (SR-39). A rehearsal host on its own name (from M3) holds Cloudflare's
   published test secret instead, which the boot refuses on the public
   name.
3. `bin/deploy -d ensaio`. It refuses a dirty working tree, prints
   `kamal version`, puts the pinned kamal-proxy's image on the host by the
   digest written beside its tag, under that tag (SR-27; Docker runs a tag
   it holds without asking the registry, where a tag can be pushed again),
   refusing an image whose own version label names another release (a
   digest a bump left behind), runs `kamal setup` (on a fresh host it boots the
   accessory first; afterwards it deploys like `kamal deploy`), and always
   ends with `kamal registry remove -d ensaio` and the removal of the
   registry's anonymous volume, which Kamal's own removal leaves (about
   158 MB a deploy; the MVP close). The first run on a fresh host took about
   two and a half minutes.
4. Smoke, from the workstation:
   - `curl -s -o /dev/null -w '%{http_code}\n' https://balcao.rafasouza.dev.br/up`
     answers `200`;
   - `curl -sI https://balcao.rafasouza.dev.br/` answers `200` with
     `cache-control: no-cache`;
   - `curl -s -o /dev/null -w '%{http_code}\n' http://balcao.rafasouza.dev.br/up`
     answers `301` (to HTTPS);
   - `kamal app details -d ensaio` lists one `web` and one `job` container
     at the deployed SHA;
   - `kamal proxy details -d ensaio` names `basecamp/kamal-proxy` at the tag
     `proxy.run.version` pins: a deploy starts the proxy that is already
     there, so another tag means a swap is due ("Swapping the proxy's
     release", below);
   - a script mints no visitor (since M2-1, SR-39): a session asked for
     with no Turnstile token answers `403` and `{"error":"challenge"}`:

     ```
     curl -s -w ' %{http_code}\n' -H 'Origin: https://balcao.rafasouza.dev.br' \
       -H 'Content-Type: application/json' -d '{}' https://balcao.rafasouza.dev.br/api/session
     ```

   - a conversation runs in a person's browser: open `/chat`, which runs
     Cloudflare's check as it loads (it shows a box to tick only when
     Cloudflare wants one), and send "tem dipirona?"; the reply comes in
     five to ten seconds and the glass box draws its rows. A real token
     needs a browser, so the conversation over the API with curl (PR-09 to
     M4-6b) runs only where the test keys are, a rehearsal host from M3,
     with the test site key's dummy token in the session's body, a cookie
     jar, the host's origin in the `Origin` header and a new id for the
     message:

     ```
     ORIGIN=https://ensaio.rafasouza.dev.br; JAR=$(mktemp)
     curl -s -o /dev/null -w '%{http_code}\n' -c "$JAR" -H "Origin: $ORIGIN" \
       -H 'Content-Type: application/json' \
       -d '{"turnstile_token": "XXXX.DUMMY.TOKEN.XXXX"}' "$ORIGIN/api/session"
     curl -s -o /dev/null -w '%{http_code}\n' -b "$JAR" -H "Origin: $ORIGIN" \
       -H 'Content-Type: application/json' \
       -d "{\"id\": \"$(uuidgen)\", \"say\": \"stock_pt\"}" "$ORIGIN/api/messages"
     curl -s -b "$JAR" "$ORIGIN/api/conversations/current"
     rm "$JAR"
     ```

     The session answers `201` and the message `202`; the third request,
     repeated for up to a minute (the reply took five to ten seconds on
     2026-11-15), shows the reply to "tem dipirona?" and `"pending":false`.
     Each such turn spends about two cents of the dev/eval key (US$ 0.019
     that day). Since PR-16 the same answer also carries `"mode":"normal"`
     and the rate of the real (`"brl"`), and the reply's spans carry each
     model call's cost (`balcao.cost.usd`).
5. The catalogue: after the first deploy that runs turns (PR-09) and after
   any change to `db/seeds/catalogue.yml`,
   `kamal app exec -d ensaio --roles=web --reuse 'bin/rails db:seed'`. It
   is safe to run again on the live database (`db/seeds.rb`).
6. If it fails: `kamal app logs -d ensaio`, `kamal proxy logs -d ensaio`,
   `kamal accessory logs db -d ensaio`. The registry was removed anyway; a
   new deploy of a fixed `main` is the way forward on the MVP host.
7. Say in the slice's handoff what the demo shows now. `kamal audit -d
   ensaio` on the host is the deploy record.

## Swapping the proxy's release

`kamal deploy` starts the proxy container that is already there, whatever
`proxy.run.version` says, so a new release runs only after a reboot of the
proxy. On the MVP host:

1. A pull request changes `proxy.run.version` in `config/deploy.yml`, with
   the advisory or release note that asks for it and, beside the tag, the
   digest the tag resolves to then
   (`docker buildx imagetools inspect basecamp/kamal-proxy:<tag>`, its
   first `Digest:`); once it is merged, the MVP deploy flow above deploys
   that `main`, and `bin/deploy` puts the new release's image on the host
   by that digest, under its tag, before `kamal setup`.
2. Measure before, from the workstation, what the swap is for (the checks
   of step 4), so the difference is seen.
3. `kamal proxy reboot -d ensaio`, with the destination's env file loaded
   as for a deploy. It asks for confirmation, then stops and removes the
   proxy container and runs the pinned tag, which the host already holds:
   the demo is down for a few seconds. The certificates and the routes to
   the app live in the `kamal-proxy-config` volume, which the new container
   reads at boot, so nothing is issued again and no deploy is needed.
4. Check, from the repository, the pin read from its one line:

   ```
   PIN=$(grep -o '^ *version: v[0-9.]* # basecamp/kamal-proxy@sha256:[0-9a-f]*$' config/deploy.yml)
   TAG=basecamp/kamal-proxy:$(echo $PIN | cut -d' ' -f2)
   DIGEST=$(echo $PIN | cut -d' ' -f4)
   kamal proxy details -d ensaio
   kamal server exec -d ensaio "docker image inspect $TAG --format '{{json .RepoDigests}}'"
   kamal server exec -d ensaio "docker exec kamal-proxy kamal-proxy version"
   ```

   The details name `$TAG`, the image under it lists `$DIGEST` (the
   content, not only the name), and the running proxy says it is the
   pinned release (releases from v0.10 have the command). The smoke of the deploy flow passes; and,
   for the v0.10.2 swap:
   - `echo | openssl s_client -connect balcao.rafasouza.dev.br:443 -tls1_2 -cipher ECDHE-ECDSA-AES128-SHA`
     fails the handshake (a CBC suite), and the same with
     `ECDHE-ECDSA-AES128-GCM-SHA256` connects;
   - a connection that sends no request, on port 80 or 443, with or without
     a finished TLS handshake, is closed by the proxy after about 10 s;
   - a cable socket opened from the public origin is still open after 90 s
     with no message from the client (Action Cable's pings keep coming);
   - `kamal app logs -d ensaio` shows a request of yours from your own
     address, so the app still reads the client's IP from the proxy (SR-36).
5. Way back: set `proxy.run.version` to the release that ran before in
   the working tree, with its digest beside it (before this pin,
   `v0.9.2 # basecamp/kamal-proxy@sha256:826a6f66c6ba26ac26197ac8755804403c9bb617b90cfac25c7972154c5328ab`,
   the image the MVP host pulled on day 2 and still holds),
   `kamal proxy reboot -d ensaio`, restore the file, and open a pull request
   that pins what runs, with the reason. That release reads the state the
   newer one saved, whose fields it does not know it ignores.

Production (from M3) swaps the same way from the operator account, after
the deploy-path review of the pull request (SR-38); there is no `bin/deploy`
there, so the operator checklist puts the image on the host by its digest
before `kamal deploy`, as `bin/deploy` does.

## End of a deploy session

- **No registry left behind:** `docker ps -a --filter name=kamal-docker-registry`
  on the workstation lists nothing, and `docker volume ls --filter dangling=true`
  lists no volume the deploy left (`bin/deploy` removes the registry's once
  docker says the container is gone, since Kamal's removal exits 0 even when
  docker's failed; a registry still there is named, with the two commands to
  run, as long as docker answers: a daemon that stops answering in those
  seconds is read as "gone", and this check is what finds it).
- **Build cache under 4 GiB:** `docker system df` on the workstation prints
  decimal units, so 4 GiB reads 4.29 GB there; when the build cache is above
  it, `docker builder prune --max-used-space 4GB -f`, whose flag reads "GB"
  as GiB (at 4.05 GB it deleted nothing, pull request #38's session; Docker
  29.9). The engine's own builder holds the deploy cache.
- **Cloud resources:** the rehearsal project holds exactly the MVP host,
  the reserved IPv4 and the cloud firewall; no other primary IP; load
  balancers, volumes, floating IPs and snapshots are empty. With the
  provider's CLI in the rehearsal project's context: `hcloud server list`,
  `hcloud primary-ip list`, `hcloud load-balancer list`, `hcloud volume
  list`, `hcloud floating-ip list` and `hcloud image list -t snapshot`; to
  count one, add `-o json | jq length`, which reads 0 for an empty list
  (`-o noheader | wc -l` reads 1). The provider
  bills a server until it is deleted, powered off or not; the MVP host is
  never deleted before M3.

## Monitoring

An external uptime monitor (the owner's free account) checks
`https://balcao.rafasouza.dev.br/up` every three minutes and e-mails on
failure and on recovery (NFR-04). The canary's failure URL (FR-17) joins at
M3; until then the monitor URL in the env file stays empty.

## The budget, the nightly job and the logs (from PR-16)

Each line below runs from the workstation, with the env file loaded in the
same call (`set -a; . <env file>; set +a`); Kamal prints its own lines and
the host around the answer.

- **The cap** is `BUDGET_CAP_USD` in the destination's `env.clear`: 100 in
  `config/deploy.yml` (production), 10 in `config/deploy.ensaio.yml` (the
  MVP host, whose dev/eval key has a console limit of US$ 20). A new value
  is a deploy, and a raised cap resumes a paused month at once.
- **The month's spend and the mode that serves:**
  `kamal app exec -d ensaio --roles=web --reuse "bin/rails runner 'p [Budget.mode, BudgetState.for_month!.slice(:month, :spent_usd, :automatic_mode, :forced_mode)]'"`.
  The first item is the mode a turn reads now (a forced mode wins); the row
  keeps the automatic one as last read, and the log has one `budget:` line
  each time it changes. The ledger began on the day PR-16 shipped; the model
  console's usage page has the whole month.
- **Pausing by hand** (FR-14's kill switch, until the console has it in
  M2-10, after the publication; ADR-0022):
  `kamal app exec -d ensaio --roles=web --reuse "bin/rails runner 'BudgetState.for_month!.update!(forced_mode: :paused.to_s)'"`;
  releasing: the same with `forced_mode: nil`. A forced mode holds into
  the next month until released.
- **The nightly job** runs at 03:00 São Paulo in the `job` container and
  writes one line, `nightly reset: expired N reservations, reset N
  products; deleted ...`. To run it by hand (it is safe to run again):
  `kamal app exec -d ensaio --roles=job --reuse "bin/rails runner 'NightlyResetJob.perform_now'"`.
  A step that fails stops none of the others: it writes an error line,
  `nightly reset: <step> failed: <class>` with its backtrace, the summary
  goes at warn and names it in place of its count (`messages failed:
  ActiveRecord::StatementTimeout`), and the job raises the first failure's
  error at the end. The command still ends with status 0: its output then has a
  `Retrying NightlyResetJob` line naming the same class, and Solid Queue
  runs the job again in the `job` container a few seconds later; a third
  failed attempt there ends with `Stopped retrying` and `Error performing
  NightlyResetJob` lines in that container's log.
- **The logs** are one JSON object per line (`time`, `level`, `message`,
  `request_id` on a request's lines, `conversation_id` on a turn's, the
  other tags in `tags`); Puma's own start-up lines are plain text. An error
  is logged by its class, never its message (SR-30): the trace of the turn
  (the glass box, the trace page) says what the visitor saw.

## The Telegram bot (from PR-18 and PR-19)

The demo's bot is `@BalcaoDemoBot` (FR-19, ADR-0016, ADR-0017). What only
BotFather holds is set there by hand; everything else is set from the
repository by one task, run inside the application's container, where the
token already is (SR-38). Each line below runs from the workstation, with
the env file loaded in the same call.

- **BotFather's checklist** (once, and again only for what changes):
  - the bot, made with `/newbot`; its username is permanent;
  - its token, pasted into the destination's env file as
    `TELEGRAM_BOT_TOKEN` (the boot refuses a value not of BotFather's
    shape, SR-25);
  - its privacy policy, `https://balcao.rafasouza.dev.br/privacy`, in the
    bot's settings under `/mybots` (Telegram's developer terms require one,
    ADR-0016);
  - out of groups: `/setjoingroups`, disabled (SR-42; the webhook drops a
    group's message anyway);
  - its photo, the favicon's mark, with `/setuserpic` (an upload through the
    Bot API would be a new photo at every run of the task).

  The name, the description, the about text and the command menu are the
  task's: an edit made in BotFather is written over at its next run.
- **The webhook's secret** is generated: `bin/secrets-example` prints a
  `TELEGRAM_WEBHOOK_SECRET` line when the env file has none.
- **The task:**
  `kamal app exec -d ensaio --roles=web --reuse "bin/rails telegram:setup"`.
  Run it after the first deploy, after a deploy that changes the bot's texts
  (`telegram.menu` and `telegram.profile` in `config/locales/`, the commands'
  phrases in `config/commands.yml`) and after each rotation below. It sets
  the webhook (the URL, the secret, `message` updates alone, one
  connection), then reads the command menu of private chats and the
  profile (name, description, short description) for the default language,
  which is Portuguese, and for `en` and `es`, and writes only what differs;
  it prints one line per setting (`written`, `unchanged`, or `not written`
  with Telegram's answer) and ends with `getWebhookInfo`. It exits 1 when a
  setting was not written: Telegram limits `setMyName` and its neighbours,
  and a 429 names the wait (sometimes hours); the others were written, and a
  run after that wait writes the rest. It exits 1 too when `getWebhookInfo`
  reports the webhook otherwise than the task set it, in any of `url`,
  `allowed_updates`, `max_connections` and `has_custom_certificate`
  (`false`), or leaves one of them out: a line `webhook <field>: set …,
  Telegram reports …` names each (FR-19). That is no wait, and a run again
  sets the same values: a `url` on another name means the destination's
  `APP_HOST` (`config/deploy.ensaio.yml`) is not the demo's name, or the
  task ran in another destination's container; any other field means
  Telegram took or reports something other than what the task sent, so
  compare its two values with the Bot API's page on `setWebhook` and
  `getWebhookInfo` (a field left out counts too, two of the four being
  optional there) before running the task again. The secret is not among
  them: Telegram never shows it back, so the smoke below reads the
  delivery errors.
- **The smoke** reads `getWebhookInfo`, at the end of the task or alone:
  `kamal app exec -d ensaio --roles=web --reuse "bin/rails runner 'puts JSON.pretty_generate(Telegram::Client.new.webhook_info)'"`.
  The task has compared `url`, `max_connections`, `allowed_updates` and
  `has_custom_certificate`; read the rest yourself: a
  `pending_update_count` near 0, and no `last_error_date` after the deploy:
  a `last_error_message` of 401 means the secret Telegram sends differs from
  the app's (run the task), a timeout that the app did not answer. Then, on
  a phone: the description in the empty chat, the menu, and Start answered
  with the ask and its button; the button's tap answered with the greeting
  and FR-21's three suggestions in the button's place, and a tap on one
  answered as a typed message, the suggestions gone; a reservation's reply
  with a button that copies its code; `/trace`'s reply, with no link
  preview, and its button opening the trace page; a photo and a text over
  1,000 characters each answered with their fixed line; `/apagar`
  answered with its confirmation, and the next message with the ask again
  (FR-19).
- **Rotating the webhook's secret** (when it may have leaked, SR-06): delete
  its line from the env file, append the one `bin/secrets-example` prints,
  `bin/deploy -d ensaio`, then the task at once. Between the two, Telegram's
  deliveries meet a 401 (one log line a minute) and Telegram keeps the
  updates and sends them again, for up to 24 hours, once the task has
  registered the new secret.
- **Rotating the token** (when it may have leaked; at M3 for the production
  set): BotFather's `/token` makes a new one and the old one stops working;
  paste it into the env file, `bin/deploy -d ensaio`, then the task, which
  registers the webhook again with the secret (SR-06). Until the deploy, the
  bot sends nothing.
- **A reply that did not leave** is marked `failed` on its message, and the
  log has one `telegram reply <id>: failed after N attempts` line naming the
  error by its class and Telegram's code (a 403 is a visitor who blocked the
  bot), the wait a 429 named and, for a reply cut in parts, the part that
  failed. A reply Telegram asked to wait for, or that failed on the way (a
  timeout, a broken connection, an answer of 5xx, whose line names it
  `HTTP 5xx`), stays `pending` with its time (`next_attempt_at`) until
  `TelegramReplyJob` tries it again, three attempts in all; a connection cut
  during TLS is one of those, named `Telegram::Client::Error
  (OpenSSL::SSL::SSLError)`. An error that is not the network's (a
  certificate the host does not prove, named `OpenSSL::SSL::SSLError` alone,
  or a bug) is no failure of the way there: the reply stays `pending`, the
  attempt counted, and the job that sends logs the error's class
  (`telegram replies of visitor <id>: not sent, <class>` after a turn,
  `telegram update <update_id>: replies not sent, <class>` while an update
  is read, or `stored replies not sent, <class>` when the update's own line
  left and only the stored replies before it broke) and `TelegramReplyJob`
  tries again a minute later; the third such attempt marks it `failed`,
  with `telegram reply <id>: failed after 3 attempts that broke, <class>`,
  so the visitor's later replies go (M4-4).
  A certificate that fails every time is the host's certificate store or
  something between the host and Telegram, not Telegram; `telegram:setup`
  stops at its first call with OpenSSL's reason. The trace page of the
  conversation says `mensagem não enviada` for a reply marked `failed`. A
  visitor whose chat does not decrypt (encryption keys other than the
  row's) can be sent nothing: each pending reply of theirs is marked
  `failed` with `telegram reply <id>: failed, the visitor's chat cannot be
  read`.
- **A reply that is never stored** (the ask, `/help` and the deletion
  before the agreement, the fixed lines) is tried once, since nothing keeps
  its chat to try again; one that could not be sent has a `telegram fixed
  reply <name>: failed after 1 attempt` line.
- **The deletion's confirmation** leaves before the visitor's rows go, and
  the turn's job tries it again with its backoff, three attempts in all,
  each failed one with a `telegram fixed reply deleted: failed at attempt N
  of 3 of turn <id>'s job` line, or `broke at attempt N of 3 of turn <id>'s
  job, <class>` when the send broke rather than failed (FR-05); a later
  turn's job that runs the deletion first names its own turn. The third
  run deletes whether or not it left, and once the data went the log has
  `telegram fixed reply deleted: not sent, the data deleted all the same`.
  While the deletion has not gone, whatever broke it, the visitor's later
  messages wait behind it (`earlier turn <id>: a deletion that did not go
  holds the turns after it, <class>`, or `earlier turn <id>: not read, so
  the turns after it wait, <class>` when the database kept the job from
  telling whether it is one), and none reaches the model. The update that
  asked for the deletion goes with the data, so it is never read again. A
  deletion whose job ends in the dead letter keeps no reply (`dead letter:
  turn <id> is a deletion that did not go, <class>: no reply, the sweep or
  the next message runs it again`), nor does a turn it held (`... is held by
  an earlier deletion ...`); the sweep runs it again within about six
  minutes, and past its third run it deletes without sending the
  confirmation again (`not sent again after the turn's 3 runs, the data
  deleted all the same`). A confirmation can arrive twice when a run is
  repeated.
- **Replies left pending** (after a stop, an outage) leave before the
  person's next reply, or with the sweep below within about six minutes of
  their time, or at once with:
  `kamal app exec -d ensaio --roles=job --reuse "bin/rails runner 'Visitor.where(channel: :telegram.to_s).find_each { |visitor| TelegramReplyJob.perform_later(visitor.id) }'"`.
  A reply marked `failed` is never sent again.
- **The sweep** (NFR-03, M4-4) runs every minute in the `job` container and
  takes up again what was left stopped for more than five minutes with no
  job at work on it: an update left unread, a turn left without a reply, a
  reply left pending past its time. A pass that took something up writes
  one line, `sweep: taken up again N updates, N conversations, N visitors'
  replies`; a look that broke writes `sweep: <what> not looked at,
  <class>`. The job it starts decides: an update read three times is given
  up with the fallback's line to the person (`telegram update <update_id>:
  given up after 3 reads`), sent once the update is stripped; one whose
  body no longer decrypts is given up with no line (`given up, no line:
  ActiveRecord::Encryption::Errors::Decryption`); and a turn run three
  times gets the fallback with no model call (its trace's outcome
  `dead_letter`, error `TurnProcessor::RunsSpent`). Something taken up
  again pass after pass, every five or six minutes, keeps breaking (a
  deletion whose erase fails, the database): its own lines say why.

## When the monitor says the demo is down

The alert is the external monitor's e-mail (Monitoring, above): `/up` did
not answer `200`. Every command here is one the MVP deploy flow already
gives; this section only puts them in the order of a bad day.

1. Ask `/up` by hand, the first line of the smoke (deploy flow, step 4).
   A `200` means the demo is back: the monitor writes again on recovery,
   and the logs of step 3 say what happened meanwhile.
2. No answer at all, or a refused connection: see whether the host and its
   containers are there, with `kamal app details -d ensaio` and
   `kamal proxy details -d ensaio` (the destination's env file loaded, as
   for a deploy). When SSH does not answer either, the host itself is down,
   and the cloud provider's console says whether the server runs.
3. An answer that is an error (the proxy is up and the app behind it is
   not): read `kamal app logs -d ensaio`,
   `kamal proxy logs -d ensaio` and `kamal accessory logs db -d ensaio`
   (deploy flow, step 6). An error is logged by its class, never its message
   (SR-30).
4. The way forward is a new deploy of a green `main` (the deploy flow from
   its first step), fixed first when the logs name a fault of the code;
   then the smoke, whole.
5. The proxy is swapped only when its release is the cause ("Swapping the
   proxy's release", above).

When `/up` answers and the chat does not, the monitor says nothing: the
first things to read are the mode that serves (the budget, above: a paused
month answers with its fixed text) and whether the `job` container runs
(`kamal app details -d ensaio` lists one `web` and one `job`).

## Bump day (monthly)

In this order, from the workstation, with the destination's env file
loaded as for a deploy. Steps 3 and 4 interrupt the demo, so they are done
only when there is something to change; the others never do.

1. **Dependabot's pull requests** (gems, npm, the base images of the
   `Dockerfile`, Actions): read, merged when CI is green, then the MVP
   deploy flow above.
2. **The pinned Kamal gem:** the same new version in both accounts, and
   this file's table.
3. **The pinned kamal-proxy**, against the advisories kamal-proxy publishes
   (`gh api repos/basecamp/kamal-proxy/security-advisories --jq '.[] | [.ghsa_id, .severity, .summary] | @tsv'`
   and its releases); a release that fixes one is pinned, with its digest,
   and swapped as above. *Interrupts the demo for the seconds of the swap.*
4. **The Postgres accessory's digest**, which Dependabot does not propose
   (it reads the `Dockerfile`, not `config/deploy.yml`): checked by hand
   against the image's releases. A new image is a pull request that changes
   the digest and then a deliberate reboot from that `main`, never a side
   effect of a deploy, and the jobs stop first. The digest is the image
   index's, which `docker buildx imagetools inspect postgres:<tag> --format
   '{{json .Manifest.Digest}}'` prints, and it follows the tag in the `db`
   accessory's `image:` line (`postgres:18.6@sha256:…`). The reboot needs
   no deploy: a deploy never reboots an accessory, and the app's containers
   keep the version they run.

   ```
   RUNNING=$(kamal app version -d ensaio -q | grep -E '^[0-9a-f]{40}$')
   kamal app stop -d ensaio --roles=job
   kamal accessory reboot db -d ensaio
   kamal accessory exec db -d ensaio --reuse "pg_isready -U balcao -d balcao_production"
   kamal app start -d ensaio --roles=job --version="$RUNNING"
   kamal app details -d ensaio --roles=job
   ```

   The first line reads the version that runs: `kamal app start` names the
   container by a version and, given none, takes the checkout's commit, so
   on a checkout that moved since the last deploy it would start nothing
   and still end without an error. (The variable is not named `VERSION`,
   which Kamal itself reads from the environment.) The fourth line is
   repeated until it says "accepting connections"; only then do the jobs
   start, and the last line must list the `job` container, up; `kamal
   accessory details db -d ensaio` then shows the new image running.
   *Interrupts the demo:* while Postgres is down a message gets "not sent"
   on the page and Telegram sends its update again later; with the jobs
   stopped no turn is cut in the middle, and what was waiting runs when
   they start. Rebooted with the jobs running, a turn can lose its lock, a
   turn can be left without a reply and an update unread (the verifier of
   the owner's round at the MVP close, 2026-11-15). *Measured* on
   2026-11-15, when the demo's database was rebooted for its new log
   settings (the step whole, from `4c2587a`): the jobs stopped for 39 s,
   `kamal accessory reboot db` took 19.3 s, the first `pg_isready` already
   said "accepting connections", and a probe from outside every 3 s saw the
   database answer no request for between 6 and 12 s (three reads answered
   500) while `/up` answered 200 throughout; a turn was answered after it.
5. **`registry:3`**, the image Kamal runs for its local registry on the
   workstation: Kamal pulls it by tag, outside the digest pins, so the tag
   Kamal names is checked against its release notes.
6. **Docker's repository signing key** in `ops/cloud-init.yml`: its
   fingerprint is checked again against Docker's documentation.
7. **The price table and the rate of the real** in `config/prices.yml`: the
   prices against the provider's price page and the fallback models against
   `allowed_fallback_models` (design §6.4), the rate against the Banco
   Central's PTAX; each date moves only when its figures were read again.
