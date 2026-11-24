# Security policy

Balcão is a one-person portfolio project: a demo of a pharmacy's
attendant, live at <https://balcao.rafasouza.dev.br>, on the web and on
Telegram. The pharmacy, its catalogue and its stock are invented.

## Reporting a vulnerability

Report it privately through GitHub's form: the repository's **Security**
tab, then **Report a vulnerability**. Please do not open a public issue
or pull request for it.

Say what you did, what happened and what you expected, with the request or
the message that shows it. Reports are read by the author and answered on a
best-effort basis.

## What counts

- The code in this repository and the demo it runs: the web chat and its
  API, the trace pages, the Telegram bot and its webhook, the host's open
  ports.
- Getting the attendant to give clinical advice it must refuse, to show
  another visitor's conversation, or to act outside its tools
  ([threat model](docs/threat-model.md) S5): report it privately too.
- Already known and accepted: the risks in the threat model's section 5.
  A report that one of them is worse than it says is welcome.

Out of scope: volumetric denial of service, findings in services the demo
uses (Telegram, Cloudflare, Anthropic, the hosting provider), which go to
them, and social engineering.

## What stays private

A finding that someone outside the system could trigger stays private
until it is fixed, whether it came from a report or from the project's own
reviews; the pull request that fixes it publishes it
([ADR-0024](docs/adr/0024-what-the-public-record-holds-back.md)). A
defect of a dependency is reported to its maintainers and described here
only after they release a fix.
