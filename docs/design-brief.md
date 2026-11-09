# Balcão — visual design brief

**Status:** v1.1, 2026-11-04 (Turnstile notice line added to the chat components; font note cites SR-03); v1 2026-11-02. For the design session that runs after the
MVP's placeholder is live (day 2) and the chat (days 6–7) is taking shape. The
session starts from this file and the documents it points to; nothing else
is assumed.

## 1. What you are designing

Five public screens and one internal console, specified in
`design.md` §6.7 (routes), §6.8 (text wireframes, binding for content and
order) and the design direction block in §6.7 (binding). The technical
ground is `adr/0008-no-styled-component-library.md`: own CSS over design
tokens, CSS Modules, headless primitives only where a widget needs them.
Requirements that touch design: NFR-09 (three languages) and NFR-10
(accessibility and footprint).

You change `web/src/styles/tokens.css` and the CSS of components. You do
not restructure components, add UI libraries, or change what a screen
contains. If a sketch in §6.8 cannot work visually, say so and propose the
change; the design document is edited first, then the screen.

## 2. Who looks at it, and for how long

- A hiring manager for a backend role, five minutes, desktop, often from a
  link in Slack or LinkedIn. Decides in the first screen whether this is
  "another chatbot" or something built with judgement.
- A small-business owner, on a phone, from a QR code or a freelance
  profile. Decides whether it looks like something they would put their
  business name on.
- The owner himself, in the console, daily for a minute.

The glass box is the hook for the first; the counter is the hook for the
second. Both must be visible in the first screen of `/chat`.

## 3. The concept: the counter

A neighbourhood pharmacy counter in Belo Horizonte. Not a hospital, not a
startup, not a lab. Things that belong to that world and may inform the
design: prescription-pad paper, the typography of package inserts and
price tags, the handwritten reservation slip, the green cross as a nod in
a corner, the glass counter itself. Things that do not: stock photos of
smiling pharmacists, blue medical gradients, pill icons, a mascot.

Two registers share every screen:

- **The counter** — the conversation, the landing, the calendar. Warm,
  paper-light, generous spacing, a text face with character. This is
  where a visitor feels served.
- **The instrument** — the glass box, the trace page, the status page.
  Cool, precise, monospaced numbers, tight rows, nothing decorative. This
  is where an engineer feels respected.

The design is the contrast between the two, on one screen, without a
border fight: the instrument sits beside the counter like a receipt
printer beside a till.

## 4. Decisions already made (do not reopen)

- Light theme. Paper, not white; ink, not black.
- Glass box visible by default on desktop, side by side; drawer with a
  one-line summary bar on narrow screens.
- No illustration, no photography in V1. Type and colour do the work.
- Pharmacy aesthetics as inspiration, not costume.
- Footer signature: name, GitHub, LinkedIn. No photo.
- Three languages everywhere, switcher in the header, text may be 30%
  longer in Portuguese and Spanish than in English: design for the
  longest.
- No styled component library; tokens first.

## 5. What to decide in the session, with starting points

**Typography.** Two families, both open-licensed and self-hosted (no font
CDN: SR-03's CSP allows no third-party origin but Turnstile's; fonts sit
outside NFR-10's 300 KB budget, so two weights per family at most is a
taste rule, not a budget rule):

- Counter face: something with warmth and a bit of print history. Explore
  a humanist serif or a grotesque with character; candidates to try, not
  a shortlist: Literata, Source Serif, Fraunces (sparingly, for display),
  Public Sans. Reject Inter, Roboto, Arial, system-ui as the primary face.
- Instrument face: a monospace with tabular figures that reads well at
  13–14 px in dense rows: JetBrains Mono, IBM Plex Mono, Commit Mono.
- Type scale: a small one, five sizes, named in tokens.

**Colour.** Build the palette in tokens with these roles: paper (surface),
paper-2 (raised), ink, ink-2 (secondary), rule (hairlines), accent (the
pharmacy green, used sparingly: links, the online dot, the primary
button), and the meaning colours for modes and states: normal, economy,
paused, error, success. Derive the data colours for the status sparklines
and the spend bar from the same ramp (no separate "chart palette", no
teal or any hue foreign to the page); validate contrast at AA for all text
and at 3:1 for UI. Two standing rules from the owner: one clear view beats
two overlapping; meaning colours carry meaning and nothing else.

**Rhythm and density.** The counter breathes; the instrument is dense but
never cramped: 4 px baseline, rows of 24–28 px in the glass box.

**Motion.** Trace rows appear in place with a 120 ms fade; nothing slides
across the screen; `prefers-reduced-motion` turns it all off. The
"online" dot may pulse once on state change, never continuously.

**Components, in order of importance:** the glass-box row (expanded and
collapsed states, the guardrail row, the cache hit/miss mark, the cost
figure), the message bubble (visitor, attendant, pharmacist-human, system
notice — four voices, no avatars), the composer with chips, the one-line
Turnstile notice under the chat (FR-18: Cloudflare runs the check and sees
the visitor's IP), the live numbers strip, the status tiles and spend bar, the bookings list with the
"new" highlight, the language switcher, the header, the footer signature,
the console table and reply box.

## 6. The banned list

If any of these appears, the design has drifted into the default look of
AI-generated front ends. Treat as a bug:

purple or blue gradients; Inter/Roboto/system-ui as the text face;
rounded cards floating on a grey background; a hero with three feature
cards and icons; chat bubbles with round avatars; glassmorphism, blur
panels; emoji in headings; drop shadows on everything; a dark hero over a
light page; decorative icons from a generic icon set; "✨" anywhere;
skeleton loaders shaped like a social feed; pill-shaped everything.

## 7. Deliverables and rhythm

1. **Tokens first.** `tokens.css` with the roles above, applied to the
   existing skeleton. Screenshot of `/chat` with real data.
2. **Static clickable prototype** of three screens — landing, chat with
   glass box, status — as plain HTML and CSS in `docs/prototype/`
   (no build step, opens from the file system) in the three languages,
   desktop and 390 px wide. Reviewed screen by screen with the owner; one
   round of changes. This is the cheap moment: the owner looks hard here,
   because after step 3 every change costs real work.
3. **Applied CSS** in the app for all six screens; the Playwright run of
   J1 still green; Lighthouse accessibility and best-practices at 100,
   first-visit transfer under 300 KB excluding fonts.
4. **A one-page `docs/visual-identity.md`**: the concept in a paragraph,
   the two faces, the palette with roles and contrast ratios, the banned
   list, and three screenshots. It replaces this brief when the session
   closes.

Session checklist before calling a screen done: three languages, 390 px
and 1280 px, keyboard only, reduced motion, 200% zoom, contrast checked,
no banned item, the sketch's content order respected.
