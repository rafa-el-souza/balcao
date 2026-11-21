# ADR-0023: The operator account on a VM of its own

**Status:** accepted · **Date:** 2026-11-21 (pull request #67, M3-6; the
owner's word the same day) · Extends
[ADR-0011](0011-rehearsal-destination-and-human-only-production-deploys.md):
where its operator account lives.

## Context

ADR-0011 puts production's deploys in an operator account that the
development account, where the coding agent runs (threat model T8), can
neither read nor enter, and threat model SR-37 places that account on the
owner's workstation, beside the development account, as a separate
operating-system user. The review of pull request #67, which wrote the
operator's checklist, found two ways the agent reaches a production deploy
from another user of the same system, neither of which reading or entering
the operator account:

- **The local registry.** Kamal builds the image in the deploying account
  and runs `registry:3`, which takes pushes from anyone, on the system's
  loopback (`127.0.0.1:5556` for production); the host pulls the image
  through an SSH forward that the deploying Kamal process opens to
  `localhost:5556`. Loopback has no access control between users: a process
  of the development account can push its own image under the deploy's tag
  while it runs, or, where `localhost` resolves to `::1` first, listen on
  `[::1]:5556` and serve the pull itself, with no race. Production would
  then run the agent's image with every production secret, and the
  deploy-path review (SR-38) would see nothing, since no file changed. The
  port pair of design §8 (5556 and 5555) avoids a collision between the two
  accounts' registries; it never separated them.
- **The build's clone.** Kamal clones the checkout to build from it under
  the system's temporary directory (`kamal-clones` there), shared by every
  user: the development account's own rehearsal deploys create that
  directory first, which fails the operator's deploy, and if it made the
  directory writable to all it could swap the tree Kamal builds from between
  Kamal's checks and the build.

## Options

1. **The same system, hardened:** firewall rules set by root that let only
   the operator's user reach the registry's port on `127.0.0.1` and nobody
   on `[::1]`, and a private temporary directory for Kamal. The kernel, the
   shared memory and the process list stay common to both accounts, so other
   channels of the same kind are not ruled out.
2. **A VM of its own for the operator account,** on the same host: no
   loopback, temporary directory or process is shared with the development
   account's VM, so both routes go by construction.

## Decision

Option 2 (the owner, 2026-11-21, "VM própria (Recomendado)"). The operator
account lives on a VM of its own on the owner's workstation, which:

- shares no folder with the development VM, has no port forwarded to it
  from the host, and is entered only by its own login;
- sits on a virtual network of its own, which the development VM is not
  on, its SSH taking keys alone, so the agent finds no login to try (the
  fix review of #67, R7);
- is reached by nothing the development VM controls: the development VM has
  no hand on the hypervisor.

Two layers stay in the operator's checklist (`docs/runbook.md`) whatever
the VM: Kamal clones into a private temporary directory of the operator's
(`TMPDIR`), and after each deploy the checklist reads that the host's
running web and job containers run the very image this checkout built, a
difference stopping the containers and rotating every production secret.
The second detects a swap after the image ran; the VM prevents it.

## Consequences

- Threat model SR-37 says where the account lives; design §8's sentence on
  the two registries' ports says what the pair does and what it does not.
- The owner's preparation for the production cut (M3-7) includes the VM:
  the operating system, rootless Docker, Ruby and the pinned Kamal, as the
  runbook's operator account section lists them.
- Reversal: a single system again needs option 1's rules first, and a new
  ADR.
