# ADR-0008: No styled component library; design tokens first, headless primitives allowed

**Status:** accepted · **Date:** 2026-11-02

## Context

The owner wants a bespoke visual identity that does not read as the default
look of AI-generated front ends. The concern on the other side is cost: a
choice that makes the implementation painful would be worse than a generic
look. The public UI surface is small: landing, chat with a live panel, a
read-only trace page, a read-only bookings list, a status page with a few
numbers. The operator console is internal and server-rendered.

## Options

1. **Styled component library (MUI, shadcn/ui, Tailwind UI, Chakra).**
   Fast for form-heavy admin apps; carries its look everywhere, and
   overriding it costs more than writing the few components we need.
   Swapping it out later is a rewrite.
2. **Utility CSS with defaults (Tailwind as shipped).** Not a look by
   itself, but its defaults are the look everyone recognises; needs a
   custom theme to avoid that, at which point the gain is small.
3. **Own CSS with design tokens (custom properties) and CSS Modules; a
   headless, unstyled primitive library only where accessibility is hard
   (dialog, menu, tabs, tooltip).** Small surface, full control, the
   tokens are the design system. Headless primitives bring no look, so
   adding or removing them later is additive, not a rewrite.
4. **No libraries at all, hand-rolled widgets.** Accessible dialogs and
   menus are harder than they look; false economy.

## Decision

Option 3. Concretely:

- `web/src/styles/tokens.css` defines colour, type scale, spacing, radius
  and motion as custom properties; components use tokens, never raw values.
  The design session edits tokens and component CSS, nothing else.
- CSS Modules per component; no global utility framework.
- A headless primitive library (unstyled, accessibility-focused) is allowed
  for dialog, menu, tabs and tooltip; it is not required until a widget
  needs it.
- Charts on the status page are inline SVG from our own small component; at
  most one sparkline per metric.
- The operator console is Rails server-rendered with a single plain
  stylesheet reusing the same tokens; it may use a classless base
  stylesheet for speed.
- Where the chat and trace panel need virtualisation or scrolling
  behaviour, a small focused utility is preferred over a UI kit.

## Why this is the cheap choice, not the expensive one

The expensive mistakes are the ones that force a rewrite: adopting a styled
kit and later fighting it, or dropping one after the UI is built on it.
Tokens plus own CSS plus headless primitives has no such cliff: if during
development a widget turns out hard, the primitive is added for that widget
alone. The surface is five pages with roughly a dozen components; a
component library would not save a day on it.

## Consequences

- Implementation writes about a dozen components with their own CSS; the
  MVP's day-1 skeleton ships with tokens and a neutral placeholder look.
- The design session (after day 2) changes tokens and component CSS; it does
  not restructure components.
- Accessibility (NFR-10) is the implementer's job for everything not
  covered by a primitive: focus order, contrast via tokens, reduced-motion
  media query, keyboard for the composer and the panel.
- Revisit if the surface grows beyond the five pages (e.g. a real
  operator back office); then a headless kit across the board, still not a
  styled one.
