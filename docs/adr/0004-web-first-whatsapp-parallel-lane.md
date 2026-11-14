# ADR-0004: Web channel first, WhatsApp on a parallel lane

**Status:** accepted · **Date:** 2026-11-02 · The WhatsApp lane amended by
[ADR-0016](0016-telegram-bot-api-as-the-messaging-channel.md) on
2026-11-14: Meta never approved, as this ADR allowed for, and the messaging
channel is Telegram; web first stands.

## Context

WhatsApp is the channel clients recognise, but Meta's setup (business
manager, number registration, display-name approval) takes days to weeks
and is outside our control. A demo that waits for Meta ships late; a demo
without WhatsApp loses its strongest hook.

## Options

1. **WhatsApp first.** Blocks everything on Meta's clock.
2. **Web only in V1, WhatsApp in V2.** Ships fast; risks the adapter being
   bolted on and the transport abstraction being fiction.
3. **Web first, transport port designed in from day one, WhatsApp adapter
   developed when the number is ready, merged whenever Meta approves.**

## Decision

Option 3. The Meta lane (SIM, Business Manager, number, display name) starts
on day one. The web adapter is the reference implementation of the port and
ships first (MVP days 1–10, design §9.1). The WhatsApp text adapter follows
inside the MVP (days 11–12) and voice notes at M4 (schedule of 2026-11-09);
it is developed against recorded Meta payloads and a sandbox test number,
and switched on by configuration when the registered number exists.

## Consequences

- The landing page launches with "try it in the browser" and gains the QR
  code later without redesign.
- The port interface is tested by two implementations, which is what makes
  it real.
- If Meta never approves (restriction, verification demands), the project
  still stands on the web channel, and the ADR records why the QR is
  missing.
