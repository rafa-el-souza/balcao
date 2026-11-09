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
  there is no host firewall (Docker's rules would bypass it).
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
- **What Kamal adds.** `kamal-proxy` on ports 80 and 443, with a Let's
  Encrypt certificate obtained on the first HTTPS request for the name;
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
   CX23, image Ubuntu 24.04, the reserved IP as its primary IPv4, the cloud
   firewall attached. The provider still generates a root password; keep
   the command's output to the server's id and status, so the password is
   never printed (root cannot log in anyway).
3. Remove the reserved IP's old host key (host contract, last item).
4. Wait for cloud-init, retrying until SSH answers:
   `kamal server exec -d ensaio 'cloud-init status --wait'`. Docker is
   installed in cloud-init's final stage, and `kamal setup` cannot install
   it as `deploy`. On this provider the command exits **2** ("degraded
   done") because the provider's own vendor data uses deprecated keys; it
   is finished when `cloud-init status --long` says `status: done` and
   `errors: []`, with only deprecation notices under `recoverable_errors`.
5. Run the host checklist.
6. Deploy (next section).

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
   `kamal version`, runs `kamal setup` (on a fresh host it boots the
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
     at the deployed SHA.
5. If it fails: `kamal app logs -d ensaio`, `kamal proxy logs -d ensaio`,
   `kamal accessory logs db -d ensaio`. The registry was removed anyway; a
   new deploy of a fixed `main` is the way forward on the MVP host.
6. Say in the slice's handoff what the demo shows now. `kamal audit -d
   ensaio` on the host is the deploy record.

## End of a deploy session

- **No registry left behind:** `docker ps -a --filter name=kamal-docker-registry`
  on the workstation lists nothing.
- **Build cache under 4 GB:** `docker system df` on the workstation; when the
  build cache is above 4 GB, `docker builder prune --max-used-space 4GB -f`
  (the engine's own builder holds the deploy cache).
- **Cloud resources:** the rehearsal project holds exactly the MVP host,
  the reserved IP and the cloud firewall; load balancers, volumes, floating
  IPs and snapshots are empty. The MVP host is never deleted before M3.

## Monitoring

An external uptime monitor (the owner's free account) checks
`https://balcao.rafasouza.dev.br/up` every three minutes and e-mails on
failure and on recovery (NFR-04). The canary's failure URL (FR-17) joins at
M3; until then the monitor URL in the env file stays empty.

## Bump day (monthly)

- Dependabot's pull requests (gems, npm, base-image digests, Actions).
- The pinned Kamal gem: the same new version in both accounts, and this
  file's table.
- The Postgres accessory's digest: a new image is a deliberate
  `kamal accessory reboot db -d ensaio`, never a side effect of a deploy.
- `registry:3`, the image Kamal runs for its local registry on the
  workstation: Kamal pulls it by tag, outside the digest pins, so the tag
  Kamal names is checked against its release notes.
- Docker's repository signing key in `ops/cloud-init.yml`: its fingerprint
  is checked again against Docker's documentation.
