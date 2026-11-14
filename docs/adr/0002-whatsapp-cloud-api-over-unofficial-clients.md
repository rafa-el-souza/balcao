# ADR-0002: Official WhatsApp Cloud API over unofficial clients

**Status:** accepted · **Date:** 2026-11-02 · The choice of the Cloud API
superseded by [ADR-0016](0016-telegram-bot-api-as-the-messaging-channel.md)
on 2026-11-14 (WhatsApp's business policy forbids messaging that
facilitates the exchange of drugs); the rejection of unofficial clients
stands.

## Context

Freelance adverts split between the official Meta platform and unofficial
WhatsApp Web automation (Baileys and similar). The demo number will be
public and must stay up for months.

## Options

1. **WhatsApp Cloud API (Meta).** Free API access; inbound and service
   replies inside the 24-hour window free up to a monthly allowance per
   number (verify the current figure; 1,000/month at the time of writing);
   250 conversations per day without business verification; needs a
   dedicated phone number, Meta Business Manager setup and display-name
   approval. Test numbers only reach five registered recipients.
2. **Unofficial client (Baileys).** No setup with Meta, any number; against
   WhatsApp's terms, session corruption and bans are routine (a paid advert
   in the research was exactly that debugging job). Unacceptable for a
   public demo that must not die.
3. **A BR gateway SaaS (Evolution API, Z-API and similar).** Adds a vendor
   and a monthly fee to hide option 1 or 2; nothing to learn that a client
   would pay for.

## Decision

Option 1, with the honest trade-off written down: setup is bureaucratic and
on Meta's clock, so it runs as a parallel lane (ADR-0004). Template
messages are never sent in V1 (they cost money and need approval); the
service window is enough for a demo.

## Consequences

- A prepaid SIM dedicated to the bot, never registered on the consumer app.
- The Business Manager experience itself becomes something the author can
  speak to in proposals (a recurring paid task in the market).
- The transport port must tolerate the channel arriving late; the web
  channel is the reference implementation.
