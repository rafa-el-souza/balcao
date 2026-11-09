# ADR-0006: One VM, Kamal 2, Solid Queue/Cable/Cache, no Redis

**Status:** accepted; the first consequence (deploy model and the timing of
the production VM) is superseded by ADR-0011 · **Date:** 2026-11-02

## Context

Infrastructure budget under US$ 10/month; a single operator who already
provisions and hardens VMs. The demo must run unattended and be
recreatable from the repo.

## Options

1. **Smallest Hetzner shared-vCPU instance, Docker, Kamal 2.** Rails'
   own deploy tool: zero-downtime deploys, TLS via kamal-proxy, secrets
   injection, accessories for Postgres. Everything in the repo.
2. **Docker Compose + Caddy on the same VM.** Equivalent cost; more
   hand-written glue; not the Rails-native story.
3. **A PaaS (Fly.io, Railway, Render).** Less to operate; costs creep,
   less to show, Postgres add-ons priced separately.
4. **Free-tier cloud instances.** Free until they are not; reclaimed or
   throttled without notice; wrong signal for "runs for months".

## Decision

Option 1. Postgres as a Kamal accessory with a persistent volume. Solid
Queue for jobs, Solid Cable for websockets, Solid Cache for caching: all in
Postgres, no Redis, one fewer process to secure and monitor. Host hardening
as in the threat model (SR-24).

## Why not Sidekiq

Sidekiq is the queue most Rails adverts name, and the author knows it. It
is not used here because nothing in Balcão needs it: the workload is a
few jobs per minute (turns, the canary, the nightly reset, handoff
timeouts, event deliveries). Solid Queue gives two things that matter for
this design: recurring jobs without an extra scheduler (canary, nightly),
and transactional enqueue, so the job that follows a reservation is
committed with the reservation and the classic "job ran before the commit"
race cannot happen. Mission Control provides the dashboard. Sidekiq would
add Redis, one more process to secure, monitor and back up on a single
VM. The choice inverts at sustained volume (thousands of jobs per minute),
with heavy queues, or when batch and uniqueness features are needed; at
that point Sidekiq with Redis is the right tool, and this ADR is
superseded.

## Why not Devise

The console has one operator, password login, lockout and sessions; no
registration, no email recovery in V1, no OAuth. The Rails 8 authentication
generator covers it in a few files the team owns; lockout is Rack::Attack
plus a counter. Devise earns its place with multiple users, confirmation,
recovery, OmniAuth or two-factor extensions, none of which exist here.

## Consequences

- Deploy is `kamal deploy` from the operator's machine with secrets from a
  password manager; CI builds and tests but does not deploy in V1 (OD: a
  deploy-on-tag workflow may be added at M3 if the secret handling is
  clean). **Superseded 2026-11-04 by ADR-0011**: a rehearsal destination
  with throwaway hosts in the slices that need one, the production VM from M3, production
  deploys human-only with the deploy-path review, no CI deploy ever in V1;
  the budget check against the 2026-11-04 prices is there too.
- Single point of failure, accepted (threat model R1); the canary and the
  uptime monitor bound the blind time.
- Everything on one box means resource caps per container (memory limits in
  the Kamal config) so a runaway job cannot starve the web process.
