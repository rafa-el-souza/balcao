# ADR-0016: Telegram's Bot API as the messaging channel

**Status:** accepted · **Date:** 2026-11-14 (decided with the owner after a
survey of Telegram, Signal and the routes left on WhatsApp; the sources
were read that day and are listed at the end) ·
Supersedes ADR-0002's choice of the WhatsApp Cloud API (its rejection of
unofficial clients stands) and amends ADR-0004's lane, ADR-0011's words on
the demo's secrets, ADR-0012's WhatsApp line and ADR-0013's risk list ·
Extended by
[ADR-0017](0017-the-telegram-bot-stays-a-text-channel.md) (what the bot
uses of the platform).

## Context

ADR-0002 chose the official WhatsApp Cloud API, and ADR-0004 ran it as a
lane beside the web channel with a fallback written down: if Meta never
approves, the project stands on the web channel and an ADR records why. On
2026-11-14 the setup on Meta's side did not go through, and Meta's
published rules close the official route for this project anyway. The
WhatsApp Business Messaging Policy (updated 2026-09-23) forbids using
WhatsApp for "buying, selling, promoting, or otherwise facilitating the
exchange of" items that include "Drugs, whether prescription, recreational,
or otherwise" and "Medical and healthcare products", "irrespective of the
global or local licenses, registrations, or other approvals your business
may hold". Its one exception, over-the-counter medicine in Brazil, needs a
licence a fictional pharmacy cannot hold. An attendant that looks up stock
and reserves products facilitates exactly that exchange, and the rule holds
for every official route: the Cloud API directly and the Business Solution
Providers that onboard numbers into it.

A messaging channel still matters: the small-business client of §1.1
recognises a messaging app before a web page, and the transport port needs
its second implementation to be real (ADR-0004). Whatever replaces
WhatsApp must keep what FR-19 and the threat model asked of it: inbound
events authenticated before parsing and deduplicated (SR-06, SR-07),
visitor identities hashed with the pepper and never logged (SR-10, SR-30),
replies only (§2.2), voice notes fetched by id through an official API
(SR-22), months unattended on one VM (G5, ADR-0006).

## Options

1. **Telegram's Bot API.** Official and free.
   - **The bot.** It is created inside Telegram (BotFather) with no
     business verification, and "Bots can't start conversations with
     users".
   - **Inbound.** Webhooks arrive over HTTPS (IPv4 only) with a secret the
     bot chose in the `X-Telegram-Bot-Api-Secret-Token` header; every
     update has a unique `update_id` and is kept up to 24 hours while
     undelivered.
   - **Identity and voice.** A visitor is a stable numeric id; the phone
     number never arrives unless the visitor shares a contact. Voice notes
     are fetched by file id (`getFile`), up to 20 MB.
   - **The developer terms.** They require a privacy policy (Telegram's
     standard one forbids passing user data to third parties, and the
     model provider is one) and user data "encrypted at rest and stored
     separately from its encryption key". They keep a bot's data to what
     is "essential for the operation of your services", always prohibit
     "any form of data collection aimed at creating large datasets,
     machine learning models and AI products", and let a bot use what
     users send it "provided that you clearly inform them of the data's
     intended use and they give their individual, explicit, active and
     revocable consent". They forbid "regulated" goods without defining
     the word.
   - **What the platform asks of a bot.** To answer `/start` and `/help`
     ("We require all developers to support several Global Commands") and
     to "respond to all messages that are sent to your bot".
   - **What comes with it.** Telegram's own ads "may appear in large
     public channels, bots, public stories and public search", in a bar
     above the chat with a bot. Its pages speak of popular bots and give
     no number; the one switch they document is for channels, and none
     for a bot's owner.
   - **In Brazil.** Installed on 57 % of smartphones, against WhatsApp's
     99 % (Mobile Time and Opinion Box, fieldwork of January 2025); courts
     ordered two suspensions, in 2022 (revoked before it took effect) and
     in 2023 (three days).
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
4. **Try again on Meta's side.** Meta's clock, and a setup that goes through
   leaves the policy above in force.
5. **Web only,** ADR-0004's fallback: no messaging channel, and the port
   keeps a single implementation.

## Decision

Option 1. Telegram's Bot API replaces the WhatsApp Cloud API as the
messaging channel: MVP days 11 and 12 (design §9.1) build its inbound and
outbound adapters, and the voice notes of M4 arrive on the same bot. No new
attempt on Meta's side is planned. Signal and unofficial WhatsApp clients
stay out of this project. How much of the platform the bot uses is a
decision of its own, ADR-0017.

## Consequences

- FR-19 becomes the Telegram channel. The §2.2 non-goal that kept Telegram
  out now keeps WhatsApp, Instagram and Signal out, and J2, FR-05, FR-10's
  operator-reply rule, FR-11 and FR-12 follow (design §10, note
  2026-11-14).
- The threat model's S2 is the Telegram webhook:
  - SR-06 compares the secret header in constant time; it is a shared
    secret, not a signature of the body, so a leaked secret works until
    the webhook is registered again with a new one;
  - SR-07 keys updates by `update_id`;
  - SR-08 is retired: Telegram has no verification handshake, and the id is
    not reused;
  - SR-10 hashes the Telegram user id with the pepper, and keeps the raw
    id, which a reply needs as its chat, on the visitor's row alone,
    encrypted;
  - SR-22 fetches media by file id from Telegram's file host, whose URLs
    carry the bot token, as every Bot API URL does, and are never logged;
  - the new SR-41 encrypts at rest what visitors send and the chat id a
    reply needs, the project's reading of the "user data" the terms want
    encrypted.
- `/privacy` (§6.7) is the bot's own privacy policy, set in BotFather,
  because Telegram's standard policy would forbid sending a message to the
  model; it names Telegram among the processors, and it says that the bot
  asks for agreement first and that the delete command erases the server's
  copy while the chat in the visitor's app stays the visitor's to clear.
- What the platform asks of a bot becomes requirements: FR-19 answers
  `/start`, `/help` and every message a person sends in a private chat, a
  photo included, short of a flood (ADR-0017).
- The bot asks before it reads (the owner, 2026-11-14). The terms' consent
  sentence, read strictly, covers the everyday use of a message: sending
  it to the model provider to answer. So a person the bot does not know
  gets, on the first message, Start included, the demo notice, what
  happens to a message and one button to agree; nothing of that person is
  stored and no model is called until the tap, and the delete command
  withdraws the agreement (FR-19). The web chat keeps its notice and its
  privacy page: the step answers Telegram's terms.
- No Telegram conversation becomes an eval case in V1: the console's
  action (FR-16, M2) is not offered for the channel. Under the terms a
  case would be at best one more use that needs its visitor's consent, and
  at worst the collection they always prohibit; and a case committed to a
  public repository cannot be taken back.
- ADR-0012's line "WhatsApp is unaffected" reads for Telegram: a Telegram
  account needs a phone number to exist, so identities stay costly to mint,
  and Telegram adds its own limits (R2).
- ADR-0013's risk list reads "the Telegram webhook and the Bot API
  client" where it says "the WhatsApp webhook and the Graph API client".
  Where ADR-0011 speaks of "the demo number's Meta values", read the bot
  token and the webhook secret.
- The landing's QR opens the bot, and its stack line names the Telegram Bot
  API. The freelance audience of §1.1 loses the channel Brazilian shops
  actually serve on; that cost is accepted.
- The channel is another company's platform, and three things can take it
  away or change its face: Telegram reading its terms against the demo
  ("regulated" goods, the reach of "user data"), a court suspending
  Telegram in Brazil again, and Telegram's own ads above the chat.
  Accepted (threat model R9): the bot says it is a demo before the first
  message, and the project stands on the web channel alone, as ADR-0004
  planned, the day the bot goes.
- What the owner does by hand shrinks to BotFather: creating the bot,
  pasting its token into the env file, setting the privacy-policy URL and
  the photo, and keeping the bot out of groups. The webhook, the bot's
  profile and its command menu are set by one task of the repository
  (ADR-0017).

## Sources (read 2026-11-14)

- WhatsApp Business Messaging Policy: https://whatsappbusiness.com/policy/
- WhatsApp Terms of Service: https://www.whatsapp.com/legal/terms-of-service
- WhatsApp Help Center, unofficial apps:
  https://faq.whatsapp.com/1217634902127718
- Telegram Bot API (version 10.4 of 2026-11-09):
  https://core.telegram.org/bots/api, and the bots' introduction ("Bots
  can't start conversations with users"): https://core.telegram.org/bots
- Telegram Bot Features (global commands, status alerts):
  https://core.telegram.org/bots/features
- Telegram Bot Platform Developer Terms of Service:
  https://telegram.org/tos/bot-developers, and the Standard Bot Privacy
  Policy: https://telegram.org/privacy-tpa
- Telegram's ads: the FAQ, https://telegram.org/faq; how apps show them
  in a chat with a bot, https://core.telegram.org/api/sponsored-messages;
  the channels' switch,
  https://core.telegram.org/method/channels.restrictSponsoredMessages
- Signal Terms of Service: https://signal.org/legal/; signal-cli:
  https://github.com/AsamK/signal-cli
- Messaging apps in Brazil, Panorama Mobile Time/Opinion Box, February
  2025: https://www.mobiletime.com.br/noticias/27/02/2025/telegram/
- The suspensions of Telegram in Brazil:
  https://www.cnnbrasil.com.br/nacional/alexandre-de-moraes-determina-bloqueio-do-telegram-no-brasil/
  (2022) and
  https://www.cnnbrasil.com.br/nacional/justica-federal-anula-decisao-que-suspendeu-funcionamento-do-telegram-no-brasil/
  (2023)
