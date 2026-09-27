---
version: "1.1"
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
  button-primary:
    fontFamily: "-apple-system, SF Pro"
    fontSize: "14px"
    fontWeight: 700
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

### Timer state colors (locked)

Color on a timer always **means** which timer/state is running, and the collapsed ring and the expanded
axis/chip use the **same** color so the two views read as one:

- **Countdown → indigo** (`accent`) — a plain countdown carries no focus/break semantics, so it uses the
  identity accent, not a warm hue.
- **Pomodoro focus → coral** (`accent-warm`).
- **Pomodoro break → mint** (`accent-cool`).

A timer never uses amber (attention-only). Color is applied where it carries meaning; a resting/idle
surface stays neutral.
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

### Collapsed notch (locked geometry rule)

The collapsed footprint is **fixed per display** (07-DESIGN-AGREEMENT.md §11): the MacBook pill is
257×36pt with 18pt shoulders and 3pt floor sag; the Dell desktop pill is 197×30pt (menu-bar height) with
24pt shoulders and 2pt sag; on a fullscreen display the pill becomes a 197×9pt bulge with 72pt shoulders
and 2pt sag. None of these ever widen or grow to fit a timer or now-playing.

Alerts and the HUD are **separate drops that pinch off below the pill/bulge and never touch its width** —
they are no longer part of the notch once they've separated, so they may even be wider than it.
**opening the band is the only thing that widens the notch itself** — this replaces and resolves the old
"never widens" rule, which read as a contradiction once the HUD/alert drops and the wing items shipped.

Wing items (artwork, live sound wave, running-timer clock-face) sit 16pt, against the camera housing at a
3pt gap, which stays **empty** — nothing is ever drawn over it. Expansion (hover / hotkey) pours the same
shape into the band.

## Components

- **Notch strip** (collapsed) — the fluid pill/bulge above, wing items against the camera housing (which
  stays empty). Never blank; its footprint never resizes to fit content.
- **Band** (hover-reveal) — a row of two-line module summaries (Now Playing, Timer, Next meeting, Claude,
  Clipboard), each with one round action glyph; 1166pt for five modules, never under 824pt; re-flows when
  a module is switched off.
- **Detail droplet** — always 188pt deep, 236–300pt wide; holds secondary detail and controls for the
  module the band is resting on or has pinned.
- **Drops** (HUD, alerts) — separate from the band/pill: the HUD is 160pt (MacBook) / 140pt (Dell) wide,
  22pt deep, click-through; the meeting alert is 30pt deep (44pt on two lines) and Join is the only
  clickable alert.
- **Panel** (legacy stage container, retired in plan 08) — `surface` card, md rounding, hairline border,
  grouped rows under uppercase mono labels.
- **Primary button** — indigo fill, sm rounding, used sparingly (e.g. "Join").
- **Chip** — pill on `surface-raised` for clipboard/metadata; sharp only in the technical variant.
- **Attention row** — amber dot + label for Claude sessions needing you, with an indigo jump arrow on
  hover. Amber is strictly attention-only.

## Do's and Don'ts

- **Do** reserve amber strictly for attention ("needs you", warnings). If it doesn't require action,
  it isn't amber.
- **Do** use indigo for identity and interaction; keep it restrained on the dark ground.
- **Don't** auto-expand the notch — reveal is hover or hotkey only. Ambient calm is the whole point.
- **Don't** add a third UI typeface — SF Pro + SF Mono only.
- **Don't** let coral or mint compete with amber or replace indigo; they are categorical seasoning, used
  only when a distinction genuinely needs a second hue.
- **Don't** widen or grow the collapsed pill/bulge to fit ambient content — the collapsed footprint is
  fixed per display; alerts and the HUD are separate drops below it that never touch its width;
  opening the band is the only thing that widens the notch itself.

## Interaction rules

- **Any action one click, any detail two.** Every module's primary action is a round glyph on the band
  itself, reachable the moment the band is open. Secondary detail and secondary controls live in the
  detail droplet, one click (or Return) further in.
- **Hover only ever speeds things up — it is never the only path.** Pointer rest, a click, and the
  keyboard all reach every droplet. Resting 0.25s on the notch pours the band open; resting 0.14s on a
  module drips its droplet down; but the same states are reachable by clicking or by keyboard (⌥Space,
  arrows, Return) with no hover at all.
- A click on a glyph, or anywhere inside the droplet, **never** pins, opens, or collapses anything else —
  a glyph tap and a "close this" tap are distinct gesture regions that never overlap.
- **No scrolling or marquee text anywhere.** A long meeting title wraps to a second line instead.
- **Amber strictly means attention.** If a state doesn't require the user to act, it isn't amber.

## Shape family

One fluid outline family draws every surface — the pill, the Dell pill, the fullscreen bulge, the band,
the detail droplet, the meeting bump, and the HUD: even-S shoulders that leave the top edge flat and
arrive at the floor's own slope, a floor that sags under its own weight, and — for drops — smootherstep
flanks with a rounded belly. No straight edge, no corner, anywhere in the family.

| Surface | Size | Shoulders | Floor sag |
|---|---|---|---|
| MacBook pill | 257×36 | 18pt | 3pt |
| Dell desktop pill | 197×30 (menu-bar height) | 24pt | 2pt |
| Dell fullscreen bulge | 197×9 | 72pt | 2pt |
| Band | 1166pt for five modules, never under 824pt | 132pt | 9pt |
| Detail droplet | 236–300pt wide, always 188pt deep | 122pt flanks | 18pt belly |

## Motion & feedback

Every surface transition runs on the same five named `FluidSpring` presets (`FluidMotionPreset`,
response / damping):

| Spring | Response | Damping |
|---|---|---|
| open | 0.55 | 0.78 |
| close | 0.50 | 0.92 |
| droplet | 0.60 | 0.80 |
| slide | 0.55 | 0.86 |
| sticky pull | 0.70 | 0.90 |

**Staging.** Opening pours: width leads, depth follows 1.35× slower. Closing drains: depth goes first,
width follows 1.35× slower. A new droplet spreads, then drips. Content fades in 160ms after the surface
opens. Dwell is 0.25s resting on the notch, 0.14s resting on a module.

**Press feedback.** Every control dims and scales to 0.86 within one frame via a `ButtonStyle` reading
`isPressed`, with a hover highlight underneath it — no click ever goes without visible feedback.

**Symbol effects.** SF Symbols animate on state changes — play/pause, mute, a timer completing. Numeric
readouts use the numeric-text content transition so digits tick instead of jumping.

**Focus ring.** The standard 2pt accent ring, used for every keyboard-focused control (PANEL-09).

**Haptics.** `NSHapticFeedbackManager` fires only at snap points and threshold crossings — a timer
reaching zero, a progress axis passing a mark — **never on ordinary clicks**, and always honoring the
system haptic setting.

**Reduce Motion.** Every spring above becomes a 0.2s cross-fade; no pour/drain staging, no symbol
effects beyond the plain content change.
