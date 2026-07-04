---
version: alpha
name: my-island
colors:
  accent: "#7C6BFF"
  signal: "#FFB338"
  accent-warm: "#FF6B5C"
  accent-cool: "#3DDC97"
  background: "#0A0B0D"
  surface: "#15161A"
  surface-raised: "#1C1E23"
  text: "#E9E9EE"
  text-muted: "#83868F"
  text-faint: "#575A63"
  hairline: "#202128"
typography:
  title:
    fontFamily: "-apple-system, SF Pro"
    fontSize: "15px"
    fontWeight: 600
  body-md:
    fontFamily: "-apple-system, SF Pro"
    fontSize: "12.5px"
    fontWeight: 400
  label:
    fontFamily: "SF Mono"
    fontSize: "10px"
    fontWeight: 600
  data:
    fontFamily: "SF Mono"
    fontSize: "12px"
    fontWeight: 500
rounded:
  sm: "7px"
  md: "11px"
  lg: "16px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
components:
  panel:
    background: "#15161A"
    rounded: "11px"
    border: "#202128"
  button-primary:
    background: "#7C6BFF"
    color: "#F4F2FF"
    rounded: "7px"
  chip:
    background: "#1C1E23"
    color: "#83868F"
    rounded: "999px"
  attention-row:
    color: "#FFB338"
---

## Overview

my-island is a dark-first, always-on notch overlay — a quiet ambient strip that expands on hover into
a compact panel. The identity is **calm and precise**: near-black grounds, a single restrained indigo
accent, and amber held in reserve for one job only — the "needs you" attention signal. It should read
as considered instrument, not decoration; information-dense but never loud.

## Colors

- **accent** (`#7C6BFF`, indigo) — the identity color and every interactive/active affordance: primary
  buttons, now-playing accent, the pane-jump arrow on hover, selection. Kept low-saturation on black so
  it feels premium, not neon.
- **signal** (`#FFB338`, amber) — **reserved exclusively** for attention: the Claude "needs you" count,
  permission-waiting dots, warnings. Never used decoratively; it must always mean "act on this."
- **accent-warm** (`#FF6B5C`, coral) and **accent-cool** (`#3DDC97`, mint) — situational secondary
  accents for categorical distinctions only (e.g. timer states, session categories) when a second hue
  is genuinely needed. They never carry attention meaning (that is amber's alone) and never replace the
  indigo identity accent.
- **Neutrals** — warm-biased greys on near-black: `background` for the desktop/notch, `surface` and
  `surface-raised` for the panel and chips, `hairline` for low-contrast separators. `text` /
  `text-muted` / `text-faint` form a three-step legibility hierarchy.

## Typography

Two system families, no third-party fonts. **SF Pro** (`-apple-system`) carries UI titles and body
text; **SF Mono** carries data, numerals, and labels. Numeric values use tabular figures so digits stay
column-aligned as they tick. Labels are uppercase SF Mono with wide tracking (~0.12em) — the one place
letterspacing is deliberate.

## Layout

A 4px-base spacing scale (4 / 8 / 12 / 16 / 24) keeps density tight enough for a notch overlay. Corners
use the sm/md/lg rounding scale (7 / 11 / 16). Separators are single low-contrast hairlines, never heavy
rules — structure comes from spacing and grouping labels, not boxes.

## Components

- **Notch strip** (collapsed) — always populated: now-playing on the left, amber attention chip + clock
  on the right, flanking the physical notch. Never blank.
- **Panel** (hover-reveal) — `surface` card, md rounding, hairline border, grouped rows under uppercase
  mono labels.
- **Primary button** — indigo fill, sm rounding, used sparingly (e.g. "Join").
- **Chip** — pill on `surface-raised` for clipboard/metadata; sharp only in the technical variant.
- **Attention row** — amber dot + label for Claude sessions needing you, with an indigo jump arrow on
  hover.

## Do's and Don'ts

- **Do** reserve amber strictly for attention ("needs you", warnings). If it doesn't require action,
  it isn't amber.
- **Do** use indigo for identity and interaction; keep it restrained on the dark ground.
- **Don't** auto-expand the notch — reveal is hover or hotkey only. Ambient calm is the whole point.
- **Don't** add a third UI typeface — SF Pro + SF Mono only.
- **Don't** let coral or mint compete with amber or replace indigo; they are categorical seasoning, used
  only when a distinction genuinely needs a second hue.
