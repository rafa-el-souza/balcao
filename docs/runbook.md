# Runbook

How the hosts are made, checked and deployed, and how the demo is run
(design §8, ADR-0011, threat model SR-24, SR-26, SR-37, SR-38). Started on
day 2 of the MVP with the host contract, the host checklist and the MVP
deploy flow; completed in M3 (M3-6, 2026-11-21) with the operator account
and its checklist for production, roll back, the rotations, resetting the
demo, the per-slice rehearsal flow with the Certificate Transparency count
and the production cut. There is no restore: V1 keeps no backup
(ADR-0020).

Kamal is the deploy tool: from a deploying account it builds the
application's image, carries it to the host over SSH and runs the
containers there. Until the production cut (M3-7) there is one host: the
Kamal destination `ensaio` (a destination is a named variant of the deploy
configuration, `config/deploy.ensaio.yml` merged over `config/deploy.yml`,
chosen with `-d ensaio` on every Kamal command), which serves the demo
itself at `https://balcao.rafasouza.dev.br` and is deployed from the
development account with `bin/deploy -d ensaio` (ADR-0011's MVP amendment,
threat model R5). From the cut, production runs on a host of its own,
deployed by the owner from the operator account with the base
configuration, and `ensaio` names throwaway rehearsal hosts at
`ensaio.rafasouza.dev.br`. Nothing in the development account deploys
production.

Two roles appear below. The **development account** is where the code is
written and from where the MVP host is deployed, on a **workstation** with
rootless Docker; its cloud project, the **rehearsal project**, holds the MVP
host until M3 and only rehearsal hosts after it. The **operator account**,
from M3, deploys production and holds its secrets, on a VM of its own
(ADR-0023), and the development account can neither read, enter nor reach
it (SR-37). "Both accounts" means these
two.

**Reading this file.** Labels such as M3-6, PR-16 or M2-10 name the slice,
one pull request, of design §9's plan that brought a piece or will bring
it; `#64` is a pull request, and a letter and a number after it (H1, R4)
one finding of its review. SR-, FR- and NFR- identifiers are requirements
(the threat model, design §4), and R and T ones the threat model's
accepted risks and threats. The **operator** is whoever runs the demo: the
owner, or someone covering for him. The **MVP host** is the MVP's one
host, the `ensaio` destination at the demo's name until the cut; **the
session** is the coding session in the development account.

**What the commands need.** They run from a checkout of this repository in
the deploying account, with that account's env file for the destination
(its place is the account's own, never written in the repository), its SSH
key and ssh config, the provider's CLI logged in to the account's cloud
project, and `gh` logged in to GitHub. The outside consoles (the model's,
the monitor's, the cloud provider's, Cloudflare's, and the Telegram account
that owns the bot) are the owner's, and the monitor's e-mails reach him;
without them, someone covering can still pause the demo (The budget, below)
and call him.

**Has the cut happened?** It has when `dig +short balcao.rafasouza.dev.br`
answers another address than the reserved IP's (`hcloud primary-ip list`
in the rehearsal project) and `dig +short ensaio.rafasouza.dev.br` answers
the reserved IP's.

**Production's commands.** The Kamal commands below are written for the MVP
host, with `-d ensaio`. From the cut, production's are the same commands
without `-d ensaio`, run by the operator from the operator account's
checkout with production's env file loaded the same way (the operator
account, below).

## Pinned tools

| Tool | Version | Where it is pinned |
|---|---|---|
| Kamal | 2.12.0 | A global gem in each deploying account, the same version in both; not in the Gemfile, no `bin/kamal`. `bin/deploy` prints `kamal version` first. |
| kamal-proxy | v0.10.2 | Kamal's reverse proxy on the host, which terminates TLS and passes each request to the application's container. `proxy.run.version` in `config/deploy.yml`, by tag: Kamal reads the running version back from the image tag, so a digest there stops every deploy. A tag can be pushed again, so the digest it resolved to when pinned is written beside it, and a host gets the image by that digest, under the tag, before Kamal boots the proxy (the swap below). Kamal 2.12 alone boots v0.9.2, which GHSA-g8jf-9mcc-x4f2 (high) affects. A deploy never swaps a running proxy. |
| Docker on the workstation | rootless | Kamal builds with the engine's own builder (`builder.driver: docker` in `config/deploy.yml`), which fetches no BuildKit image. |
| Base images | by digest | Those of the `Dockerfile`, which Dependabot proposes, and the Postgres accessory's in `config/deploy.yml` (an accessory is Kamal's word for a service it runs beside the application, here the database), checked by hand on bump day. |

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
  the `web` container (Puma, the application's web server, behind
  Thruster, a small HTTP proxy in the same container that compresses
  answers and caches static files) and the `job` container (Solid Queue,
  the job queue kept in the database, which runs the turns, the canary and
  the nightly job: a turn is a visitor's message and the reply it gets, a
  visitor a person the demo talks to, known by a cookie on the web or by a
  Telegram account, and the canary a visitor's question the app asks itself
  every ten minutes, Monitoring below), both as uid 1000 on a read-only root filesystem with
  `tmp/` and `/tmp` in memory; Postgres as the accessory `balcao-db` on the
  Kamal network with no published port, its data in `~/balcao-db/data` on
  the host. Each container has a memory and a CPU limit (`config/deploy.yml`,
  M3-6): 1 GiB and 1.5 CPUs for `web`, `job` and `balcao-db`, 256 MiB and
  one CPU for `kamal-proxy`, so one that runs away leaves the rest of the
  host to the others (the host has no swap). At its memory limit the
  kernel kills a process inside it: a Solid Queue worker is replaced by its
  supervisor, the turn it ran failing until the sweep takes it up again; a
  Postgres backend makes the database reset every connection; the web
  server's container is restarted by Docker when its main process exits. A
  deploy brings a new limit to `web` and `job`; it reaches the database and
  the proxy only when they are rebooted, so a deploy that changes either
  limit is followed, the same session, by the database's reboot as bump
  day's step 4 runs it (the jobs stopped first; about ten seconds without
  the database) and by `kamal proxy reboot -d ensaio -y` (a few seconds),
  and then by the checklist's row (#67's review, C5).
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
   host by its digest before the first `kamal setup` boots it, so Docker
   Hub is never asked what the tag means.

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
| containers' limits | `docker ps -q \| xargs docker inspect --format '{{.Name}} memory={{.HostConfig.Memory}} cpus={{.HostConfig.NanoCpus}}'` | `web`, `job` and `balcao-db`: `memory=1073741824 cpus=1500000000`; `kamal-proxy`: `memory=268435456 cpus=1000000000` (the database's and the proxy's once rebooted after the deploy that changed them; the host contract) |

From outside: the cloud firewall shows exactly TCP 22, 80, 443 and ICMP
inbound, applied to this server (`hcloud firewall describe <firewall>`); a
production host being cut shows TCP 22 and ICMP alone until the cut's step
5 opens 80 and 443 (The production cut, below).
At M3 an external port scan is recorded as well.

## MVP deploy flow (until M3)

Only a green `main` is deployed to the MVP host.

1. `git switch main && git pull --ff-only`, then check that the CI of that
   commit is green:
   `gh api "repos/rafa-el-souza/balcao/commits/$(git rev-parse HEAD)/check-runs?per_page=100" --jq '.check_runs[] | "\(.name): \(.conclusion)"' | sort`
   prints the four lines of the operator's checklist's step 1, each
   `success`; a line missing is a check not run yet.
2. Load the destination's env file, readable by its account alone (mode
   600), into the same shell as the deploy (with `set -a`), never from a
   shell start-up file, so its keys reach only the deploy. It holds the host address, the key and ssh config paths, and the
   secrets that `.kamal/secrets.ensaio` references. A missing secret is
   generated with `bin/secrets-example` (it prints only the names not yet
   set) and appended to that file, except those an outside console holds:
   the model key, the bot's token and, since M2-1, `TURNSTILE_SECRET_KEY`,
   the secret of the owner's Turnstile widget in Cloudflare's dashboard
   (SR-39). A rehearsal host on its own name (from M3) holds Cloudflare's
   published test secret instead, which the boot refuses on the public
   name. Since M3-2 the two heartbeat URLs of the external monitor,
   `MONITOR_URL` and `TELEGRAM_MONITOR_URL`, are held by the monitor's
   console too (Monitoring, below): the boot refuses the public name
   without them, and a rehearsal host leaves both blank. Since M3-4 the app
   connects to its databases as its own role, `balcao_app`, with
   `APP_DATABASE_PASSWORD`, which `bin/secrets-example` generates beside
   `POSTGRES_PASSWORD`, the owner's (SR-24): the web container's entrypoint
   makes the role, or sets its password again, at every boot. A rotation
   is a new line in the env file and a deploy, watched to its end: from the
   web container's role step, the containers still running hold the old
   password and cannot open a new connection, so if the deploy fails after
   that step, roll back or deploy again at once; either makes the
   containers and the role agree on the env file's password. The owner's
   password stays in each app container's configuration, which an exec
   with `--reuse` (a `docker exec` into the running container) hands whole
   to its command; every app command below runs in a new container
   instead, through the entrypoint, which takes it out first
   (`spec/deploy/runbook_exec_spec.rb` holds the runbook to it).
3. `bin/deploy -d ensaio`. It refuses a dirty working tree, prints
   `kamal version`, puts the pinned kamal-proxy's image on the host by the
   digest written beside its tag, under that tag (SR-27; Docker runs a tag
   it holds without asking the registry, where a tag can be pushed again),
   refusing an image whose own version label names another release (a
   digest a bump left behind), runs `kamal setup` (on a fresh host it boots the
   accessory first; afterwards it deploys like `kamal deploy`), and always
   ends with `kamal registry remove -d ensaio` and the removal of the
   registry's anonymous volume, which Kamal's own removal leaves (about
   158 MB a deploy; the MVP close). It exits non-zero when the deploy
   failed, and when the deploy ran but the local registry is still there
   after its removal, naming the two commands to run (#4's review, R4;
   M3-6). The first run on a fresh host took about two and a half minutes.
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

   - a conversation runs in a person's browser, in a fresh private window:
     open `/chat`, which runs Cloudflare's check as it loads (it shows a box
     to tick only when Cloudflare wants one), and send "tem dipirona?"; the
     reply comes in five to ten seconds and the glass box draws its rows. A
     window that still holds a visitor cookie renews its session with no
     token and would pass with a wrong site key; in a fresh one, the stamp
     "A verificação anti-bot não passou", or a console error naming the code
     110100, 110110 or 400020, says the site key is not the widget's. A real token
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
     that day); on a rehearsal host's fake model it spends nothing, and the
     reply is the recorded one, though the spans and the budget's ledger
     still price the recorded calls as the demo would. Since PR-16 the same
     answer also carries `"mode":"normal"`
     and the rate of the real (`"brl"`), and the reply's spans carry each
     model call's cost (`balcao.cost.usd`).
   - the app's database role (since M3-4): the web and job containers
     connect as `balcao_app`, never as the owner, and the web container's
     log names the role's grants:

     ```
     kamal accessory exec db -d ensaio --reuse "psql -U balcao -d balcao_production -Atc \"select usename, count(*) from pg_stat_activity where backend_type = 'client backend' group by 1\""
     kamal app logs -d ensaio --roles=web --since 15m | grep 'db:app_role'
     ```

     The first runs `psql` inside the running Postgres container (`--reuse`
     on an accessory; the database holds no application secret) and lists
     `balcao_app` with the app's connections, and `balcao` only for the
     line's own `psql`; the second reads the web role's log (`--roles=web`
     limits a command to that role's container, `--roles=job` to the job
     container's), `db:app_role: balcao_app granted on 4 databases`.
   - the canary (since M3-2): within ten minutes of the deploy the job's
     log has a line `canary: passed in … ms (mode economy)`, or
     `(mode paused)` while the demo is paused, and five minutes later the
     Telegram watch's `telegram watch: the webhook delivers, 0 updates
     waiting`; neither is followed by a `heartbeat` line, which would say
     the monitor refused or never heard it:

     ```
     kamal app logs -d ensaio --roles=job --since 15m | grep -E 'canary:|telegram watch:|heartbeat '
     ```

     After the first deploy that sends to a new heartbeat, the monitor's
     console (the owner's account) shows both `Balcão: canário` and
     `Balcão: webhook do Telegram` up, not pending: a URL pasted from
     another heartbeat answers 200 all the same, and only the console
     shows which one heard it (#64's H7).

5. The catalogue: after the first deploy that runs turns (PR-09) and after
   any change to `db/seeds/catalogue.yml`,
   `kamal app exec -d ensaio --roles=web 'bin/rails db:seed'`. It
   is safe to run again on the live database (`db/seeds.rb`).
6. If it fails: `kamal app logs -d ensaio`, `kamal proxy logs -d ensaio`,
   `kamal accessory logs db -d ensaio`. The registry was removed anyway; a
   new deploy of a fixed `main` is the way forward on the MVP host.
7. Say in the slice's handoff what the demo shows now. `kamal audit -d
   ensaio` on the host is the deploy record.

## The operator account (from M3, once; SR-37)

Production is deployed only by the owner, from a separate operating-system
account, the **operator account**, on a VM of its own on the owner's
workstation (ADR-0023), which holds production's secrets. The development
account, where the code is written and where the coding agent runs (threat
model T8), can neither read nor enter it, nor reach it (SR-37): the VM
shares no loopback, temporary directory, process or folder with the
development VM, no port is forwarded to it from the host, and the
development VM has no hand on the hypervisor. On one system the agent could
push its own image to the operator's local registry, or answer the host's
pull on `[::1]`, and reach the clone Kamal builds from (#67's review, C1
and V1). Set up once, as root at the VM's own console, never from the
development account, which has no sudo:

1. The VM and the account, with a password of its own, entered only
   through a login of its own (the VM's console, or SSH by key from the
   host), never with `su` or `sudo` from another account. The VM sits on a
   virtual network of its own, which the development VM is not on, and its
   SSH takes keys alone (`PasswordAuthentication no` in its sshd's
   configuration), so the agent finds no login to try. The account is not
   in the VM's `docker` group, which is root-equivalent there.
2. Rootless Docker for the operator account, as the development account
   has it: Docker's rootless setup run as the operator, its user service
   enabled, and `loginctl enable-linger <the operator account>` so that the
   service starts at boot without a login. A deploy builds the image and
   runs Kamal's local registry with it (`localhost:5556` in production,
   which keeps its configuration apart from the rehearsal's `5555`; the VM
   keeps the accounts apart). Kamal clones the checkout to build it under
   the temporary directory, so the account has its own, made once:
   `mkdir -m 700 -p ~/.kamal-tmp`.
3. Ruby at the version `.tool-versions` names and the pinned Kamal:
   `gem install kamal -v 2.12.0`, then `kamal version` prints `2.12.0`;
   `curl` and `jq`, which the checklist's first step reads CI with.
   No file of the clone may choose or configure them: if mise manages
   Ruby, the clone is never trusted in it (`mise trust` is never run there,
   and when mise asks to trust a configuration of the clone the answer is
   no and the deploy stops).
   Never `bundle install` in the checkout, and never `bin/setup` there:
   `bin/setup` turns on the repository's hooks, which would then run
   repository code in this account at every commit (#1's review, SR-38).
4. The production key pair, made in this account, never copied out of it,
   with a long passphrase the owner's password manager generates and keeps:
   `ssh-keygen -t ed25519 -a 100 -C balcao-prod -f ~/.ssh/balcao-prod`.
   `-a 100` gives the passphrase's key derivation a hundred rounds where
   the default is sixteen, so each guess at a stolen file costs about six
   times as much, and an unlock about 0.6 s (measured on 2026-11-24), once
   a session; `-C` keeps the account's and the machine's names out of the
   public half. Its public half goes into
   the temporary copy of `ops/cloud-init.yml` the production host is made
   from (the cut, below). A deploy session holds it in an agent of its own
   for an hour at most (the checklist, below).
5. The ssh config, which resolves the alias `config/deploy.yml` names:

   ```
   Host balcao-prod
     HostName <the production host's IPv4>
     User deploy
     IdentityFile ~/.ssh/balcao-prod
     IdentitiesOnly yes
     ForwardAgent no
     StrictHostKeyChecking accept-new
   ```

   `accept-new` pins the host's key at the first contact and refuses a
   changed one afterwards; a host made again on the same address (a lost
   VM, SR-26) needs the old entry removed first
   (`ssh-keygen -R <its IPv4>`). The workstation's SSH agent is never
   forwarded to the host (`forward_agent: false` in `config/deploy.yml`).
6. A clone of the public repository, used read-only:
   `git clone https://github.com/rafa-el-souza/balcao.git`. It is fetched,
   read and fast-forwarded by the checklist below, never edited.
7. Production's env file, outside the clone, readable by the operator
   alone, with the values `.kamal/secrets` names. Make it first, empty and
   at mode 600, and never over one that exists, which `install` would
   empty: `[ -e <the file> ] || install -m 600 /dev/null <the file>`, then
   `chmod 600 <the file>` for one made earlier at another mode. The
   generated values come from the operator's own Ruby, never from the
   repository's `bin/secrets-example`, which is repository code; the same
   lengths and characters as that script's:

   ```
   ruby -rsecurerandom -e '%w[SECRET_KEY_BASE:128 POSTGRES_PASSWORD:40 APP_DATABASE_PASSWORD:40 ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY:32 ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY:32 ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT:32 IDENTITY_PEPPER:64 TELEGRAM_WEBHOOK_SECRET:64].each { |pair| name, size = pair.split(":"); puts "#{name}=#{SecureRandom.alphanumeric(Integer(size))}" }' >> <the file>
   ```

   Then `stat -c %a <the file>` prints `600`. The held ones are pasted
   from their consoles: `ANTHROPIC_API_KEY` from
   the production workspace of the model's console, whose spend limit sits
   just below the cap (design §8); `TELEGRAM_BOT_TOKEN` from BotFather;
   `TURNSTILE_SECRET_KEY` from the widget's page in Cloudflare's
   dashboard; `MONITOR_URL` and `TELEGRAM_MONITOR_URL`, the URLs of
   production's own two heartbeats, `Balcão produção: canário` and
   `Balcão produção: webhook do Telegram`, from the monitor's console
   (Monitoring, below), never the MVP host's. Paste a value without spaces or a line
   break around it: the boot check reads past them, and so does the app
   for the host, the keys, the pepper and the secret key base (SR-25), but
   a value Telegram or Cloudflare compares is compared as pasted.

## A production deploy: the operator's checklist (from M3; SR-38)

The production path runs no repository code in the operator account
outside the files this checklist reviews: Kamal is the pinned global gem,
invoked directly, never through `bundle exec` or a `bin/` script, and the
repository ships no `.kamal/hooks` (CI fails if one appears). Every step
runs in the operator account's clone, with production's env file loaded in
the same shell, and Kamal's clone kept in the account's own temporary
directory: `set -a; . <the file>; set +a; export TMPDIR=~/.kamal-tmp`,
never from a shell start-up file. The production key is held for the
session by an agent of its own, its passphrase typed once, for an hour at
most (`ssh-add` again when a command asks for it):
`eval "$(ssh-agent -s)" >/dev/null && ssh-add -t 1h ~/.ssh/balcao-prod`;
the session ends with `ssh-agent -k`, after step 9.

1. `git fetch origin`, then read the CI of `origin/main`'s commit:

   ```
   curl -s "https://api.github.com/repos/rafa-el-souza/balcao/commits/$(git rev-parse origin/main)/check-runs?per_page=100" \
     | jq -r '.check_runs[] | "\(.name): \(.conclusion)"' | sort
   ```

   It prints these four lines, one for each job of the workflow, and
   nothing else; a line missing is a check not run yet, never a pass
   (the verifier's V2 on #67):

   ```
   Ruby: RSpec: success
   Ruby: RuboCop, Brakeman, bundler-audit: success
   Secrets: gitleaks: success
   Web: ESLint, Prettier, types, Vitest, build, npm audit: success
   ```

2. The deploy-path review: the diff, between what runs and what will run,
   of the files whose content Kamal and the image build read in this
   account. Kamal evaluates `config/deploy.yml` as a template and reads
   `.kamal/secrets`, which can run commands; the build reads the rest, the
   two lockfiles naming every package the image installs; and
   mise, the tool that picks Ruby's version, reads `.tool-versions` and its
   own configuration files (the `mise` patterns), which can run commands
   too.

   ```
   git diff "$(cat .last-deployed-sha)" origin/main -- config/deploy.yml .kamal/ Dockerfile .dockerignore web/package.json web/package-lock.json Gemfile Gemfile.lock .tool-versions ':(glob)**/mise.*' ':(glob)**/.mise.*' ':(glob)**/mise/**' ':(glob)**/.mise/**' ':(glob)**/.config/mise*' ':(glob)**/.config/mise/**'
   git ls-tree --name-only origin/main .kamal/
   ```

   The second lists `.kamal/secrets` and `.kamal/secrets.ensaio` and
   nothing else. Anything unexpected in either stops the deploy: in
   `.kamal/secrets` a line other than `NAME=$NAME` (a `$(...)` there would
   run a command), in `config/deploy.yml` a new host, template tag or
   secret, in the `Dockerfile` a new `RUN`, `ARG` or base image, in the
   lockfile a package no pull request named. The first
   deploy has no `.last-deployed-sha`: read those files whole, with the
   same command against git's empty tree in its place,
   `git diff 4b825dc642cb6eb9a060e54bf8d69288fbee4904 origin/main -- <the same paths>`
   (`git ls-tree` refuses the glob patterns).
3. `git merge --ff-only origin/main`; `git status --porcelain` then prints
   nothing.
4. The pinned kamal-proxy on the host by its digest (SR-27), as
   `bin/deploy` does for the rehearsal, read from its one line of
   `config/deploy.yml` (the variables are not named `VERSION`, which Kamal
   reads from the environment):

   ```
   PIN=$(grep -o '^ *version: v[0-9.]* # basecamp/kamal-proxy@sha256:[0-9a-f]*$' config/deploy.yml)
   PROXY_TAG=$(echo $PIN | cut -d' ' -f2); PROXY_DIGEST=$(echo $PIN | cut -d' ' -f4)
   kamal server exec "(docker image inspect $PROXY_DIGEST > /dev/null 2>&1 || docker pull $PROXY_DIGEST) && docker image inspect $PROXY_DIGEST --format '{{index .Config.Labels \"org.opencontainers.image.version\"}}'"
   ```

   The last line prints the release the image says it is, which must be
   `$PROXY_TAG`; anything else stops the deploy. Only then:
   `kamal server exec "docker tag $PROXY_DIGEST basecamp/kamal-proxy:$PROXY_TAG"`.
   (The two commands were run from the development account against the MVP
   host with `-d ensaio` on 2026-11-21.)
5. `kamal version` prints the pinned version; then `kamal deploy`, or on a
   fresh host `kamal setup`, which boots the database accessory first.
   When step 2's diff changed the database's or the proxy's options in
   `config/deploy.yml` (a limit, the logging), a deploy does not bring them:
   reboot them after it, as the host contract says, on production's
   commands.
6. The host runs the image this checkout built (ADR-0023), read only after
   a deploy that passed: a failed one leaves the version before it
   running, whose image is another, and this step is then skipped:

   ```
   BUILT=$(docker image inspect localhost:5556/balcao:$(git rev-parse HEAD) --format '{{.Id}}')
   kamal server exec "docker ps --filter label=service=balcao --format '{{.Names}}' | xargs docker inspect --format '{{.Name}} {{.Image}}'"
   ```

   Every running `web` and `job` container prints `$BUILT`. Another image
   means one built elsewhere ran with production's secrets: `kamal app
   stop`, then every secret rotated (Rotating a secret, below), before
   anything else. (Run against the MVP host with `localhost:5555` and
   `-d ensaio` on 2026-11-21; a change of Docker's image store on either
   side would print another ID, a false stop and never a false pass.)
7. `kamal registry remove`, whether the deploy passed or not, and then
   `docker ps -a --filter name=kamal-docker-registry` lists nothing (End
   of a deploy session, below); then `docker volume prune -f`, which
   removes the registry's anonymous volume that Kamal's removal leaves,
   about 158 MB a deploy (since Docker 23 it removes anonymous volumes
   alone, and this account keeps no other). Production never uses `-P`
   (`--skip-push`, which deploys an image already there instead of building
   this checkout).
8. The smoke of the MVP deploy flow, step 4, on production's commands; in
   the monitor's console, production's heartbeats, `Balcão produção:
   canário` and `Balcão produção: webhook do Telegram`, are the ones up.
9. `git rev-parse HEAD > .last-deployed-sha` (the file is gitignored);
   `kamal audit` on the host keeps the same record.

## Rolling back

Kamal keeps the containers of the last five deploys on the host, stopped,
with their images (`kamal app containers -d ensaio` lists them), and
`kamal rollback <version> -d ensaio` starts that version again with the
env file loaded now and stops the one running: no build, no registry,
the version being the commit's SHA. In production the operator runs it
without `-d ensaio` and writes that SHA into `.last-deployed-sha`.

- Read first which migrations came after that version (a migration, a
  file in `db/migrate`, changes the database's tables; the web container
  runs the new ones at its boot):
  `git log --oneline <version>..HEAD -- db/migrate`. A rollback runs the
  old code on the new schema and never runs a migration back. A table or a
  column added is read by no old code and is safe; a changed format is not
  (design §10, the migration window): fix forward instead, a new deploy of
  a fixed `main`.
- An image from before M3-4 connects as the database's owner, whose
  password Kamal still injects, so it boots (SR-25).
- Then the smoke, and a pull request that fixes `main`; the next deploy
  is an ordinary one.

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
2. Measure before, from the workstation, what the swap is for (this
   section's step 4), so the difference is seen.
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
- **Cloud resources:** the rehearsal project holds exactly the MVP host
  (until the cut; from it, no server at all once a rehearsal host is
  deleted), the reserved IPv4 and the cloud firewall; no other primary IP; load
  balancers, volumes, floating IPs and snapshots are empty. With the
  provider's CLI in the rehearsal project's context: `hcloud server list`,
  `hcloud primary-ip list`, `hcloud load-balancer list`, `hcloud volume
  list`, `hcloud floating-ip list` and `hcloud image list -t snapshot`; to
  count one, add `-o json | jq length`, which reads 0 for an empty list
  (`-o noheader | wc -l` reads 1). The provider
  bills a server until it is deleted, powered off or not; the MVP host is
  never deleted before M3.

## Rehearsal hosts (from M3): the per-slice flow

From the cut, `ensaio` names throwaway hosts at `ensaio.rafasouza.dev.br`,
on the reserved IP, made for the session of a slice that changes the
`Dockerfile` or a Kamal configuration, or closes a milestone, and deleted
at its end (ADR-0011, SR-26). Every one is made from `ops/cloud-init.yml`
itself, so the production host's definition is exercised each time. A
rehearsal host runs the rehearsal's own secret set: Cloudflare's published
Turnstile test secret, which the boot refuses on the public name; no
heartbeat URLs, which the boot refuses off it; a bot token and a webhook
secret of its own and no webhook registered, since a bot has one webhook
and the demo's stays with the demo. It runs in the rehearsal's own mode
(design §8, M3-6b), which the boot holds to the name:

- **The fake model by default** (`MODEL_ADAPTER=fake`): the replies the evals
  recorded (`evals/recordings/`), so the host holds no model key and spends
  nothing. A visitor's message that is the message of a recorded
  one-message case gets that case's recorded answers, its tool calls run
  against the host's own catalogue and FR-20's check included, though the
  reply is the recording's whatever that catalogue holds: the
  landing's three chips ("tem dipirona?" among them) and the canary's
  question, so the canary passes there. Any other message gets the fixed
  apology, as a model error, and two such turns alone in half an hour fail
  the canary's look at the visitors' turns, as a dead model would. The
  boot refuses the fake model on the public name and a model key beside it.
- **A real-model rehearsal** sets `ENSAIO_MODEL_ADAPTER=real` in the
  deploying shell for that deploy alone: the destination then runs the real
  model and injects the dev/eval key, never the production one.
- **noindex on every answer** (`NOINDEX=true`, `X-Robots-Tag: noindex`): its
  name is in the certificate logs within minutes. `robots.txt` lets every
  page be crawled, as on the demo, since a crawler reads noindex only on a
  page it may fetch.

1. **Count the week's certificates** on Certificate Transparency, the
   public logs every certificate is written to. Let's Encrypt issues at
   most five certificates a week for one name, and every rehearsal host's
   first HTTPS request takes one, so stay under four; and since the
   domain's DNS service offers no CAA record, which would name the only
   authority allowed, read that every certificate logged for the domain's
   names came from Let's Encrypt:

   ```
   curl -s 'https://api.certspotter.com/v1/issuances?domain=rafasouza.dev.br&include_subdomains=true&expand=dns_names&expand=issuer' > /tmp/ct.json
   jq -r --arg since "$(date -u -d '7 days ago' +%FT%TZ)" '[.[] | select((.dns_names | index("ensaio.rafasouza.dev.br")) and .not_before >= $since)] | length' /tmp/ct.json
   jq -r '.[] | select(.issuer.friendly_name != "Let'"'"'s Encrypt") | "\(.not_before) \(.dns_names | join(",")) \(.issuer.name)"' /tmp/ct.json
   ```

   The first number is the week's count; the second command prints
   nothing when every issuer is Let's Encrypt. A line there is a
   certificate nobody here asked for: stop, and tell the owner. An empty
   answer where the demo's own certificates must be (`balcao.rafasouza.dev.br`
   has had one since 2026-11-09) is a source that failed, not zero: read
   `https://crt.sh/?q=%25.rafasouza.dev.br` in a browser instead (its JSON
   answered an empty list on 2026-11-21 while Cert Spotter answered).
2. **Create the host** as the MVP host was made (Creating the MVP host,
   steps 1 to 3): `ops/cloud-init.yml` with the development account's
   rehearsal key, CX23 or, out of stock, the next shared x86 type there,
   the reserved IP, no IPv6, the cloud firewall; then the reserved IP's old
   host key removed.
3. **Wait for cloud-init** (step 4 there), then the host checklist.
4. **Deploy:** `bin/deploy -d ensaio` from a clean checkout of the slice's
   commit.
5. **Smoke:** the deploy flow's step 4 on `https://ensaio.rafasouza.dev.br`
   (a conversation runs over the API there, with the test keys: on the fake
   model the reply to "tem dipirona?" is the recorded one, with a price, in
   a second or two, and costs nothing; the canary's line reads `passed`), and
   SR-03 seen from outside, before a production deploy of that commit:
   `bin/edge-check https://ensaio.rafasouza.dev.br`. It asks the host,
   through its proxy and Thruster, for a page of each kind and every answer
   of `spec/requests/response_headers_spec.rb`'s catalogue one request can
   reach, reads each for the headers the application writes on every
   answer, reads the proxy's own two answers (its redirect of plain HTTP,
   its page for a host it does not serve) for their accepted shape, prints
   the headers the edge adds, and exits 1 on any miss. It spends about
   seventy requests of your address on the API, whose limit then refuses
   it for up to a minute. On 2026-11-21 it passed against the MVP host.
   Since M3-6b it reads noindex too: on every answer of a rehearsal host,
   on none of the public name's but the trace page's own.
6. **Delete it** at the session's end: `kamal registry remove -d ensaio`
   if `bin/deploy` could not; then `hcloud server poweroff ensaio`,
   `hcloud primary-ip unassign ensaio` and `hcloud server delete ensaio`.
   The reserved IP is protected against deletion, and the provider deletes
   no server that holds a protected primary IP; a primary IP leaves a
   server only while it is off. Then the resource check of "End of a
   deploy session" with the server list empty: the reserved IP, unassigned,
   and the cloud firewall are the only standing items.

## The production cut (M3-7)

The day production takes the demo's name: the owner's host, the name moved
to it, the bot's token reissued, the MVP host deleted, and the demo
publicised (design §9.2). Its visitors and their data stay behind, by
design: the visitor cookie is `__Host-balcao_visitor` from M3-6 (threat
model R7), so every web visitor starts over, and no data is carried. In
this order; *owner* marks the steps that are the owner's alone.

1. *Owner:* the operator account and production's env file (above), with
   a production model key whose spend limit sits just below the cap; two
   new heartbeats in the monitor's console, `Balcão produção: canário` and
   `Balcão produção: webhook do Telegram`, whose URLs go into production's
   env file alone, so that no two hosts ever tell one heartbeat (one host's
   passing beats would hide the other's failures, as the boot's refusal off
   the public name says; #67's review, C4); the MVP host's Telegram
   heartbeat paused in the console right before the token's rotation
   below, from which its watch fails, while its canary's stays on as long
   as it serves the demo, both deleted with the host at step 9; and two
   values rotated for production alone,
   right before step 4: a new bot token (BotFather's `/token` on the demo's
   bot; the MVP host's token stops at once, so the bot is silent until step
   7) and a new Turnstile secret (the widget's "Rotate secret key"; "the
   rotation occurs over the course of two hours", during which Cloudflare
   takes both secrets, so the MVP host goes on making visitors meanwhile).
   If the DNS service lets the name's TTL go below its hour, set it to
   five minutes the day before: step 5 then takes minutes.
2. *Owner:* the production host, on the day of the cut itself, so the two
   hosts are billed together only for the hours until step 9 (the owner
   chose on 2026-11-23 not to pay for two machines longer). It is made in
   the production project from the provider's web console, which holds no
   API token, as the MVP host was made: `ops/cloud-init.yml` with the
   operator account's public key in place of the placeholder (the file is
   carried from the operator's VM to the browser by its console, and its
   SHA-256 compared on both sides), CX23, Ubuntu 24.04, no IPv6, a primary
   IPv4 of its own, protected against deletion (it outlives a host made
   again, SR-26), the operator's public key chosen as the server's SSH key
   (so no root password is mailed), a cloud firewall that admits TCP 22
   and ICMP alone until step 5 opens 80 and 443. The provider's stock of
   CX23 comes and goes by the hour: production may take another EU
   location than the MVP host's (on 2026-11-24 only Falkenstein had it),
   its primary IP made in that same location; with none in the EU, the
   cut moves to another day, the demo serving meanwhile. Then its address
   in the operator account's ssh config (above),
   `kamal server exec 'cloud-init status --wait'`, repeated until SSH
   answers, and the host checklist.
3. The session deploys the `main` to be cut over to the MVP host, and runs
   `bin/edge-check https://balcao.rafasouza.dev.br` against it: before the
   cut, the MVP host is the rehearsal of production's first deploy.
4. *Owner:* the operator's checklist, with `kamal setup` (a fresh host).
   The certificate cannot be issued yet, the name still pointing at the
   MVP host, and the firewall closed to 80 and 443: the checklist's smoke
   waits for step 5, and its other steps run as written.
5. *Owner:* the DNS records: the `A` record of `balcao.rafasouza.dev.br` to
   the production host's address, and a new `A` record of
   `ensaio.rafasouza.dev.br` to the reserved IP. Then wait out the
   record's TTL (an hour, or the five minutes set the day before): the
   first HTTPS request has kamal-proxy ask Let's Encrypt for the
   certificate, whose check resolves the name with Let's Encrypt's own
   resolvers, and a check that still met the MVP host would fail and count
   against the name's limit (#67's review, C6). Only then open TCP 80 and
   443 in production's cloud firewall, so no request reaches it earlier,
   and make the first request:
   `curl -s --resolve balcao.rafasouza.dev.br:443:<the production address> https://balcao.rafasouza.dev.br/up`
   answers `200`. The cloud firewall then admits exactly TCP 22, 80, 443
   and ICMP, as the host contract says; then the checklist's smoke. Until
   the ports open, a visitor or the uptime monitor whose resolver already
   has the new address meets a timeout: the monitor may write once, and
   writes again on recovery.
6. *Owner:* production's first data: `bin/rails db:seed` (The deploy flow,
   step 5).
7. *Owner:* the bot's task in production (The Telegram bot, below), which
   points the webhook at the name and registers production's secret.
   Telegram reaches the production host once its own cache of the name
   expires; until then its deliveries meet the MVP host, which refuses
   them (its webhook secret is another), and Telegram keeps them and sends
   them again. Only then the operator's chat linked again (The budget,
   below: a fresh database has none): the link's Start reaches production
   through its webhook alone. Between step 4 and this task, production's
   Telegram watch may tell its heartbeat a failure, the webhook being the
   MVP host's still; the task's next watch, ten minutes on, brings it up.
8. *Owner:* the smoke on production, and within ten minutes the canary's
   line and the Telegram watch's; in the monitor's console, production's
   two heartbeats up, not pending.
9. The session, after the name's TTL (an hour) has passed: the MVP host
   deleted (Rehearsal hosts, step 6: powered off, the reserved IP taken off
   it, deleted) and the resource check; the
   owner deletes the MVP host's two heartbeats in the monitor's console;
   the pull request of M3-7 points `config/deploy.ensaio.yml` at
   `ensaio.rafasouza.dev.br`, the proxy's host and `APP_HOST`, with the
   rehearsal's mode (M3-6b): `MODEL_ADAPTER` read with ERB as
   `ENV.fetch("ENSAIO_MODEL_ADAPTER", "fake")`, the destination's own
   `env.secret` list naming `ANTHROPIC_API_KEY` only when that reads `real`
   (a Kamal destination's list replaces the base's), and `NOINDEX: "true"`;
   `spec/deploy/kamal_config_spec.rb` holds the destination to the boot's
   rule, and the cut's pull request has it render the destination both
   ways, with `ENSAIO_MODEL_ADAPTER` unset and set to `real`, so the
   real-model rehearsal's lines are read too (#68's finder, its note 7).
   The rehearsal env file drops the two heartbeat URLs and the demo's
   bot token for a throwaway one, and its `TURNSTILE_SECRET_KEY` becomes
   Cloudflare's published test secret.
10. The demo is publicised.

## Monitoring

An external uptime monitor (the owner's free account) checks
`https://balcao.rafasouza.dev.br/up` every three minutes and e-mails on
failure and on recovery (NFR-04).

Since M3-2 the same account holds two heartbeats, each with its own
incident (the owner, 2026-11-21): the canary's (FR-17), whose URL is
`MONITOR_URL`, and the Telegram delivery watch's, `TELEGRAM_MONITOR_URL`.
Each expects a request every 10 minutes with a grace of 5, so silence
alerts within NFR-04's fifteen minutes, and e-mails on failure and on
recovery. A run that passes requests the URL; one that fails requests the
URL with `/fail` and a line saying why, which the monitor shows beside the
incident; a worker that stopped requests nothing, and the monitor alerts on
the silence. A heartbeat stays pending until its first request, so a new
one alerts only after the first deploy that sends to it.

- **Creating them** (in the monitor's console, once for each host that
  serves the demo's name): the MVP host's two, `Balcão: canário` and
  `Balcão: webhook do Telegram`, and from the cut production's, `Balcão
  produção: canário` and `Balcão produção: webhook do Telegram`, each
  expecting a heartbeat every 10 minutes with a 5-minute grace period and
  e-mail on. Each heartbeat's page shows its secret URL.
- **Their URLs** go into the destination's env file, never into a tracked
  file, the way a held secret does (step 2 of the deploy flow); each holds
  the monitor's token, so the app never logs it. The boot refuses the
  public name without them, with a query or a fragment, without a path, or
  with the same URL for both; and it refuses either off the public name: a
  rehearsal host leaves them blank, and its canary runs and counts without
  telling anyone, while its Telegram watch looks at nothing (design §8;
  #64's H4, C3 and H5). Production gets two heartbeats of its own at the
  cut, named apart from the MVP host's, which go with that host (The
  production cut, above); the rehearsal env file then holds none.

## The budget, the nightly job and the logs (from PR-16)

Each line below runs from the workstation, with the env file loaded in the
same call (`set -a; . <env file>; set +a`); Kamal prints its own lines and
the host around the answer.

- **The cap** is `BUDGET_CAP_USD` in the destination's `env.clear`: 100 in
  `config/deploy.yml` (production), 10 in `config/deploy.ensaio.yml` (a
  rehearsal host on the real model, and the MVP host before the cut, whose
  dev/eval key has a console limit of US$ 20). A new value
  is a deploy. **Resuming a month the cap paused** (FR-14, from M3-1): a
  raised cap resumes it at once, in normal below 70 % of the new cap and in
  economy above it; but while ADR-0003's gate is closed (below) an economy
  pauses, so the new cap must put the month's spend under 70 % of it (more
  than the spend ÷ 0.7: US$ 14.29 for a spend of US$ 10) and the day's spend
  under its slice (the cap ÷ 30 × 1.5). With the gate closed, a full eval run
  that opens it, committed and deployed, lets the month's economy serve
  instead. A mode the operator forced holds whatever the cap is, until it is
  released.
- **The month's spend and the mode that serves:**
  `kamal app exec -d ensaio --roles=web "bin/rails runner 'p [Budget.mode, BudgetState.for_month!.slice(:month, :spent_usd, :day, :day_spent_usd, :automatic_mode, :forced_mode)]'"`
  (`bin/rails runner '<Ruby>'` runs that Ruby inside the application, here
  in a new container of the web role, which the command starts and
  removes). The first item is the mode a turn reads now (a forced mode wins); the row
  keeps the automatic one as last read, and the log has one `budget:` line
  each time it changes, with the month's spend against the cap and the
  day's against its slice. `day` is the last day a charge opened; a day no
  charge has opened yet counts as zero. The ledger began on the day PR-16
  shipped; the model console's usage page has the whole month.
- **The automatic modes** (FR-14, from M3-1): economy from 70 % of the cap
  on, for the rest of the month; economy from the day's slice (the cap ÷ 30
  × 1.5: US$ 0.50 under a cap of 10, US$ 5 under 100) until midnight in São
  Paulo; paused from the cap on, until the next month or a raised cap. No
  model call makes the switch, and none needs a command. While ADR-0003's
  gate is closed (below), an economy pauses instead: the month's with the
  cap's text, the day's until midnight with a text of its own, and the
  `budget:` line ends `the economy model may not serve yet, so the demo
  pauses until midnight` (or `until the month ends`).
- **Pausing by hand** (FR-14's kill switch, until the console has it in
  M2-10, after the publication; ADR-0022):
  `kamal app exec -d ensaio --roles=web "bin/rails runner 'p Budget.force!(:paused)'"`;
  releasing: the same with `Budget.force!(nil)`. The command prints the
  month's `budget:` line and what serves now (`mode`, `forced`). A forced
  mode holds into the next month until released.
- **Economy by hand** (from M2-3; the automatic modes above from M3-1):
  the same line with `Budget.force!(:economy)`. The economy model serves
  only on ADR-0003's gate, the committed `evals/economy_allowed.yml`, which
  every container reads once, at boot; while it says no, or names another
  model, effort, system prompt, tool set (with the texts its results
  carry), history or FR-20 check than the ones that serve (the check since
  M2-11a, the history and the tools' texts since M2-11a3), a
  forced economy pauses with the forced pause's text, and the command's
  line says so (`the forced economy mode may not serve yet, so the demo
  pauses`, then `mode="paused"`). What a boot of the running image reads:
  `kamal app exec -d ensaio --roles=web "bin/rails runner 'p Budget.economy_allowed?'"`;
  and the file itself, to tell a gate that says no from one the boot set
  aside: `kamal app exec -d ensaio --roles=web "cat evals/economy_allowed.yml"`.
  A file missing, unreadable or written for another route, prompt, tool
  set, history or check leaves one `budget: <path> ...; the economy model may not serve`
  warning in each container's log, at boot, which says which; a gate that
  says no (its boundary did not pass at 100 %) leaves none. A bug in the
  code that reads the route or the digests is no warning: the boot raises,
  which CI's boot specs see before any deploy.
- **The operator's chat** (threat model SR-35, from M3-1): the bot sends
  the operator's alerts (the budget's at the cap) to one chat, linked once
  per host, since a fresh database has none. On the workstation:
  `kamal app exec -d ensaio --roles=web "bin/rails runner 'puts OperatorChat.link_url!'"`
  prints `https://t.me/BalcaoDemoBot?start=...`; open it on the phone where
  the operator's Telegram is, within fifteen minutes, and tap Start (or
  Restart). The bot answers in that chat: `Este chat está ligado ao Balcão:
  os alertas do operador chegam aqui.` Any other answer, or none, is read
  with the "what is linked" line below, never by the answer alone:
  - `linked_at` set a moment ago: the chat is linked, and the answer was
    lost or came twice (a link read again after it was made answers with
    the agreement's ask or the greeting, since its token is spent);
  - no `linked_at`, or an old one: the link was spent by someone else or
    expired; run the command again, which also replaces any link still
    pending;
  - the limit's line (`limite da demo por agora` or `por hoje`), or nothing:
    the operator's own Telegram account is over FR-14's per-visitor limits
    (10 messages a minute, 40 a day), which the link counts in; wait a
    minute, or the next day, and run the command again.
  The link is a secret for its fifteen minutes; paste it nowhere else.
  What is linked: the same line with
  `'p OperatorChat.current.slice(:linked_at, :language, :link_expires_at)'`.
  Linking sends again the alert the budget calls for now (the month at its
  cap, or a pause of the closed gate's still on), if it failed because no
  chat was linked or the linked one could not be read. A test of the whole path, which sends a fixed
  line to the chat and prints what became of it: `'p OperatorAlert.test!.slice(:status, :error, :next_attempt_at)'`;
  `sent` arrived, `failed` names why in `error`, and `pending` with an
  `error` and a `next_attempt_at` failed on the way and is tried again by
  then. Unlinking, which also revokes a link still pending:
  `'p OperatorChat.unlink!'`.
- **The budget's alerts** (FR-14, from M3-1): when the month reaches its cap
  the bot sends the linked chat one line naming the month, the cap and the
  spend, once a month and cap (a cap raised and reached again sends
  another); while ADR-0003's gate is closed it also sends one when the
  month's economy pauses the demo until the month ends (once a month and
  cap) and when the day's slice pauses it until midnight (once a day). No
  alert names a visitor or a conversation. Each is tried three times; one
  that cannot leave writes an error line, `operator alert <id> (<kind>): not
  sent, <why>`, where why is `no operator chat is linked`, `Telegram refused
  it (403)` (the bot was blocked in that chat) or the way there failing at
  each attempt. The alerts: `'p OperatorAlert.order(:created_at).last(5).map { |a| a.slice(:kind, :key, :status, :error, :sent_at) }'`.
- **The nightly job** runs at 03:00 São Paulo in the `job` container and
  writes one line, `nightly reset: expired N reservations, reset N
  products; deleted ...`. To run it by hand (it is safe to run again):
  `kamal app exec -d ensaio --roles=job "bin/rails runner 'NightlyResetJob.perform_now'"`.
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
- **FR-20's check of every reply** (from M2-2) is a second, cheap model
  call per turn the model answered, a second usage record at the economy
  model's prices (about US$ 0.0001). A check that gave no verdict lets the
  reply go as the model wrote it (threat model R4) and writes, in the
  `job` container's log, `turn <id>: the guardrail gave no verdict
  (<cause>); the reply is sent as the model wrote it`, the cause an error's
  class or `refusal`, `max_tokens` or `unreadable`; the turn's trace shows
  the same row in the error colour. One such line is a provider's hiccup;
  a run of them means the replies are going out unchecked, which the model
  console's status page or a refused key explains. A reply the check
  replaced writes, in the same log, `turn <id>: FR-20's check replaced the
  model's reply (products listed: N, emergency: true|false)` (from M2-11a),
  never a word of the reply or of the visitor: one is the check doing its
  work; a run of them on ordinary questions means the check has begun to
  replace right answers, which the turns' traces show.

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
  `kamal app exec -d ensaio --roles=web "bin/rails telegram:setup"`.
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
  `kamal app exec -d ensaio --roles=web "bin/rails runner 'puts JSON.pretty_generate(Telegram::Client.new.webhook_info)'"`.
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
  bot sends nothing: Telegram refuses each reply tried with the old token,
  which is marked `failed` and never sent again, so a person who wrote
  meanwhile gets no answer to it.
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
  `kamal app exec -d ensaio --roles=job "bin/rails runner 'Visitor.where(channel: :telegram.to_s).find_each { |visitor| TelegramReplyJob.perform_later(visitor.id) }'"`.
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

## Rotating a secret

When a secret may have leaked, or the owner asks: a new line in the
destination's env file in place of the old one, a deploy (`bin/deploy -d
ensaio` on the MVP host or a rehearsal host; the operator's checklist in
production), and what the table says. A generated value comes from
`bin/secrets-example` in the development account (with the old line
deleted first, since it prints only what is missing); in production, the
one value alone, never the operator account's line for the whole set,
which would rotate every generated secret at once:
`ruby -rsecurerandom -e 'puts SecureRandom.alphanumeric(<its length>)'`,
the length that line gives the name, written in place of the old value.
The deploy is watched to its end.

| Secret | The new value | After the deploy, and what it costs |
|---|---|---|
| `ANTHROPIC_API_KEY` | the model console's workspace: production's, or the dev/eval one | delete the old key in the console. Nothing else changes. |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_WEBHOOK_SECRET` | BotFather's `/token`; generated | the bot's task at once (The Telegram bot, above, which says what happens between the two). |
| `TURNSTILE_SECRET_KEY` | the widget's "Rotate secret key" in Cloudflare's dashboard | deploy within the two hours in which Cloudflare takes both secrets; after them, a host still on the old one refuses every new web visitor (`403 challenge`). |
| `MONITOR_URL`, `TELEGRAM_MONITOR_URL` | the monitor's console: a new heartbeat, then the old one deleted | the canary's and the watch's next runs tell the new heartbeat, which stays pending until then (Monitoring, above). |
| `APP_DATABASE_PASSWORD` | generated | none: the web container's entrypoint sets the role's password again at boot; watch the deploy, as the deploy flow's step 2 says. |
| `POSTGRES_PASSWORD` | generated | set it on the database first, then deploy: `kamal accessory exec db -d ensaio --reuse --interactive "psql -U balcao -d balcao_production"`, then `\password balcao` at its prompt with the new value (typed at the prompt, so it lands in no command line or log). The image's Postgres reads the variable only to make an empty database, so nothing else changes. In production it is done between the operator's checklist's steps 4 and 5, once nothing can stop the deploy that follows; on the MVP host, right before `bin/deploy`. Read the web container's state until the deploy ends: a web container restarted in between (its memory limit, a crash) runs its migrations as the owner with the old password and fails until the deploy brings the new one (the verifier's V3 on #67). |
| `SECRET_KEY_BASE` | generated | every web visitor's cookie stops verifying: each opens a new conversation, and the old ones go with the nightly deletion within seven days. |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `..._DETERMINISTIC_KEY`, `..._KEY_DERIVATION_SALT` | generated, the three together | no stored row of a visitor decrypts any more: reset the demo (below) right after the deploy, with its two lines for the keys. |
| `IDENTITY_PEPPER` | generated | every Telegram visitor becomes a new one, asked to agree again; the old rows go with the nightly deletion within seven days. |

## Resetting the demo

Erases every visitor and everything under them, conversations, messages,
traces, reservations (their stock given back), as each one's own deletion
does (FR-05), and keeps the canary's system visitor and the month's spend:

```
kamal app exec -d ensaio --roles=web "bin/rails runner 'p Visitor.where.not(channel: :system.to_s).each(&:erase!).size'"
```

After a rotation of the encryption keys, two more lines: the stored
Telegram updates, which no longer decrypt, and the operator's chat, linked
again afterwards with the link of "The operator's chat" (The budget,
above):

```
kamal app exec -d ensaio --roles=web "bin/rails runner 'p WebhookEvent.delete_all'"
kamal app exec -d ensaio --roles=web "bin/rails runner 'p OperatorChat.unlink!'"
```

The catalogue's stock comes back with the nightly job, or at once with
`kamal app exec -d ensaio --roles=job "bin/rails runner 'NightlyResetJob.perform_now'"`
(The budget, the nightly job and the logs, above).

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
   and the cloud provider's console says whether the server runs: a server
   stopped is started there; one that is gone or broken is made again from
   `ops/cloud-init.yml` (Creating the MVP host; from the cut, production as
   the cut's step 2 made it) and deployed whole, with a fresh database
   (SR-26: no backup).
3. An answer that is an error (the proxy is up and the app behind it is
   not): read `kamal app logs -d ensaio`,
   `kamal proxy logs -d ensaio` and `kamal accessory logs db -d ensaio`
   (deploy flow, step 6). An error is logged by its class, never its message
   (SR-30).
4. The way forward is a new deploy of a green `main` (the deploy flow from
   its first step), fixed first when the logs name a fault of the code; or,
   when the trouble began with the last deploy, a roll back to the version
   before it (Rolling back, above), then the fix. Then the smoke, whole.
5. The proxy is swapped only when its release is the cause ("Swapping the
   proxy's release", above).

When `/up` answers and the chat does not, the monitor says nothing: the
first things to read are the mode that serves (the budget, above: a paused
month answers with its fixed text) and whether the `job` container runs
(`kamal app details -d ensaio` lists one `web` and one `job`).

## When the canary or the Telegram watch fails (from M3-2)

The alert is the monitor's e-mail for one of the two heartbeats
(Monitoring, above). Its incident shows the failure's line; the job's log
has the same line, and every line before it (design §8; the env file
loaded, as for a deploy):

```
kamal app logs -d ensaio --roles=job --since 1h | grep -E 'canary:|telegram watch:|heartbeat |budget:'
```

- **Silence** (the heartbeat went down with no failure line): no job ran.
  `kamal app details -d ensaio` should list one `job` container; one that
  is missing or restarting is the cause, and the way forward is the one of
  "When the monitor says the demo is down" (a new deploy of a green
  `main`). A line `heartbeat canary: …` or `heartbeat telegram watch: …`
  says the job ran and the monitor refused the request or never heard it
  (a status or an error's class; never the URL).
- **`canary: failed: the reply lacks the marker (outcome …)`**: the turn
  ran and its reply did not hold the street of the store's address. The
  outcome says where, with the error's class when there was one:
  `model_error, Anthropic::Errors::…` (the model API failed: `NotFoundError`
  a model gone, `AuthenticationError` a key revoked, `RateLimitError` or
  `OverloadedError` the provider's limits; the dev/eval key's console says
  whether its limit was reached), `replaced` (FR-20's check replaced the
  reply), `refused`, `deadline`. The canary asks on the economy model, so a
  fault of that model alone fails it while visitors in normal mode, on the
  other route, are still answered (#64's V3).
- **`canary: failed: visitors' turns: N of N in the last 30 minutes
  failed at the model's API (outcome …)`**: the canary's own question was
  answered, but every visitor turn that called the model in the last half
  hour got the fallback because the model's API failed: the visitors'
  route failed (normal mode runs another model, with the API's refusal
  fallback). A fallback a visitor's own question causes (a reply cut at
  its limit, too many tool calls, the turn's time) does not count (#64's
  fix review, R1). The outcome names the
  latest turn's error by its class: `BadRequestError` a model id or a beta
  header the API no longer takes, `NotFoundError` a model gone,
  `RateLimitError` that model's limits spent. The provider's status page
  and the dev/eval key's console say which; a forced economy
  (`Budget.force!(:economy)`, The budget, above) serves visitors on the
  canary's route meanwhile, when ADR-0003's gate allows it (#64's H1).
- **`canary: failed: the reply took … ms from the run's time, over
  20000`** or **`the run started … s after its time`**: the queue, the
  model or the database is slow; the 20 seconds count from when the run was
  due, as a visitor's count from the message's arrival, so the visitors'
  turns wait as long.
- **`canary: failed: paused, and the reply is not a pause's text`**: the
  budget paused the demo and the reply was something else, a fault of the
  code: read the `budget:` lines.
- **`canary: failed: the run broke: <class>`** or **`canary: not run,
  <class>`**: an error outside the model, named by its class; the
  database first.
- **`canary: failed: no reply, the turn is … (…)`**: the visitors' own
  job did not answer the question: `received (not run)` means the job
  failed before the turn ran, the conversation's lock among the causes;
  `failed` with an error's class, a break inside the turn. The job tries it
  again in its own time, as a visitor's, and finds it deleted; visitors'
  turns break the same way (`kamal app logs` shows the job's lines).
- **`canary: failed: an earlier run's turn still holds the canary's
  conversation`**: a canary turn is stuck in its job; the next runs fail
  the same way until it ends. A deploy restarts the job container.
- **`telegram watch: a delivery error at …: <Telegram's words>`**:
  Telegram could not deliver an update. `401 Unauthorized` is a webhook
  secret the server and Telegram no longer share: run the bot's task (The
  Telegram bot, above), which sets the webhook with the server's secret.
  A `5xx` or a timeout is the app's side: `/up` and the web logs.
- **`telegram watch: N updates waiting since a delivery error at …`**:
  no new error since the last look, but updates still wait after one:
  Telegram tries them again in its own time, and the heartbeat stays
  failing until they drain (#64's H3).
- **`telegram watch: N updates waiting`**: Telegram holds updates it has
  not delivered; the delivery errors usually say why.
- **`telegram watch: the webhook's … differ from what the bot's task sets`**:
  the webhook was changed or deleted outside the task (another server with
  the same token, a `deleteWebhook`): run the bot's task.
- **`telegram watch: getWebhookInfo failed: …`**: Telegram refused the
  call, named by its code alone (`401`: the token was revoked or rotated
  without the env file), or could not be reached, named by the failure's
  class or status.

Each heartbeat recovers by itself at its next passing run, ten minutes
apart, and the monitor e-mails the recovery.

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
