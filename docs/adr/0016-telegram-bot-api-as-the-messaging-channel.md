# ADR-0016: Telegram's Bot API as the messaging channel, after Meta's refusal

**Status:** accepted · **Date:** 2026-11-14 (decided with the owner after a
survey of Telegram, Signal and the WhatsApp routes left after Meta's
refusal; the sources were read that day and are listed at the end) ·
Supersedes ADR-0002's choice of the WhatsApp Cloud API (its rejection of
unofficial clients stands) and amends ADR-0004's lane, ADR-0012's WhatsApp
line and ADR-0013's risk list.

## Context

ADR-0002 chose the official WhatsApp Cloud API, and ADR-0004 ran it as a
lane beside the web channel with a fallback written down: if Meta never
approves, the project stands on the web channel and an ADR records why. On
2026-11-14 Meta did not approve the business account that held the demo
number, and disabled it. Whatever the reason behind that one decision,
Meta's published rules close the official route for this project, not only
for this account:

- The WhatsApp Business Messaging Policy (updated 2026-09-23) forbids using
  WhatsApp for "buying, selling, promoting, or otherwise facilitating the
  exchange of" items that include "Drugs, whether prescription,
  recreational, or otherwise" and "Medical and healthcare products",
  "irrespective of the global or local licenses, registrations, or other
  approvals your business may hold". Its one exception, over-the-counter
  medicine in Brazil, needs a licence a fictional pharmacy cannot hold. An
  attendant that looks up stock and reserves products facilitates exactly
  that exchange.
- After a termination the same policy lets Meta "prohibit you and your
  organization from all future use of WhatsApp products and services", and
  WhatsApp's terms say the holder of a disabled account will "not create
  another account without our permission". A Business Solution Provider
  onboards a number into the client's own Meta business portfolio, which
  must not be disabled.

A messaging channel still matters: the small-business client of §1.1
recognises a messaging app before a web page, and the transport port needs
its second implementation to be real (ADR-0004). Whatever replaces
WhatsApp must keep what FR-19 and the threat model asked of it: inbound
events authenticated before parsing and deduplicated (SR-06, SR-07),
visitor identities hashed with the pepper and never logged (SR-10, SR-30),
replies only (§2.2), voice notes fetched by id through an official API
(SR-22), months unattended on one VM (G5, ADR-0006).

## Options

1. **Telegram's Bot API.** Official and free. A bot is created inside
   Telegram (BotFather) with no business verification, and "Bots can't
   start conversations with users". Webhooks arrive over HTTPS (IPv4 only)
   with a secret the bot chose in the `X-Telegram-Bot-Api-Secret-Token`
   header; every update has a unique `update_id` and is kept up to 24 hours
   while undelivered. A visitor is a stable numeric id; the phone number
   never arrives unless the visitor shares a contact. Voice notes are
   fetched by file id (`getFile`), up to 20 MB. The developer terms require
   a privacy policy (Telegram's standard one forbids passing user data to
   third parties, and the model provider is one), user data "encrypted at
   rest and stored separately from its encryption key", and "individual,
   explicit, active and revocable consent" before data is collected for
   "large datasets, machine learning models and AI products"; they forbid
   "regulated" goods without defining the word. Installed on 57 % of
   Brazilian smartphones, against WhatsApp's 99 % (Mobile Time and Opinion
   Box, January 2025); Brazilian courts ordered two suspensions, in 2022
   (revoked before it took effect) and in 2023 (three days).
2. **Signal through signal-cli.** No official bot or business API ("Use
   outside of Signal is unsupported", libsignal's README). Signal's terms
   forbid "bulk messaging, auto-messaging, and auto-dialing" and accounts
   created "through unauthorized or automated means". signal-cli (GPL-3.0,
   Java 25) ships monthly and a release older than about three months may
   stop working; in April 2026 the server deregistered accounts on old
   releases, and registration and rate-limit challenges need a captcha
   solved by a person. One more container on the host. Installed on 14 % of
   Brazilian smartphones.
3. **WhatsApp through an unofficial client** (Baileys and the gateways
   built on it). ADR-0002 rejected it, and its reasons stand with today's
   text: WhatsApp's terms forbid "auto-messaging" and "any non-personal use
   of our Services unless otherwise authorized by us", and its help centre
   warns that linking an account to an unofficial app, now or in the past,
   can ban it.
4. **Appeal and wait.** Meta's clock, and an appeal that succeeds leaves the
   policy above in force.
5. **Web only,** ADR-0004's fallback: no messaging channel, and the port
   keeps a single implementation.

## Decision

Option 1. Telegram's Bot API replaces the WhatsApp Cloud API as the
messaging channel: MVP days 11 and 12 (design §9.1) build its inbound and
outbound adapters, and the voice notes of M4 arrive on the same bot. No
appeal is planned. Signal and unofficial WhatsApp clients stay out of this
project.

## Consequences

- FR-19 becomes the Telegram channel. The §2.2 non-goal that kept Telegram
  out now keeps WhatsApp, Instagram and Signal out, and J2, FR-05, FR-10's
  operator-reply rule, FR-11 and FR-12 follow (design §10, note
  2026-11-14).
- The threat model's S2 is the Telegram webhook:
  - SR-06 compares the secret header in constant time; it is a shared
    secret, not a signature of the body, so a leaked secret works until it
    is rotated, and it rotates with the bot token;
  - SR-07 keys updates by `update_id`;
  - SR-08 is retired: Telegram has no verification handshake, and the id is
    not reused;
  - SR-10 hashes the Telegram user id with the pepper;
  - SR-22 fetches media by file id from Telegram's file host, whose URLs
    carry the bot token and are never logged;
  - the new SR-41 encrypts visitors' words at rest, as Telegram's terms
    require.
- `/privacy` (§6.7) is the bot's own privacy policy, set in BotFather,
  because Telegram's standard policy would forbid sending a message to the
  model; it names Telegram among the processors.
- A Telegram conversation becomes an eval case (FR-16, M2) only with its
  visitor's explicit consent, or not at all.
- ADR-0012's line "WhatsApp is unaffected" reads for Telegram: a Telegram
  account needs a phone number to exist, so identities stay costly to mint,
  and Telegram adds its own limits (R2).
- ADR-0013's risk list reads "the Telegram webhook and Bot API client"
  where it says "the WhatsApp webhook and Graph client". Where ADR-0011 and
  the threat model's A4b speak of the demo number's Meta values, read the
  bot token and the webhook secret.
- The landing's QR opens the bot, and its stack line names the Telegram Bot
  API. The freelance audience of §1.1 loses the channel Brazilian shops
  actually serve on; that cost is accepted.
- What the owner does in a browser shrinks to creating the bot in
  BotFather, pasting its token and a webhook secret into the env file, and
  setting the privacy-policy URL. Registering the webhook is one API call
  made with the token.

## Sources (read 2026-11-14)

- WhatsApp Business Messaging Policy: https://whatsappbusiness.com/policy/
- WhatsApp Terms of Service: https://www.whatsapp.com/legal/terms-of-service
- WhatsApp Help Center, unofficial apps:
  https://faq.whatsapp.com/1217634902127718
- Telegram Bot API (version 10.4 of 2026-11-09):
  https://core.telegram.org/bots/api
- Telegram Bot Platform Developer Terms of Service:
  https://telegram.org/tos/bot-developers, and the Standard Bot Privacy
  Policy: https://telegram.org/privacy-tpa
- Signal Terms of Service: https://signal.org/legal/; signal-cli:
  https://github.com/AsamK/signal-cli
- Messaging apps in Brazil, Panorama Mobile Time/Opinion Box, February
  2025: https://www.mobiletime.com.br/noticias/27/02/2025/telegram/
- The suspensions of Telegram in Brazil:
  https://www.cnnbrasil.com.br/nacional/alexandre-de-moraes-determina-bloqueio-do-telegram-no-brasil/
  (2022) and
  https://www.cnnbrasil.com.br/nacional/justica-federal-anula-decisao-que-suspendeu-funcionamento-do-telegram-no-brasil/
  (2023)
