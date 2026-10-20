# First Light (onboarding): page notes

**Surface:** Glance Studio's first-launch window (spec `docs/superpowers/specs/2026-10-10-first-light-onboarding-design.md`),
also replayed from Help → Welcome to Glance Studio…. Native SwiftUI in the fork's `Features/Glance/Onboarding/`; the
scene is `FirstLightScene` (GlanceCore) shaded by `FirstLight.metal`. Mode: **Experience** for the intro, **Operate**
for the setup cards.

First Light follows MASTER.md and the Studio chrome's tokens (`StudioColors`, `.studio` / `.studioMono`,
`StudioButton`, `GlowPill`). This file records only where it departs, and why.

## Overrides

- **One authored moment, a larger motion budget.** MASTER §6 caps a view at one or two moving things. First Light is
  shown once, so the mark's assembly (24 ticks in flight, the dial settling, the orb inflating) is allowed as a single
  choreographed entrance. After it, the budget is MASTER's again: the orb breathes, the pointer leans the dial, and one
  thing changes at a time (a quarter lighting, the orb's colour, a satellite arriving).
- **The orb is a lit 3D sphere** (glass body, subsurface coral, fresnel rim, a pointer-lit highlight) rather than §7.2's
  radial gradient. Its colours keep §7.2's meaning: coral calm or speaking, teal thinking, amber reading.
- **The dial is the progress bar.** Unfinished quarters sit at 36%; each finished step lights its quarter. There is no
  step header or eyebrow; the footer carries "2 of 4" in mono.
- **Display size 34pt** for the "Glance Studio" wordmark on the intro (MASTER's display is 28). Cards use 23pt titles.

## Kept

- One glow: the intro's Begin and the finish's Open Glance Studio (`GlowPill`), never both on screen.
- No sound until the user picks a voice or presses Say hello.
- Reduce Motion: the finished mark from the first frame, fades instead of rises, no parallax, a 0.3s finale.
  Reduce Transparency: the cards are `StudioColors.solid`.
- Light and dark: graphite `#131211` with additive light, or paper `#f4f1ea` where the orb casts a warm shadow.
- The clock stops when the window is off screen; the permission poll runs only on the Permissions step.
