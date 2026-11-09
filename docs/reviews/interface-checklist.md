# Interface checklist

What the interface review (ADR-0013) checks on every screen a pull request
creates or changes, derived from `docs/design-brief.md` and the wireframes
of `docs/design.md` §6.8. Each item says how it is verified: by an
assertion the verifier can write (Testing Library or Playwright, on roles,
text, attributes and computed styles, never pixels), by reading, or by a CI
measure that already exists. The design session that closes the brief into
`docs/visual-identity.md` revises this list; until then the brief wins
where they differ.

| # | Item | Source | Verified by |
|---|---|---|---|
| 1 | The screen shows the wireframe's content in the wireframe's order; nothing added, nothing missing, nothing moved without a decision | design §6.8 | reading the sketch against the DOM order |
| 2 | Every visible string comes from the three locale files; no literal user-facing string in code | NFR-09 | Grep of `web/src/`; the locale-key parity check in CI |
| 3 | The longest locale (pt-BR or es, up to 30 % longer than en) fits at 390 px with no overflow, truncation or layout change | brief §4 | screenshot at 390 px per locale; assertion on `scrollWidth` |
| 4 | The language switcher is in the header on every page and keeps the current route | design §6.7 | Playwright assertion |
| 5 | Light paper theme: surface and text come from the `paper` and `ink` tokens, never white on black or raw hex outside `tokens.css` | brief §4, ADR-0008 | Grep of CSS Modules for colour literals |
| 6 | Two faces only, both self-hosted: the counter face for the conversation, landing and calendar; the mono instrument face with tabular figures for the glass box, trace and status. Never Inter, Roboto, Arial or `system-ui` as the text face; no font CDN | brief §5, SR-03 | computed `font-family` assertion; Grep for `@font-face` sources |
| 7 | Glass box visible by default beside the chat on desktop; a drawer with a one-line summary bar always visible at 390 px | brief §4 | Playwright assertion at both widths |
| 8 | Four message voices (visitor, attendant, pharmacist, system notice) distinguishable without avatars | brief §5 | DOM roles and class assertions |
| 9 | The one-line Turnstile notice under the chat composer, in the three locales | FR-18, brief §5 | text assertion |
| 10 | Empty, loading and error states exist and are reachable on every screen that loads data (chat, trace, calendar, status) | this list's own rule (ADR-0013) | Testing Library assertions with the fake adapter |
| 11 | The bookings list highlights new rows and the status page shows mode and spend with the meaning colours | design §6.8 | assertions on attributes and tokens |
| 12 | Meaning colours (normal, economy, paused, error, success) carry meaning and nothing else; sparkline and spend bar derive from the same ramp | brief §5 | reading the CSS; Grep for the tokens' uses |
| 13 | Keyboard reaches every control in a sensible order with a visible focus ring; no focus trap; skip link where a page has a long header | NFR-10 | Playwright keyboard walk |
| 14 | Roles and names right for assistive technology: landmarks, headings in order, labelled controls, live region for new trace rows and messages | NFR-10 | axe-core pass in CI; role assertions |
| 15 | `prefers-reduced-motion` turns off the 120 ms fade and the online-dot pulse; nothing slides across the screen | brief §5 | computed style assertion under emulated preference |
| 16 | Contrast at AA for text and 3:1 for UI against the tokens' values | brief §5, NFR-10 | contrast computed from `tokens.css`; axe-core |
| 17 | Touch targets at least 44 px on the chips, the composer button, the switcher and the drawer handle | this list's own rule, from the brief's §2 phone reader | bounding-box assertion at 390 px |
| 18 | 200 % zoom keeps every control reachable and every text readable | brief §7 | Playwright at 200 % |
| 19 | Dates, times and money formatted for the locale and in America/Sao_Paulo | design §1.4 | text assertions with a frozen clock |
| 20 | None of the banned list: gradients, floating cards on grey, hero with three icon cards, round avatars, glassmorphism, emoji in headings, drop shadows everywhere, generic icon sets, "✨", feed-shaped skeletons, pill-shaped everything | brief §6 | reading the screenshots and the CSS |
| 21 | Footer signature on the public pages: name, GitHub, LinkedIn; no photo | brief §4, FR-25 | text and link assertions |
| 22 | First-visit transfer under 300 KB excluding fonts; Lighthouse accessibility and best practices at 100 | NFR-10 | the CI size check and the NFR-10 gate |
