# Glance Journal: page notes

**Surface:** the Journal tab of **Glance Studio** (spec `docs/superpowers/specs/2026-10-09-journal-design.md`): the
setup page, Today, a day page with its entry cards, Insights, the Journal side bar, and Settings → Journal. Native
SwiftUI in the fork's `Features/Glance/Journal/` and `Settings/JournalSettings.swift`, fed by GlanceKit's
`JournalService`. Behind `Feature.journal` (not GA).

Journal follows MASTER.md as written and the Studio chrome's tokens (`StudioColors`, `.studio` / `.studioMono`,
`StudioIcon`, `StudioButton`, `SettingsGroup`/`SettingsRow`). Mode: **Operate**. It's a log you scan and correct, not a
page that performs. This file adds only what is specific to Journal.

---

## 1. The composition

| Part | What it is |
|---|---|
| **Side bar** | Filter field, then two fixed rows (Today with the clock icon, Insights with the chart icon), then "Days" and every past day newest first: short date, a one-line headline (or "Not recapped · N events", "Recap failed"), and a 7pt status dot: muted open, amber drafted, green reviewed, red failed. Rows use `SettingsRowPlate`, as Settings' side bar does. |
| **Page header** | `JournalPageHeader`: 22pt bold title (-0.01em), a 12.5pt muted line, actions on the right. Pages cap at 760pt (Insights 900) with 32pt side padding. |
| **Spine timeline** | Home's session-log spine reused for events. A 64pt right-aligned time column (JetBrains Mono 11, muted), a 1pt hairline spine with each event's 13pt line icon on a background-coloured disc, then the title (13 medium) and one muted line of facts. Rows size to their content (`fixedSize` vertically), so the spine runs unbroken. Grouped by project (most recent work first), then Meetings, then Notes; group names are `Caption`s. Notes draw their glyph in coral ink. |
| **Entry card** | 12pt corners, the `card` fill, a 1pt line (60% coral when starred). Title row: 15pt semibold title, then star / edit / delete as 14pt StudioIcons in 26pt hit squares (coral when lit). Under the title one muted meta line, "Fixed · api · 1 h 35 min", never an uppercase eyebrow above it. Then summary, the impact in teal mono, skills as chips, and the story (challenge, approach, outcome, lesson) under a "The story" disclosure. Edit swaps the reader for plain fields on the `field` fill. |
| **Day page** | Header actions: Mark reviewed (primary, drafted days), Draft recap / Redraft. Then "N new since the recap · Update" in coral ink, the error in danger ink, the headline (18 semibold) and the recap (13.5, 3pt extra leading, selectable), the entry cards, Add entry, the collapsed "What happened · N events" timeline, and **Delete this day at the foot**, apart from the actions that keep work. |
| **Setup page** | The journal icon in coral, "Your dev journey, written down each day" (24 bold), one paragraph of body, then two `SettingsGroup`s: "What Journal reads" (a switch per source) and "Before you start" (four plain disclaimer blocks on hairlines). Then Start journaling (primary, 34pt). No fine print, no modal. |
| **Insights** | Segmented range picker in the header (30 days · Quarter · Year). Cards: Activity, Where time went, Output + impact, Skills + themes, Journey. With fewer than 3 active days the three middle cards collapse into one "More soon" note. |

## 2. Data visualisation

- **Year grid:** 53 columns × 7 days, 10pt squares, 3pt gaps, 2pt corners. Five steps of coral on the `field` fill:
  none, under 1 h (28%), 1–3 h (50%), 3–5 h (75%), 5 h or more (100%). A "Less ▢▢▢▢▢ More" key sits under it. Below
  about 720pt it scrolls horizontally, anchored to this week. Each square's tooltip gives the date and the time.
- **Stats:** current streak, longest streak, busiest day, busiest hour as JetBrains Mono 18 semibold over an 11.5
  muted label, in an adaptive grid (130pt minimum) so they wrap on narrow pages.
- **Series palette** (`JournalPalette`): six fixed slots, Glance coral first, then blue, aqua, yellow, magenta and
  green, each stepped per mode. "Other" is always `line3`, and colours follow the entity, never its rank. Checked with
  the dataviz validator:
  - Light, against `#FFFDF9`: passes. Its contrast WARN is relieved by the always-shown legends.
  - Dark, against `#211F1D`: passes.

  | Slot | Light | Dark |
  |---|---|---|
  | coral | `#E8643C` | `#E8643C` |
  | blue | `#2A78D6` | `#3987E5` |
  | aqua | `#1BAF7A` | `#199E70` |
  | yellow | `#EDA100` | `#C98500` |
  | magenta | `#E87BA4` | `#D55181` |
  | green | `#008300` | `#008300` |
- **Charts:** stacked weekly bars for time by project, lines (monotone) for weekly output, stacked monthly areas for
  skills. One y-axis each, with legends always shown.

## 3. Copy

- "Your dev journey, written down each day"
- "Start journaling"
- "Your day is ready" with "Review" (the meeting nudge's card, labelled "Recap")
- "What happened that Glance can't see?"
- "Wrap up day"
- "Mark reviewed", "Redraft", "Draft recap", "Delete this day", "Add entry"
- "Redraft this reviewed day?" / "Your edited entries are kept."
- "N new since the recap · Update"
- "Journaling is off · Turn on"
- "Recaps need Claude Code installed"

Empty states say what will appear and when, never "No data".

## 4. Not yet verified on screen

This pass was a code review against MASTER.md and the craft floor; no capture of the live tab exists yet. The user's
hand check covers light and dark, narrow (360pt page) and wide windows, and keyboard focus through the side bar rows
and the entry card's icon buttons.
