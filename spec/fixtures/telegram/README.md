# Telegram updates for the specs

Recorded on 2026-11-14 from the demo bot, `@BalcaoDemoBot`, on the owner's
phone, before the webhook existed: read with `getUpdates` outside the
repository, then committed with invented values in place of the real ones
(threat model SR-33). Invented: every `update_id`, the user's and the chat's
id, the first name, the file ids, the sticker's set and the dates (shifted,
their spacing kept); the app's language is set to `pt-br`. The rest is as
Telegram sent it, fields and types included.

| File | What was sent |
|---|---|
| `start.json` | the Start button (`/start`) |
| `text.json` | "Vocês têm dipirona?" |
| `agree.json` | "Concordo" |
| `help.json` | `/help` |
| `photo.json` | a photo, no caption |
| `emoji.json` | an emoji, which Telegram sends as text |
| `voice.json` | a voice message of about two seconds |
| `edited_message.json` | the second message, edited |
| `photo_caption.json` | a photo with a caption |
| `sticker.json` | an animated sticker |

The specs derive what a private chat with the bot cannot record from these,
one field changed: a group's message, a bot's, another chat's, a shared
contact, a text over 1,000 characters.
