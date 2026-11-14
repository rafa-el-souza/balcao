# ADR-0012: Daily budget slice, per-IP limits and Turnstile at session creation

**Status:** accepted · **Date:** 2026-11-04 (amended 2026-11-09, before the first commit: the schedule in the last consequence) · Extends ADR-0003 · The line "WhatsApp is unaffected" amended by [ADR-0016](0016-telegram-bot-api-as-the-messaging-channel.md) on 2026-11-14: it reads for Telegram.

## Context

A visitor identity is free: `POST /api/session` issues one to any browser
(FR-18). The per-visitor cap of ADR-0003 (40 turns a day) is therefore
defeated by a script that changes cookies, and the only per-source brake
was 60 requests per minute per IP. The budget had a monthly cap only, with
economy mode at 70 %. A plain script from one address could push the demo
into economy mode in about an hour and a half and pause it for the rest of
the month in half a day, which is exactly the failure a recruiter would
see ("demo pausada até o próximo mês"). Found in the owner's review of
2026-11-03, decided on 2026-11-04.

## Options

1. **Do nothing beyond ADR-0003**, accept the pause as a demo risk.
2. **Defences inside the app only**: a daily slice of the cap, per-IP
   limits with IPv6 aggregated by /64, and a self-hosted proof-of-work
   challenge at session creation. No third party, no CSP change; weaker
   against a patient attacker with a few machines.
3. **The same, with Cloudflare Turnstile as the challenge.** A managed
   challenge graded by a service that sees far more traffic than this
   demo; invisible for most visitors; works without moving DNS to
   Cloudflare; one third-party origin enters the CSP and the privacy line.
4. **Cloudflare in front of the VM** (proxy, Bot Fight Mode, WAF): the
   strongest, but it is a hosting-architecture change (a decision outside
   this ADR) with
   Cloudflare reading all traffic; out of scope for this gap.

## Decision

Option 3.

- **Daily slice** (FR-14, SR-02): the monthly cap is divided into daily
  slices of cap ÷ 30 × 1.5. Reaching the slice switches to economy mode
  until midnight (São Paulo time) without a model call for the switch; the
  status page shows the slice (when `economy_allowed` is false, ADR-0003,
  the slice pauses until midnight instead). Only the monthly cap pauses
  the month, so a bot costs at most a day, never the month, and a
  legitimate spike degrades instead of stopping.
- **Per-IP limits** (SR-01), client IP from the trusted proxy (SR-36),
  IPv6 aggregated by /64: 20 session creations per hour, 200 turns per
  day, on top of the existing 60 requests per minute. Over the limit the
  fixed "limite da demo" reply, no model call, nothing stored beyond the
  counter. The operator console is exempt; the canary (FR-17) runs
  in-process and never crosses the HTTP edge, so it needs no exemption.
- **Turnstile at session creation** (SR-39): `POST /api/session` requires
  a Turnstile token, verified server-side with a 10 s timeout; failure or
  timeout refuses the session with a retry hint. Managed mode, invisible
  for low-risk visitors. The site key is public (in the SPA); the secret
  key is a per-destination Kamal env secret. Development, CI and rehearsal
  hosts use Turnstile's published test keys: no real verification there.
- **CSP** (SR-03): `script-src` and `frame-src` admit
  `https://challenges.cloudflare.com`, the only third-party origin in the
  app. The chat page says in one line that Cloudflare runs the check and
  sees the visitor's IP.
- **WhatsApp is unaffected**: the identity there is a phone number, costly
  to mint, and Meta adds its own limits (R2).
- **Tests cite the ids** (SR-01, SR-02, SR-39): the 21st session from one
  IP in an hour is refused; the 201st turn in a day is refused; two
  addresses in one /64 count as one source; reaching the slice switches
  mode with no model call; a session without a valid token is refused;
  the test-key path runs in CI.

## Consequences

- The owner provides a free Cloudflare account with one Turnstile widget
  covering the production and rehearsal hostnames; the secret key goes to
  the production secret set, the test keys to the rehearsal set.
- Cloudflare becomes a processor of the visitor's IP at session start;
  disclosed on the page. If that ever becomes unacceptable, option 2
  (self-hosted proof of work) is the fallback and this ADR is superseded.
- Facts to re-verify at implementation: Turnstile's free tier and widget
  limits, the published test keys, the `siteverify` endpoint, the data the
  widget collects.
- **Schedule (2026-11-09, owner-approved):** the per-IP limits and the
  monthly cap's pause ship in the MVP; Turnstile (SR-39) ships in the first
  slice after the MVP (design §9.2, M2), before any traffic push, and is
  verified then with tests; the daily slice and economy mode at M3 with
  FR-14. Until Turnstile ships, SR-01 alone gates session creation and the
  CSP has no third-party origin.
