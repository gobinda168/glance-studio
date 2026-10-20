---
name: Glance
description: Liquid Glass, warm coral, one glowing light. Claude's presence beside the terminal and the editor on macOS.
colors:
  coral: "#e8643c"
  coral-hi: "#ffb28f"
  coral-lo: "#b8431f"
  coral-hover: "#ee7650"
  teal: "#2a8f94"
  teal-hi: "#8fd9dc"
  amber: "#d9a441"
  ok: "#2ea043"
  warn: "#d9a21b"
  critical: "#d9402f"
  del: "#f85149"
  aurora-violet: "#c96df2"
  aurora-sky: "#6aa8ff"
  ink: "#1c1a17"
  ink-dark: "#f1ede4"
  body: "#4a453d"
  body-dark: "#c5bfb3"
  muted: "#6b655c"
  muted-dark: "#9a948a"
  coral-ink-native: "#b0401c"
  coral-ink-web: "#c4471f"
  coral-ink-dark: "#ff9b7a"
  on-coral: "#1c1a17"
  teal-ink: "#13656a"
  teal-ink-dark: "#8fd9dc"
  ok-ink: "#197a35"
  ok-ink-dark: "#56d364"
  warn-ink: "#8a5a00"
  warn-ink-dark: "#e3b65c"
  critical-ink: "#b42318"
  critical-ink-dark: "#ff9189"
  ground: "#f4f1ea"
  ground-dark: "#131211"
  solid: "#fffaf6"
  solid-dark-native: "#221f1d"
  solid-dark-web: "#2a2724"
  bg: "rgba(250, 247, 240, .58)"
  bg-dark: "rgba(18, 17, 16, .5)"
  bg2: "rgba(243, 239, 230, .5)"
  bg2-dark: "rgba(24, 23, 21, .42)"
  card: "rgba(255, 255, 255, .78)"
  card-dark: "rgba(28, 27, 25, .8)"
  line: "rgba(28, 26, 23, .12)"
  line-dark: "rgba(255, 255, 255, .09)"
  rim: "rgba(255, 255, 255, .7)"
  rim-dark: "rgba(255, 255, 255, .16)"
  sel: "rgba(232, 100, 60, .16)"
  sel-dark: "rgba(232, 100, 60, .22)"
  seg: "rgba(28, 26, 23, .07)"
  hover: "rgba(28, 26, 23, .06)"
  hover-dark: "rgba(255, 255, 255, .07)"
  note: "rgba(251, 233, 223, .9)"
  notefg: "#6b2c14"
typography:
  greeting:
    fontFamily: "DM Sans, -apple-system, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "30px"
    fontWeight: 600
    letterSpacing: "-0.02em"
  display:
    fontFamily: "DM Sans, -apple-system, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "28px"
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: "-0.01em"
  title:
    fontFamily: "DM Sans, -apple-system, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "19px"
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: "-0.01em"
  heading:
    fontFamily: "DM Sans, -apple-system, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "13px"
    fontWeight: 600
    lineHeight: 1.5
  body:
    fontFamily: "DM Sans, -apple-system, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.5
  reading:
    fontFamily: "DM Sans, -apple-system, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.65
  label:
    fontFamily: "DM Sans, -apple-system, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "11.5px"
    fontWeight: 500
  control:
    fontFamily: "DM Sans, -apple-system, SF Pro Text, Helvetica Neue, sans-serif"
    fontSize: "12px"
    fontWeight: 500
    lineHeight: 1.5
  figure:
    fontFamily: "JetBrains Mono, ui-monospace, SF Mono, Menlo, monospace"
    fontSize: "15px"
    fontWeight: 600
  data:
    fontFamily: "JetBrains Mono, ui-monospace, SF Mono, Menlo, monospace"
    fontSize: "12px"
    fontWeight: 400
  key:
    fontFamily: "JetBrains Mono, ui-monospace, SF Mono, Menlo, monospace"
    fontSize: "10.5px"
    fontWeight: 600
rounded:
  xs: "4px"
  key: "5px"
  sm: "6px"
  md: "8px"
  lg: "12px"
  xl: "18px"
  pill: "999px"
spacing:
  s1: "4px"
  s2: "8px"
  s3: "12px"
  s4: "16px"
  s5: "20px"
  s6: "24px"
  s8: "32px"
  s10: "40px"
components:
  button-secondary:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.control}"
    rounded: "{rounded.md}"
    padding: "0 12px"
    height: "28px"
  button-secondary-hover:
    backgroundColor: "{colors.hover}"
  button-primary:
    backgroundColor: "{colors.coral}"
    textColor: "{colors.on-coral}"
    typography: "{typography.control}"
    rounded: "{rounded.md}"
    padding: "0 12px"
    height: "28px"
  button-primary-hover:
    backgroundColor: "{colors.coral-hover}"
  button-quiet:
    backgroundColor: "transparent"
    textColor: "{colors.muted}"
    rounded: "{rounded.md}"
    height: "28px"
  home-action:
    textColor: "{colors.ink}"
    typography: "{typography.heading}"
    rounded: "{rounded.md}"
    padding: "0 10px 0 12px"
    height: "42px"
  ask-pill:
    backgroundColor: "{colors.solid}"
    textColor: "{colors.ink}"
    rounded: "{rounded.pill}"
    padding: "0 6px 0 8px"
    height: "26px"
  key-cap:
    backgroundColor: "{colors.seg}"
    textColor: "{colors.muted}"
    typography: "{typography.key}"
    rounded: "{rounded.key}"
    padding: "1px 5px"
  field:
    backgroundColor: "transparent"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.sm}"
    padding: "5px 8px"
  segmented-track:
    backgroundColor: "{colors.seg}"
    rounded: "{rounded.md}"
    padding: "2px"
  segmented-thumb:
    backgroundColor: "{colors.solid}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    padding: "4px 10px"
  log-row:
    textColor: "{colors.ink}"
    rounded: "{rounded.md}"
    padding: "0 12px"
    height: "44px"
  banner:
    backgroundColor: "{colors.note}"
    textColor: "{colors.notefg}"
---

# Design System: Glance

> **This file is a record, not a rulebook.** The source of truth for how Glance looks, moves and feels is
> [`design-system/glance/MASTER.md`](design-system/glance/MASTER.md), with the web tokens in
> [`design-system/glance/tokens.css`](design-system/glance/tokens.css) and the native colours in `GlanceColor`
> (`Sources/GlanceKit/Palette.swift`) and faces in `GlanceFont` (`Sources/GlanceKit/GlanceFont.swift`). Page notes in
> `design-system/glance/pages/<surface>.md` win over MASTER for their surface; Home and the window chrome are
> [`design-system/glance/pages/home.md`](design-system/glance/pages/home.md). If this file and MASTER disagree, MASTER
> wins, and this file is stale. Values here are read from the shipped code (2026-10-07); where the code departs from
> MASTER, the token records the code and the departure is listed under **Where the code and MASTER disagree**.

## Overview

**Creative North Star: "One Warm Light"**

Glance is Claude's presence beside a developer's terminal and editor on macOS. Its world is MASTER's: warm
graphite or warm off-white grounds, Liquid Glass only for the chrome that floats over content, coral for Glance and
Claude, and one moving light per view, the aurora glow ring, on the one thing Claude can act on right now. Everything
else is calm: hairlines instead of cards, soft warm shadows, motion that explains an arrival or a change and then stops.

The system is dense and keyboard-first, a desktop tool's density (13px body, 28px controls, 24-44px rows), with every
action's shortcut shown as a key cap beside it. Colour is a vocabulary of states, never decoration: coral is Claude and
the selection, teal thinking and plan usage, amber reading, green done, warn and critical a limit closing in. The faces
are DM Sans for words and JetBrains Mono for data (numbers, paths, branches, keys), on the web pages and on native Home;
the AppKit chrome keeps SF as MASTER's native stand-in.

The 2026-10-07 "Liquid Glass sci-fi HUD" Home (cyan and violet on deep space, a star field, a grid floor) was rejected
by the user as childish and off-system. Settings, the last place its cyan, violet and pink survived, is a Studio tab
on the system since 2026-10-08; only the dictation pill keeps that spectrum.

**Key Characteristics:**
- Warm grounds (#131211 graphite, #f4f1ea off-white on Home); no pure black or pure white surfaces.
- Liquid Glass for bars, popovers and floating cards only, always with its 1px top rim.
- Coral marks Claude, Glance, selection and focus; state colours always pair with a word or glyph.
- One glow ring per view; the orb and one ring are the motion ceiling.
- Hairlines and spacing structure the page; no stat cards.
- DM Sans for sentences, JetBrains Mono for data and keys.
- Light and dark follow macOS; Reduce Motion and Reduce Transparency have designed fallbacks.

## Colors

A warm neutral world with one brand accent and a small set of state colours, each of which has a separate, darker
"ink" form for use as text.

### Primary
- **Glance Coral** (`coral`): Glance and Claude. The orb (idle and speaking), the spine's lit head on Home, the
  selected tab's tint and underline, the focus ring (2px), the launch switch, primary button fills. Never as text on a
  light surface (3.1:1).
- **Coral Highlight / Coral Deep** (`coral-hi`, `coral-lo`): the orb's and the small dot's radial gradient, and the
  coral-to-peach "lit" gradient of the chrome's underline and lit hairline.
- **Coral Ink** (`coral-ink-native` on native light, `coral-ink-web` on web light, `coral-ink-dark` on dark): coral as
  text: links, inline emphasis, the state word "idle", a news row's age.
- **On Coral** (`on-coral`): the label on a coral fill (5.2:1). White on coral is 3.3:1 and is never used.

### Secondary
- **Thinking Teal** (`teal`, ink `teal-ink` / `teal-ink-dark`): Claude thinking (orb, orbiting lights, the tab row's
  pulse) and plan usage (Home's lit dial ticks, the top bar's 3pt meter, the Glance pane's strip).

### Tertiary (states)
- **Reading Amber** (`amber`): the orb reading, the bell light.
- **Done Green** (`ok`, ink `ok-ink`): finished, added lines (`--ok-fill`, a 16% tint, with a `+` glyph).
- **Limit Warn** (`warn`, ink `warn-ink`): a usage meter from 70%, with the word "High".
- **Limit Critical** (`critical`, ink `critical-ink`): a usage meter from 90%, with "Near limit".
- **Removed Red** (`del`): removed lines (`--del-fill`, 16%, with a `−` glyph).
- **The Aurora** (`coral` → `coral-hi` → `aurora-violet` → `aurora-sky` → `coral`): only the glow ring and the orb's
  halo. Its violet and sky appear nowhere else.

### Neutral
- **Ink** (`ink` / `ink-dark`): titles, names, primary text.
- **Body** (`body` / `body-dark`): reading text, the Claude line, shortcut names, key-cap letters on Home.
- **Muted** (`muted` / `muted-dark`): captions, readout labels, paths, ages at rest.
- **Warm Ground** (`ground` / `ground-dark`): Home's opaque page.
- **Solid** (`solid`, `solid-dark-native` / `solid-dark-web`): the opaque face under a glow ring; glass under Reduce
  Transparency.
- **Glass fills** (`bg`, `bg2`, `card` and their dark forms): web window fill, bars, floating cards, translucent so the
  material shows through.
- **Hairlines** (`line`, plus `--line2` .08 and `--line3` .17 in tokens.css): 1px borders and dividers. Native Home draws
  its hairlines from the primary colour at 6% (section rules), 9% (readout splits, button edges) and 24% (the spine).
- **Rim** (`rim` / `rim-dark`): the glass's 1px inset top highlight.
- **Selection / Hover / Track** (`sel`, `hover`, `seg`): selected row or tab (coral at 16%, 22% dark), hover wash,
  segmented-control and key-cap track.
- **Note** (`note`, `notefg`): banners.

### Named Rules
**The One Light Rule.** At most one glowing element is visible per view, and it marks the one action Claude can take
right now (the Ask pill; on Home, Open Glance while the pane is closed). While Claude thinks on Home, the ring holds
still and the orb is the only motion.

**The Ink Pair Rule.** A colour used as text uses its ink form; a label on a coral fill uses `on-coral`. Every text pair
measures 4.5:1 or more on its ground (3:1 at 18px+ or 14px bold).

**The Meaning Rule.** Colour marks a state, never decoration, and never alone: a state word, a flag in words, or a
`+`/`−` glyph rides with it.

## Typography

**Display Font:** DM Sans (with -apple-system, SF Pro Text, Helvetica Neue)
**Body Font:** DM Sans
**Label/Mono Font:** JetBrains Mono (with ui-monospace, SF Mono, Menlo)

**Character:** a soft geometric sans for every sentence and a precise mono for anything you'd copy, compare or count.
Both are variable fonts shipped in `Web/vendor/fonts`; native Home registers them through `GlanceFont` and sets weight
on the `wght` axis, falling back to SF Pro / SF Mono if the files are missing. SF draws SF Symbols and the ⌘ ⇧ ⌥ ⌃ ⏎
arrow glyphs that JetBrains Mono lacks. The terminal's AppKit chrome stays in SF.

### Hierarchy
- **Greeting** (600, 30px; 26 below 640 wide, 34 from 1280; -0.02em): Home's greeting only.
- **Display** (700, 28px, 1.25, -0.01em): `--fs-display`, the largest web title.
- **Title** (700, 19px, 1.25, -0.01em): `--fs-title`, panel and section titles on the web.
- **Heading** (600, 13px): Home's section heads ("Recent projects", "Shortcuts") and action labels; project names at
  13.5.
- **Body** (400, 13px, 1.5): UI text. Home's Claude line runs at 14, its secondary text at 12.5.
- **Reading** (400, 15-16px, 1.65): Claude's replies.
- **Label** (500, 11.5px): Home's readout and shortcut-group labels, sentence case, muted. MASTER's web label is 11px,
  uppercase, 0.06em.
- **Control** (500, 12px): web buttons and segmented controls; 600 on primary buttons and pills.
- **Figure** (mono 600, 15px, tabular): the readout's percentages; they roll as numeric text.
- **Data** (mono 400-500, 12px): paths (clipped at their start), branches, countdowns, ages (11.5), the version.
- **Key** (mono 600, 10.5px web; mono 500, 11.5px native): key caps.

Nothing renders below 10.5px; nothing a user must read to act is below 12px.

### Named Rules
**The Mono Is Data Rule.** Figures, paths, branches, countdowns and keys are mono; the words around them ("resets in",
"changed", "Not a git repository") are sans, so a sentence never turns into a terminal line.

## Layout

A 4px grid (`s1`-`s10`: 4, 8, 12, 16, 20, 24, 32, 40). Control padding 8-12, card padding 12-16, panel gutters 16-20.
Hit targets are 28px or taller for primary controls and 24px for dense ones, 8px apart.

Pages are structured by alignment and hairlines, not containers. Home is the reference: one shared left edge (the dial
plus 24pt, 16 below 640 wide) aligns the greeting, readout, actions, headings and ages; content caps at 1240pt with
3.2% side padding clamped to 16-44pt; a shortcuts rail joins from 900pt wide (232pt, 248 from 1100). Its composition
(the session log, the spine, the dial) belongs to `pages/home.md`, not to the system.

Motion tokens (in the sidecar and tokens.css): 90ms press, 160ms fades, hovers and every exit, 240ms swaps, 420ms
arrivals, 600ms scene changes, 3s per glow-ring turn. Arrivals use the soft spring (about 2% overshoot); exits are
faster than entrances; content changed in place blur-swaps (5px rise through a 3px blur). Only opacity, transform and
filter animate. Loops run only while on screen. Under Reduce Motion every entrance becomes a 160ms fade and loops stop.

## Elevation & Depth

A hybrid: Liquid Glass and tonal layering for chrome, soft warm shadows for what floats. Content (code, replies,
the log) sits flat on its own clear layer, never inside a blur. Glass comes in thin (bars: blur 14, saturate 1.6),
regular (cards and popovers: blur 24, saturate 1.8) and thick (regular plus `e3`) tiers natively mapped to
`.glassEffect(.regular)`; every glass surface carries the rim, and glass never stacks more than two deep.

### Shadow Vocabulary
- **Resting** (`e1`: `0 1px 2px rgb(28 26 23 / .08)`): chips, the selected segment.
- **Floating** (`e2`: `0 4px 14px rgb(28 26 23 / .12), 0 1px 3px rgb(28 26 23 / .08)`): cards, the Ask pill.
- **Popover** (`e3`: `0 12px 36px rgb(28 26 23 / .2), 0 2px 8px rgb(28 26 23 / .1)`): popovers, the pane card.
- **Glow halo**: the aurora blurred 8-9px behind the ring at 42-55% (70-85% on hover).

Shadows take `--shadow-color`: warm `28 26 23` in light, black only in dark.

### Named Rules
**The Rim Rule.** Every glass surface has a 1px top highlight; without it glass reads as grey.

**The Warm Shadow Rule.** Shadows are soft and warm; never a hard black drop shadow in light mode.

## Shapes

Continuous (squircle) corners, concentric: an inner radius is the outer one minus the padding between them. The
ladder is 4 (flags, small badges), 5 (key caps), 6 (fields, small buttons, row buttons), 8 (buttons, rows, the Ask
box), 12 (cards), 18 (the pane card, windows' inner content) and the pill (999: the Ask pill, the chrome's button
plates). Borders are 1px hairlines; focus is a 2px coral ring at 2px offset (on Home's rows, a 2pt coral stroke on the
row's 8pt shape).

## Components

### Buttons
Quiet and keyed: a hairline outline that warms under the pointer.
- **Shape:** gently rounded (8px), 28px tall on the web.
- **Primary:** coral fill and border, `on-coral` label at 600; hover lifts to `coral-hover`.
- **Secondary:** transparent with a 1px `line` border, ink label at 500; hover `hover`, press `--press` and scale .97.
- **Quiet:** borderless, muted.
- **Home action** (native): a 42pt raised face (white at 3.5% dark / 62% light, brighter on hover, pressed darker), a
  1px hairline at 9% (16% hover) and a lit top edge, an SF Symbol in muted (ink on hover), a 13pt semibold label and key
  caps at the right. Press scales to .98.
- **Chrome buttons** (native): a bare glyph at rest; under the pointer a capsule of neutral glass fades in; a toggle that
  is on stays lit with a coral tint. Press squishes to .93.

### Key caps
- **Style:** a small cap with 5px corners, a 1px hairline, mono letters, SF modifier glyphs; ⌘ ⌥ ⇧ ⌃ ⏎ glyphs, never
  words (Space is the exception). Shown beside every action that has a shortcut.

### Fields
- **Style:** 1px `line` border, transparent fill, 6px corners, 13px text, 5px 8px padding.
- **Focus:** the border turns coral.

### Segmented control
- **Style:** a `seg` track with 2px padding and 8px corners; the selected thumb is `solid` with `e1`, sliding on the
  glide curve.

### Tabs / rows
- **Style:** 24-28px rows in lists and the tab sidebar (44pt on Home's log, 54 stacked); `hover` on hover; when
  selected, `sel` plus a coral edge or underline. The chrome's selected tab is a coral-tinted glass plate with a 1pt
  coral edge that slides between rows.

### Banner
- **Style:** full width, `note` fill, `notefg` text, outlined buttons.

### The Ask pill (signature)
A 26px solid pill carrying the glow ring: a 1.5px aurora border turning once every 3s over the same light blurred
behind it, an 11px coral dot, a 600/12 label and a key cap. Fades in over 160ms above a settled selection; hidden while
dragging. It is the house style's reference implementation (`.ask-hint` in `Web/editor/editor.css`).

### The orb (signature)
Glance's presence: a radial-gradient sphere (highlight at 35%/30%) whose colour is its state: coral idle and speaking,
teal thinking (with orbiting lights), amber reading, green finished (with a check). It breathes slowly at rest and
faster while working. The 11px small orb marks Claude in compact UI.

### Status lights
Flat lit spheres (7pt) with a highlight and no halo: a badge marks a state, it does not glow.

## Do's and Don'ts

### Do:
- **Do** read MASTER.md, and the surface's `pages/*.md` if it has one, before any UI work; this file only records them.
- **Do** use `GlanceColor` and `GlanceFont` on native surfaces and `tokens.css` on the web, rather than inline values.
- **Do** put coral text in its ink form (`coral-ink-native` #b0401c on native light grounds) and labels on coral in
  `on-coral`.
- **Do** pair every state colour with a word or a glyph.
- **Do** show each action's shortcut as a key cap beside it and in its tooltip.
- **Do** give Reduce Motion a 160ms fade and Reduce Transparency the `solid` surface.
- **Do** stop every loop when its view is off screen.

### Don't:
- **Don't** put glass behind body text or code, or stack glass three deep.
- **Don't** show more than one glow ring, or put it on anything that isn't an action Claude can take.
- **Don't** stack entrance effects (a spring plus a pulse plus a ring) on one element.
- **Don't** put coral text on a light surface or white text on coral.
- **Don't** use pure #000 or #fff surfaces, or hard black shadows in light mode.
- **Don't** use emoji as icons, or words where a ⌘ glyph belongs.
- **Don't** animate layout properties, or run infinite animations on hidden elements.
- **Don't** bring back the cyan, violet and pink spectrum or a space backdrop; the aurora's violet and sky live only in
  the glow ring and the orb's halo.

## Where the code and MASTER disagree

Recorded, not resolved. MASTER stays the authority; each line is a candidate for a MASTER update or a code fix.

- **Coral ink, native light:** `GlanceColor.coralInk` is #b0401c; MASTER and tokens.css say #c4471f, which measures 4.4:1
  on Home's #f4f1ea ground. `pages/home.md` §4 records the native value. The web keeps #c4471f.
- **Solid, dark:** `GlanceColor.solid` dark is #221f1d; tokens.css `--solid` dark is #2a2724.
- **Grounds:** native Home paints opaque #f4f1ea / #131211 (`GlanceColor.ground`); tokens.css has no opaque ground, only
  the translucent `--bg`.
- **State inks:** `GlanceColor` adds teal, ok, warn and critical ink forms (light and dark) that MASTER §3 and
  tokens.css do not define.
- **Type sizes:** native Home uses 11.5, 12.5, 13.5, 14 and 30 outside MASTER's 11 / 12 / 13 / 15-16 / 19 / 28 scale.
- **Labels:** Home's labels are 11.5px sentence case; MASTER §4's labels are 11px uppercase at 0.06em.
- **Press scale:** web buttons and the chrome's self-drawn buttons press to .97 (MASTER); Home's buttons (actions, row
  buttons, Open shell) to .98; the chrome's glyph buttons to .93.
- **Chrome text:** the chrome's ink is the system primary at 88% / 64%, not `GlanceColor.ink` / `body`.
- **Home key caps:** the native cap carries a 1px offset edge beneath it (black at 14% light, 50% dark). MASTER's
  `.g-kbd` is flat, and MASTER bans hard black shadows in light mode. This is a defect the build carries, not part of
  the key-cap recipe above.
