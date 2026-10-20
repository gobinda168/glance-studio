# Glance Home: page notes

**Surface:** the Home tab of **Glance Studio**, the app's start screen, and the window chrome around it (the top bar
and the tab sidebar). Home is native SwiftUI: `Sources/GlanceKit/HomeView.swift` (the page and `HomeModel`), fed by
`Sources/GlanceCore/HomeState.swift` and hosted by the fork's `Features/Glance/Home/` (`HomeWindowController`,
`HomeTabView`). The chrome is `terminal/macos/Sources/Features/Glance/Tabs/` (`GlassChrome`, `TabSidebarView`,
`GlanceTopBar`, `PlanUsageItem`).

Home and the chrome follow MASTER.md as written: warm graphite or warm off-white, coral for Glance, Claude and the
selection, teal for thinking and plan usage, green for finished, one glow ring, calm motion. Home is set in the web
pages' own faces, DM Sans and JetBrains Mono (registered from `Web/vendor/fonts` by `GlanceFont`), so it speaks with
the Glance pane beside it; SF draws only SF Symbols and the ⌘ ⇧ ⌥ ⏎ key glyphs JetBrains Mono lacks. The chrome keeps
SF, MASTER §4's native stand-in for AppKit chrome. This file adds only what is specific to Home and the chrome. It replaces the 2026-10-07
"Liquid Glass sci-fi HUD" Home (cyan and violet on deep space, a star field, a grid floor, the glass G lens), which the
user rejected the same day as childish and off-system.

---

## 1. The composition: a session log

Time is the page's axis. What is live **now** sits at the head of one hairline **spine**; every recent project hangs
below it by how long ago you left it.

| Part | What it is |
|---|---|
| **Dial** (80pt; 96 from 1280 wide, 64 below 640) | Claude's orb (MASTER §7.2) inside 60 ticks from twelve o'clock: the lit ones are the 5-hour window used, in teal (amber from 70%, red from 90%). A fine inner arc is the week. Every fifth tick is longer, like a bezel. It is the Glance mark's radial ticks put to work as a gauge. The contract's 72pt grew to 80 to hold the week's ring, and to 96 so a wide window isn't one small instrument in a field. |
| **Greeting** | "Good afternoon, Gobinda." DM Sans 30pt semibold (34 from 1280), -0.02em; the hour re-checks once a minute while Home is on screen and changes with a blur-swap. |
| **Claude line** | "Claude is **idle**. Ready when you are." The state word carries the state colour (coral, teal, green), never colour alone; a new state blur-swaps in place (5pt rise through a 3pt blur). |
| **Readout** | 5-hour window · Week · Folder, split by hairlines. Percentages, countdowns, paths and branches in JetBrains Mono; the words around them ("resets in", "changed", "Not a git repository") in DM Sans, since mono is for data, not sentences. "High" and "Near limit" flags in words. The folder takes its own line below 700pt, and a long branch there stops at 220pt so the path stays whole. Outside git it says "Not a git repository", never "Unknown". |
| **Actions** | New terminal ⌘T · New editor ⇧⌘E · Open Glance ⌥Space · Settings, as 42pt keyed buttons, two columns until the log is 820pt wide, then four. Open Glance carries the page's one glow ring while the pane is closed. |
| **Log** | "Recent projects" and up to 8 rows (44pt; 54 when the log is narrower than 520pt, the path then under the name). Each row hangs off the spine: its 10pt tick, then its age just right of it ("2m", "now"), then on the shared edge the name, the path (clipped at its start) and the branch (right). Hover or focus reveals Terminal and Editor buttons over the branch. |
| **Spine** | 1pt, from the dial's foot to the last row's tick. Coral where it leaves now, cooling by 230pt to a hairline that stays legible (24% ink): time cools as it recedes. Quarter-row ruler ticks (4pt, 17%) mark the past between the rows' own ticks. With no projects it trails off in dashes beside the empty note. |
| **Shortcuts** | A rail from 900pt wide (232pt, 248 from 1100), else one to three columns under the log. Only real shortcuts, as key caps. |
| **Footer** | The native switch "Show Home at launch" (coral), the version, and "⏎ Open shell". |

One shared left edge (the dial plus 24pt) aligns the greeting, the readout, the actions, the heading and the ages.
The content caps at 1240pt; padding is 3.2% of the width, 16 to 44pt.

## 2. States

- **First run:** no projects: "Projects you work in show up here, newest first. Open a terminal with ⌘T and cd into a
  project folder." No usage yet: the dial stays unlit and the readout says "Shows here once Claude Code reports it".
- **Claude:** idle (coral orb, slow breath), thinking (teal orb, quicker breath, three lights orbiting), finished (green
  orb with a check; the line points to the Glance pane).
- **Limits:** amber and "High" from 70%, red and "Near limit" from 90%, in the dial and the readout alike.
- **News:** a project that arrived, switched branch, or jumped ahead of another (`HomeState.news`) keeps a coral tick
  and a coral age until it has been seen: hovered, focused, or on screen for 4 seconds.
- **Before the first state:** only the ground shows, so no empty state flashes.

## 3. Motion

- **Arrival, once, only if Home is on screen:** the spine draws itself down from now (0.72s, expo out), the dial's
  ticks light in order, and the parts fade up on a short stagger, rows sliding off the spine as the line passes them.
- **Changes:** rows rerank in place with a smooth spring, keeping their identity; numbers roll; ticks re-light.
- **Loops:** the orb's breath (with its orbiting lights while thinking) and the glow ring's turn: MASTER's ceiling,
  the orb and one ring. While Claude thinks the ring holds still, so the orb is the page's only motion. Both pause when
  Home is not in front of a visible window and under Reduce Motion. The page has no other light: no ambient glow
  behind the dial; the orb's own halo marks now.
- **Reduce Motion:** a 0.16s fade instead of every entrance; no slides, no squish, no loops.

## 4. Keyboard and accessibility

- ⏎ or Esc on the page goes back to the shell; ↓ enters the log, ↑/↓ move between rows, ⏎ opens one in a terminal and
  ⌥⏎ in the editor; Esc leaves the log. A focused row has a 2pt coral ring.
- Every row is one accessibility element ("glance, ~/Code/glance, on main, 2m ago") with a default action and an
  "Open in Razor Code" action. The dial is hidden from VoiceOver: the readout says the same in words.
- Text pairs, measured on the grounds (#131211 dark, #f4f1ea light): ink, body, muted, and the coral, teal, green, amber
  and red inks all pass 4.5:1. Coral as light-theme text is #b0401c here, since MASTER's #c4471f measures 4.4:1 on
  this ground. Lit ticks are 4.9:1 (dark) and 3.4:1 (light) as graphics.
- Clicks land even while the window is in back (`acceptsFirstMouse`).

## 5. The chrome

- **Selection** is MASTER §8's: the selected tab's plate is glass with a coral tint and a 1pt coral edge, and it slides
  between rows and up to Home; the top bar's title has a short coral underline.
- **Kinds** show in the glyph, not in colour: `>_` for a terminal, the symbol otherwise, neutral (brighter when lit).
  Home in the sidebar is a row like any tab, with a house.
- **Buttons** light with neutral glass under the pointer; a toggle that is on (the sidebar, Home) glows coral.
- **Plan usage** in the top bar is a plain 3pt teal bar per window, like the Glance pane's strip.
- **Claude's state** in a tab row uses Home's colours: a teal light that pulses while thinking, a green check when
  finished. The bell is an amber light. Badges are flat lights, with no halo.
- **Gone:** the cyan to violet aurora, the sidebar's coloured atmosphere, the lit aurora tiles, and glows on badges.

## 6. Contract

`HomeModel` (GlanceKit) is the page's whole interface: the window controller calls `push(HomeState)` whenever
something on the page changes, sets `isActive` (the tab in front in a visible window), calls `requestFocus()` when the
window becomes key, and handles `onAction(HomeAction)`: `newTerminal`, `newEditor`, `focusTerminal`,
`openProject(path, terminal|editor)`, `toggleGlance`, `settings`, `setShowAtLaunch`.
