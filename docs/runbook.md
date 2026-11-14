# Runbook

How the host is made, checked and deployed (design §8, ADR-0011, threat
model SR-24, SR-26, SR-38). Started on day 2 of the MVP with the host
contract, the host checklist and the MVP deploy flow; completed during M3
with the operator checklist for production (SR-37, SR-38), roll back, the
rotations, the modes, restore, reset, the canary's failure and the
per-slice rehearsal flow with the Certificate Transparency count.

Until M3 there is one host: the Kamal destination `ensaio`, which serves
the demo itself at `https://balcao.rafasouza.dev.br` and is deployed from
the development account with `bin/deploy -d ensaio` (ADR-0011's MVP
amendment, threat model R5). Nothing here deploys production.

## Pinned tools

| Tool | Version | Where it is pinned |
|---|---|---|
| Kamal | 2.12.0 | A global gem in each deploying account, the same version in both; not in the Gemfile, no `bin/kamal`. `bin/deploy` prints `kamal version` first. |
| kamal-proxy | v0.10.2 | `proxy.run.version` in `config/deploy.yml`, by tag: Kamal reads the running version back from the image tag, so a digest there stops every deploy. A tag can be pushed again, so the digest it resolved to when pinned is written beside it, and a host gets the image by that digest, under the tag, before Kamal boots the proxy (the swap below). Kamal 2.12 alone boots v0.9.2, which GHSA-g8jf-9mcc-x4f2 (high) affects. A deploy never swaps a running proxy. |
| Docker on the workstation | rootless | Kamal builds with the engine's own builder (`builder.driver: docker` in `config/deploy.yml`), which fetches no BuildKit image. |
| Base images | by digest | `Dockerfile` and the Postgres accessory in `config/deploy.yml`; Dependabot proposes new digests. |

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
   set) and appended to that file.
3. `bin/deploy -d ensaio`. It refuses a dirty working tree, prints
   `kamal version`, puts the pinned kamal-proxy's image on the host by the
   digest written beside its tag, under that tag (SR-27; Docker runs a tag
   it holds without asking the registry, where a tag can be pushed again),
   refusing an image whose own version label names another release (a
   digest a bump left behind), runs `kamal setup` (on a fresh host it boots the
   accessory first; afterwards it deploys like `kamal deploy`), and always
   ends with `kamal registry remove -d ensaio`. The first run on a fresh
   host took about two and a half minutes.
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
   - a conversation runs over the API (since PR-09): with a cookie jar,
     `POST /api/session` with the header
     `Origin: https://balcao.rafasouza.dev.br` and the body `{}` answers
     `201`; `POST /api/messages` with the same origin and
     `{"id": "<a new UUID>", "say": "stock_pt"}` answers `202`; within a
     minute `GET /api/conversations/current` shows the reply and
     `"pending":false`. Each such turn spends a cent or so of the dev/eval
     key. Since PR-16 the session's answer also carries `"mode":"normal"`
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
  on the workstation lists nothing.
- **Build cache under 4 GB:** `docker system df` on the workstation; when the
  build cache is above 4 GB, `docker builder prune --max-used-space 4GB -f`
  (the engine's own builder holds the deploy cache).
- **Cloud resources:** the rehearsal project holds exactly the MVP host,
  the reserved IPv4 and the cloud firewall; no other primary IP; load
  balancers, volumes, floating IPs and snapshots are empty. The provider
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
- **The month's spend:**
  `kamal app exec -d ensaio --roles=web --reuse "bin/rails runner 'p BudgetState.for_month!.slice(:month, :spent_usd, :automatic_mode, :forced_mode)'"`.
  The ledger began on the day PR-16 shipped; the model console's usage page
  has the whole month.
- **Pausing by hand** (FR-14's kill switch, until the console of M2):
  `kamal app exec -d ensaio --roles=web --reuse "bin/rails runner 'BudgetState.for_month!.update!(forced_mode: :paused.to_s)'"`;
  releasing: the same with `forced_mode: nil`. A forced mode holds into
  the next month until released.
- **The nightly job** runs at 03:00 São Paulo in the `job` container and
  writes one line, `nightly reset: expired N reservations, reset N
  products; deleted ...`. To run it by hand (it is safe to run again):
  `kamal app exec -d ensaio --roles=job --reuse "bin/rails runner 'NightlyResetJob.perform_now'"`.
- **The logs** are one JSON object per line (`time`, `level`, `message`,
  `request_id` on a request's lines, `conversation_id` on a turn's, the
  other tags in `tags`); Puma's own start-up lines are plain text. An error
  is logged by its class, never its message (SR-30): the trace of the turn
  (the glass box, the trace page) says what the visitor saw.

## Bump day (monthly)

- Dependabot's pull requests (gems, npm, base-image digests, Actions).
- The pinned Kamal gem: the same new version in both accounts, and this
  file's table.
- The pinned kamal-proxy, against the advisories kamal-proxy publishes
  (`gh api repos/basecamp/kamal-proxy/security-advisories --jq '.[] | [.ghsa_id, .severity, .summary] | @tsv'`
  and its releases); a release that fixes one is pinned, with its digest,
  and swapped as above.
- The Postgres accessory's digest: a new image is a deliberate
  `kamal accessory reboot db -d ensaio`, never a side effect of a deploy.
- `registry:3`, the image Kamal runs for its local registry on the
  workstation: Kamal pulls it by tag, outside the digest pins, so the tag
  Kamal names is checked against its release notes.
- Docker's repository signing key in `ops/cloud-init.yml`: its fingerprint
  is checked again against Docker's documentation.
- The price table and the rate of the real in `config/prices.yml`: the
  prices against the provider's price page and the fallback models against
  `allowed_fallback_models` (design §6.4), the rate against the Banco
  Central's PTAX; each date moves only when its figures were read again.
