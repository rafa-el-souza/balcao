# ADR-0017: The Telegram bot stays a text channel: one update type in, plain text out

**Status:** accepted · **Date:** 2026-11-14 (after a survey of the Bot API's
reference, version 10.4, and of the platform's guides and terms, kept
outside the repository; the pages were read that day and are listed at the
end) · Extends [ADR-0016](0016-telegram-bot-api-as-the-messaging-channel.md).

## Context

ADR-0016 made Telegram's Bot API the messaging channel. The Bot API is far
more than a way to send text: version 10.4 has 193 methods and 29 kinds of
update, and 2026 alone brought replies streamed as drafts, rich messages
with tables and buttons, HTML widgets inside a message, topics inside a
private chat and bots that answer for a personal account. A pharmacy's
attendant could use many of them, and each one costs along the same four
lines:

- **What comes in.** Every kind of update is one more input that a
  stranger's device writes and the webhook must read: a button's callback
  ("the message originated the query can contain no callback buttons with
  this data"), a reaction, the "stop" of a streamed draft, a widget's
  request. The webhook is on the review policy's risk list (ADR-0013).
- **What the model's words become on a visitor's screen.** Under a parse
  mode a reply can hide a link behind an innocent word, and MarkdownV2
  refuses a whole message over one unescaped character out of eighteen.
- **Which apps can draw it.** The reference names no minimum app version
  for any feature. An app older than widgets shows "unsupported media";
  for drafts, topics, date entities and rich messages nothing says what an
  older app shows.
- **What the terms allow.** Data only as far as it is "essential for the
  operation of your services", and nothing that would "misrepresent the
  services or functions" of a bot whose pharmacy does not exist.

The platform also asks two things of every bot: to answer `/start` and
`/help` ("We require all developers to support several Global Commands"),
and to "respond to all messages that are sent to your bot". A bot that
only passes text to the model does neither: it has no help, and it meets a
photo with silence.

## Options

1. **Text and nothing else.** One update type, `sendMessage`, no profile
   and no menu. The least code and the least surface. It leaves out what
   the platform asks of every bot, leaves a visitor who sends a photo
   without an answer, and shows nothing of the bot before the first
   message, where the demo notice matters most.
2. **The native AI bot.** What the platform now offers a bot that fronts a
   model: replies streamed as drafts with a stop button, rich messages,
   inline buttons with callbacks, topics, a Mini App for the trace. The
   best first impression on a current app. It puts more kinds of update
   on the webhook (a callback, a stop), shows a reply before the guardrail
   has read it (FR-20), draws the model's Markdown on the visitor's
   screen, and splits the pipeline in two, since the web chat shows a
   reply whole.
3. **A rule, and the short list it yields.** The bot stays a text channel,
   and a feature of the platform enters only when it passes the tests
   below.

## Decision

Option 3. A feature of the platform enters the bot when all five hold:

1. **It adds no kind of update.** The webhook asks Telegram for `message`
   updates alone and drops any other. A button, where one helps, either
   sends ordinary text down the path every message takes (a reply
   keyboard) or acts on the visitor's own device (copies a text, opens a
   link). A feature that needs another kind of update needs its own ADR
   and its row in the threat model.
2. **The model's words leave as plain text.** No parse mode over text the
   model or a visitor wrote, and no link preview. Formatting, where it
   earns its place, is for the fixed texts the application writes, given
   as explicit entities.
3. **Any app in use draws it.** A feature the apps have had for years, or
   one an older app degrades to plain text.
4. **It takes no more data and pretends nothing.** No request for a phone
   number or a location, no file fetched other than a voice note (FR-11),
   nothing that would send a person to a pharmacy that does not exist.
5. **Both channels send the same reply.** A reply is written once, checked
   once (FR-20) and then sent; the evals score one pipeline.

What the rule lets in, and when (design §9):

| When | Feature | What it serves |
|---|---|---|
| MVP, days 11 and 12 | The bot's profile in the three languages: its name, its description (shown in the empty chat, before Start) and its short description; a profile photo | FR-01's notice before the first message; the terms' "must not misrepresent" |
| MVP | The command menu in the three languages; `/start` and `/help` answered with fixed texts | FR-04, FR-05, FR-12; the platform's global commands |
| MVP | The typing status while a turn runs | NFR-03's "pensando…" |
| MVP | One fixed line in answer to a photo, a sticker, a document, a voice note (until M4) or anything else that is not text; no file is fetched | "respond to all messages" |
| MVP | Private chats only: the bot kept out of groups in BotFather, and the webhook ignoring any chat that is not private | §2.2; threat model SR-42 |
| M4, its first slice | A button that copies the reservation code; the three openers as a reply keyboard under the greeting; a button that opens the trace | FR-07, FR-21, FR-12 |
| M2, with FR-08 | The offered slots as a reply keyboard | FR-08 |
| M5, with FR-23 | The deep link's parameter as the visit's source | FR-23 |

What it keeps out, each with the test it fails or the reason that settles
it first:

- **Replies streamed as drafts, and the stop button.** Test 5: a visitor
  would read the text the guardrail was about to replace, and the tags and
  fixed lines the application handles once the model has finished. Test 1:
  the stop is an update of its own. The developer terms also still tie
  "the streaming of message drafts" to enabling topics, while the
  changelog opened the method to all bots; only Telegram can settle that.
  This is the one worth reopening, with an ADR, for both channels at once.
- **A parse mode or rich messages over the model's text.** Test 2, and for
  rich messages test 3.
- **Inline buttons with callbacks.** Test 1.
- **A Mini App** for the trace, the calendar or the whole chat. Its script
  comes from telegram.org, and ADR-0012 keeps Cloudflare the page's only
  third party; a button that opens the trace page gives nearly the same.
- **HTML widgets.** Tests 1 and 3: an update of their own, and a feature
  released five days before this was written.
- **Topics in the private chat.** Test 3; and a customer's chat with a
  neighbourhood shop is one thread.
- **Reactions.** The bot's own says what the typing status already says.
  A visitor's, kept as a rating, fails test 1, and ratings kept to improve
  a model need the consent ADR-0016 quotes.
- **Asking for a location or a phone number, and reading photos.** Test 4:
  a photo of a prescription or of a box is health data, and it would carry
  the clinical boundary (FR-09) into images.
- **A map pin or a contact card of the pharmacy.** Test 4: the address is
  invented, in a real neighbourhood, and so is the phone.
- **Deleting the chat from the visitor's app on the delete command.** That
  copy is the visitor's, and Telegram lets a bot delete only the last 48
  hours of it. The command erases the server's copy, and `/privacy` says
  where the other one lives.
- **A bot that answers for a personal or business account.** The demo's
  bot is the shop itself, and the terms forbid disclosing what arrives
  that way "to third parties (including third-party APIs) without the
  user's authorization".
- **Payments, Login with Telegram, inline and guest modes, groups and
  channels.** Non-goals already (design §2.2): no payments, one visitor in
  one conversation, no sign-up.

## Consequences

- FR-19 says what the bot does with each kind of message, in scenarios.
  `config/commands.yml` gains `start` and `help`, matched before the model
  like the other commands and on both channels, and the locale files gain
  the bot's texts.
- What the bot shows of itself (its name, its descriptions, its menu) and
  its webhook are set by one task of the repository, from tracked files,
  so they are reviewed and repeated like any change (FR-26's idea, for the
  bot). What stays in BotFather is what only BotFather has: the bot's
  creation, its token, its privacy-policy URL and the switch that keeps it
  out of groups.
- The threat model gains SR-42 (private chats and `message` updates only)
  and SR-43 (plain text out, no link previews).
- The delivery plan gains a slice: M4 opens with the bot's finish (design
  §9.2).
- A visitor on a current app sees a plainer bot than the platform could
  draw: no streaming, no rich text, a few plain buttons. Accepted: the
  glass box is the web page's show, and the bot's job is to be the same
  attendant where a client already is.
- Two questions stay for the milestones that own them: whether the booked
  time carries a date entity the visitor's calendar can take (M2, with
  FR-08, once an app has shown how it reads), and whether the operator's
  alert goes through the bot instead of a push service (M2, with FR-10).

## Sources (read 2026-11-14)

- Telegram Bot API, version 10.4 of 2026-11-09 (`Update`, `setWebhook`,
  `sendMessage`, `LinkPreviewOptions`, `sendChatAction`, `setMyCommands`,
  `setMyDescription`, `CopyTextButton`, `ReplyKeyboardMarkup`,
  `sendMessageDraft`, the MarkdownV2 style): https://core.telegram.org/bots/api,
  and its changelog: https://core.telegram.org/bots/api-changelog
- Telegram Bot Features (commands and global commands, keyboards, deep
  linking, status alerts, the BotFather settings):
  https://core.telegram.org/bots/features
- HTML widgets: https://core.telegram.org/bots/widgets
- Telegram Bot Platform Developer Terms of Service (4.3, 5.2, 5.4, 6.2.6):
  https://telegram.org/tos/bot-developers
