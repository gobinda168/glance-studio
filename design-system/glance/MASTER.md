# Glance Design System — MASTER

The source of truth for how Glance looks, moves and feels, on every surface: the Glance pane and overlay, Glance
Terminal's chrome (top bar, tab sidebar), Razor Code, Glance Code's extension UI, and Settings.

- **Tokens (web):** [`tokens.css`](tokens.css): drop-in CSS custom properties and the signature classes.
- **Live preview:** [`preview.html`](preview.html): open it in a browser, toggle light/dark, see every token and effect.
- **Native (SwiftUI/AppKit):** §9 maps every token to Liquid Glass APIs.
- **Page overrides:** `pages/<surface>.md` wins over this file for that surface, when one exists.

Reference implementation of the house style: the Inline Ask pill (`Web/editor/ask.js`, `.ask-hint` in
`Web/editor/editor.css`): a quiet glass chip, a coral orb, a ⌘ key, and one light running round its border.

---

## 1. Principles

1. **Content first, glass second.** Liquid Glass is a layer *above* content for navigation and controls: bars,
   popovers, the pane card, the pill. Code, replies and diagrams sit on their own clear layer, never inside a blur.
2. **One light per view.** The aurora glow ring is a signal: "Claude can act here". At most one glowing element is
   visible at a time. Everything else is calm.
3. **Warm, not neon.** Coral on warm off-white and warm near-black. No pure black, no pure white surfaces, no blue
   UI chrome. Colour marks meaning (Claude, thinking, reading, added, removed), never decoration.
4. **Motion explains.** Things arrive with a soft spring, leave faster than they came, and change in place with a
   blur-swap. Loops (the glow, the orb) are linear and only run while visible.
5. **Keyboard is first-class.** Every action has a key, shown as a `kbd` chip next to it (⌘I, ⌘↩, Esc).
6. **Respect the system.** Light/dark follow macOS; Reduce Motion and Reduce Transparency each have a designed
   fallback, not a broken one.

## 2. Materials (Liquid Glass)

| Tier | Use | Web | Native |
|---|---|---|---|
| **Thin** | Bars: headers, tab bars, sidebars | `.g-glass-thin` (blur 14, sat 1.6, `--bg2`) | `.glassEffect(.regular, in: .rect)` on the bar |
| **Regular** | Floating cards, popovers, the Ask box | `.g-glass` (blur 24, sat 1.8, `--card`, rim, `--e2`) | `.glassEffect(.regular, in: .rect(cornerRadius: 12))` |
| **Thick** | Modal-ish surfaces: the pane card over the terminal, palettes | `.g-glass-thick` (+ `--e3`) | `.glassEffect(.regular)` + shadow; `NSVisualEffectView(.hudWindow)` pre-26 |
| **Solid** | Under a glow ring; Reduce Transparency fallback | `--solid` | `.background(.background)` |

Rules:
- Every glass surface has the **rim**: a 1px inset top highlight (`inset 0 1px 0 var(--rim)`). Without it glass reads as grey.
- Glass never stacks more than two deep (a popover on a bar is fine; a popover on a popover on a bar is not).
- Tint glass only with a semantic colour, at ≤ 16% (`--sel`), for a selected state.
- Corners are **continuous** (squircle) natively, and concentric: inner radius = outer radius − padding.

## 3. Colour

Brand: **coral `#e8643c`** (Claude/Glance). States: **teal `#2a8f94`** thinking, **amber `#d9a441`** reading,
**green `#2ea043`** added/ok, **red `#f85149`** removed/error. The aurora (`--aurora`: coral → peach → violet →
sky) appears only in the glow ring and the orb's halo.

Text roles, with contrast measured on the panel background (WCAG AA needs 4.5:1 for text under 18px):

| Token | Light | Dark | Use |
|---|---|---|---|
| `--ink` | `#1c1a17` (16.2:1) | `#f1ede4` (15.6:1) | titles, primary text, labels |
| `--body` | `#4a453d` (8.9:1) | `#c5bfb3` (10.0:1) | long reading text (replies) |
| `--mu` | `#6b655c` (5.4:1) | `#9a948a` (6.1:1) | captions, hints, secondary |
| `--coral-ink` | `#c4471f` (4.6:1) | `#ff9b7a` | coral **as text**: links, inline emphasis |
| `--on-coral` | `#1c1a17` on coral (5.2:1) | same | labels on a coral fill |

Hard rules (found by measuring the current UI):
- **Never put `--coral` text on a light surface** (3.1:1). Use `--coral-ink`.
- **Never put white text on a coral fill** (3.3:1). Use `--on-coral`. *(The Ask box's Accept button does today:
  fix when next touched.)*
- The old light `--mu` `#7a746a` is 4.3:1 and fails at caption sizes. `tokens.css` uses `#6b655c`.
- Diff fills: added `--ok-fill`, removed `--del-fill` (16% tints), with a `+`/`−` glyph so colour is never the only cue.

## 4. Typography

- **DM Sans** for UI and reading (`--sans`); **JetBrains Mono** for code, keys and numbers (`--mono`). Both ship in
  `Web/vendor/fonts`. Natively, SF Pro / SF Mono are acceptable stand-ins in AppKit chrome.
- Scale: caption 11 · small 12 · body 13 · reading 15–16 · title 19 · display 28 (`--fs-*`). Nothing below 11px;
  nothing below 12px that the user must read to act.
- Weights: 400 body, 500 controls, 600 labels/pills, 700 titles. Titles get `letter-spacing: -.01em`.
- Line height: 1.25 titles, 1.5 UI, 1.65 replies.
- Small caps-style labels (section headers, tab heads): 11px, uppercase, `letter-spacing: .06em`, `--mu`.

## 5. Space, shape, elevation

- **4px grid**: `--s1`…`--s10` (4, 8, 12, 16, 20, 24, 32, 40). Control padding 8–12; card padding 12–16; panel gutters 16–20.
- **Radius**: 4 (kbd), 6 (fields, small buttons), 8 (buttons, rows, Ask box), 12 (cards), 18 (pane card, windows' inner content), pill (999).
- **Hit targets**: ≥ 28px tall on desktop for primary controls, ≥ 24px for dense ones (tab close, chips); 8px between targets.
- **Elevation**: `--e1` resting chips, `--e2` floating cards/pills, `--e3` popovers and the pane card. Shadows are
  warm (`--shadow-color`) and soft; never a hard black drop shadow in light mode.

## 6. Motion

| Token | Value | Use |
|---|---|---|
| `--t-instant` | 90ms | press feedback (`scale(.97)`) |
| `--t-fast` | 160ms | fades, hovers, the pill appearing, leaving anything |
| `--t-base` | 240ms | swaps, segmented controls, small moves |
| `--t-slow` | 420ms | a card or reply arriving (`.g-rise`) |
| `--t-scene` | 600ms | a panel or the orb changing place (`.g-appear`) |
| `--t-orbit` | 3s | one turn of the glow ring (linear) |

Curves: `--spring` (≈2% overshoot, the SwiftUI `.smooth` feel) for arrivals and moves; `--ease-out` for fades in;
`--ease-in` for exits; `--glide` for size/position; `linear` for loops and progress.

Choreography rules:
- **One entrance per element**: fade *or* rise *or* appear, never a spring + a pulse + a ring on the same thing.
  (The first Ask pill stacked three animations and looked broken; the fix was a plain fade + the glow ring.)
- **Exit faster than enter** (fast vs slow).
- **Change in place with a blur-swap** (`.g-swap`: 5px rise + 3px blur), not a slide.
- **Animate opacity, transform, filter only**; never width/height/top/left in a loop.
- **Loops run only while visible** (`.show`, `:not(.g-quiet)`), so a hidden glow costs nothing.
- **Max 1–2 moving things per view.** The orb and one glow ring is the ceiling.
- **Reduce Motion**: loops stop, entrances become a 160ms fade, presses don't scale. Final state is always readable.

## 7. Signature effects

### 7.1 The glow ring (aurora border)
A 1.5px conic-gradient border masked to a ring, plus the same gradient blurred 9px behind at 55% opacity, both
rotating once per 3s via the registered `--g-angle` property. Hover raises the halo to 85%.
Use: the one affordance where Claude can act right now (the Ask pill; a future "Ask Claude" command button; the
focused agent tab). Class: `.g-glow` on a solid (`--solid`) element. Don't: put it on containers, text, or more than
one element; animate it while hidden.

**The one exception: the meeting nudge.** It wears Apple Intelligence's edge light, not the aurora: blue `#8D9FFF`,
violet `#BC82F3` / `#C686FF`, pink `#F5B9EA`, red `#FF6778` and orange `#FFBA71`, turning once per 4s, with a crisp
1.5px line, a soft inner glow and a bloom behind that flares as the nudge drops in, then settles. It's the system's own
"look here" when a meeting starts, so nothing else on the nudge glows (Join is plain primary). It's still under Reduce
Motion. `NudgeCard.swift`, `IntelligenceGlow`.

### 7.2 The orb
Glance's presence. A radial-gradient sphere (highlight at 35%/30%) with a soft halo; its colour is its state:
coral idle/speaking, teal thinking (orbiting dots), amber reading (dashed ring + scan line). Breathes at 4s idle,
faster while working; ripples while speaking. Small orb (`.g-dot`, 11px) marks Claude in compact UI (pill, rows).
Implementation: `Web/style.css` `.orb`, `Web/orb.html`.

### 7.3 Rise, appear, swap
`.g-rise` (16px up, .97 scale, 4px blur → rest, spring) for replies/cards arriving; `.g-appear` (14px from the
edge, 6px blur) for panels; `.g-swap` for content replaced in place (new answer, new tab content).

### 7.4 Diff colours
Old lines `--del-fill` + red `−` gutter glyph; new lines `--ok-fill` + green `+`. Accept is the primary action
(coral, ⌘↩), Reject is secondary (Esc).

## 8. Components

| Component | Recipe | Reference |
|---|---|---|
| **Ask pill** | `.g-pill.g-glow` + `.g-dot` + label 600/12 + `.g-kbd`; fades in 160ms above a settled selection; hidden while dragging | `.ask-hint` |
| **Inline box** | `.g-glass`, radius 8, 3px coral left edge, question in `--mu` with `›`, answer markdown in `--ink`, textarea `.g-field`, actions right-aligned | `.ask` |
| **Buttons** | `.g-btn` (secondary), `.primary` (coral fill, `--on-coral` text), `.quiet` (borderless, `--mu`); 28px tall | |
| **Key hint** | `.g-kbd` beside its action; ⌘ ⌥ ⇧ ⌃ ↩ glyphs, not words | |
| **Segmented control** | `.g-seg` track `--seg`, selected thumb `--solid` + `--e1`, slides on `--glide` | pane settings |
| **Tabs / rows** | 24–28px rows, `--hover` on hover, `--sel` + 2px coral underline/edge when active | Razor tabs, tab sidebar |
| **Banner** | full-width, `--note` fill, `--notefg` text, outlined buttons | Razor `#banner` |
| **Field** | `.g-field`, 1px `--line`, coral border on focus | search, Ask input |
| **Toast** | Regular glass card, radius 12, one row: an SF Symbol in its state colour, a 13/500 title with a mono detail, `.quiet` buttons and one `.primary` (radius 6, 6px in from the edge: concentric), a 2px coral progress line along the bottom edge; one width for every step, its content blur-swaps; rises 14px through a 6px blur, leaves faster; the window's bottom left | update toast (`UpdateToastCard`) |

Iconography: Glance Studio's strip, side bars and PR pages draw the PR Management canvas's line icons natively
(`StudioIcons` in GlanceCore, `StudioIcon` in the fork: the 24-unit grid, a 1.7 stroke, round caps and joins); other
native UI uses SF Symbols; in web UI, inline SVG at 16px with `currentColor` (no emoji as icons; the `✦` in Glance
Code's text decoration is the one exception, since a decoration can't hold an SVG).

Logo: the coral orb inside its coral-and-amber level ring, in `assets/logo/` (`glance-mark.svg`, `-mono`,
`-cream-on-coral`, `glance-app-icon.svg`). Glance Studio's app icon (`terminal/images/Glance.icon`, flattened in
`glance-icon-preview.svg`) is that mark on a warm off-white tile in light mode and a graphite tile with a coral halo in
dark mode.

## 9. Native mapping (SwiftUI / AppKit, macOS 26+)

```swift
// Materials
bar.glassEffect(.regular, in: .rect)                                     // thin tier
card.glassEffect(.regular, in: .rect(cornerRadius: 12, style: .continuous))
pill.glassEffect(.regular.tint(.orange.opacity(0.16)).interactive(), in: .capsule) // tinted only when selected
GlassEffectContainer { /* sibling glass that should merge/morph */ }      // + .glassEffectID(id, in: ns)
// Pre-26 fallback: NSVisualEffectView(material: .hudWindow, blendingMode: .behindWindow)

// Motion: tokens → SwiftUI
let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)    // --spring (pane card already uses this)
let fast   = Animation.easeOut(duration: 0.16)                           // --t-fast
let orbit  = Animation.linear(duration: 3).repeatForever(autoreverses: false) // --t-orbit
@Environment(\.accessibilityReduceMotion) var reduceMotion
@Environment(\.accessibilityReduceTransparency) var reduceTransparency

// The glow ring: the gradient turns, the capsule doesn't. TimelineView pauses under Reduce Motion and while the
// view is off screen, so a hidden ring costs nothing.
struct GlowRing: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  static let aurora: [Color] = [Color(red: 0.910, green: 0.392, blue: 0.235), Color(red: 1, green: 0.698, blue: 0.561),
                                Color(red: 0.788, green: 0.427, blue: 0.949), Color(red: 0.416, green: 0.659, blue: 1),
                                Color(red: 0.910, green: 0.392, blue: 0.235)]
  func body(content: Content) -> some View {
    TimelineView(.animation(paused: reduceMotion)) { context in
      let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
      let light = AngularGradient(colors: Self.aurora, center: .center, angle: .degrees(turn * 360))
      content
        .background(Capsule().fill(.background))                          // --solid under the ring
        .overlay(Capsule().strokeBorder(light, lineWidth: 1.5))
        .background(Capsule().fill(light).blur(radius: 9).opacity(0.55))  // the halo
    }
  }
}
```
Native colours live in `GlanceColor` (`Sources/GlanceKit/Palette.swift`), with the hex values in §3; Home and the
window chrome (`GlassChrome`) both read them. Use them rather than inline `Color(red:…)`.

## 10. Accessibility checklist (every new surface)

- [ ] Text pairs from §3 only; measured ≥ 4.5:1 (≥ 3:1 for 18px+ or 14px bold).
- [ ] Every control reachable by keyboard; visible `:focus-visible` ring (2px coral, 2px offset).
- [ ] Every action that has a shortcut shows it (`.g-kbd`) and in its tooltip.
- [ ] Colour is never the only signal (diff glyphs, state labels next to the orb).
- [ ] Reduce Motion: loops off, entrances → fade. Reduce Transparency: glass → `--solid`.
- [ ] Hit targets ≥ 24px, primary ≥ 28px; 8px apart.
- [ ] Hidden UI costs nothing: no running animation, timer or observer while not shown.
- [ ] Light and dark both checked.

## 11. Don'ts

- Glass behind body text or code; glass on glass on glass.
- More than one glow ring, or a glow on anything that isn't an action Claude can take.
- Stacked entrance effects (spring + pulse + ring); bouncy overshoot on dense information.
- Coral text on light, white text on coral, grey-on-grey captions.
- Pure `#000`/`#fff` surfaces; hard black shadows in light mode.
- Emoji as icons; words where a ⌘ glyph belongs.
- Animating layout properties; infinite animations on hidden elements.
