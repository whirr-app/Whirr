# ADR 0007: The metadata ladder is resolved against the page, not fixed

> Renumbered from 0004 on 2026-08-31: two ADRs shared that number. The content and its 2026-08-28
> acceptance are unchanged; `0004` now refers only to native RSS podcast subscriptions.

- Status: Accepted
- Date: 2026-08-28

> **Superseded in part by [ADR 0005](0005-dark-appearance-vetoes-light-ambient-canvases.md),
> itself superseded by the app-owned details and player appearance plan (private,
> `plans/app-owned-ambient-appearance-2026-09-06.md`).**
> The page-resolved ladder remains the ambient-page contract. Neither night canvas described in
> this history is reachable now: app appearance selects the pole, every Dark page sits inside the
> `0.26...0.40` band on the standard ladder, and the production user of the lifted ladder is the
> lower part of the Light band, `0.65` up to `0.7455`, where black ink at the standard floor rung
> falls under AA. See the plan's follow-up for why the Light band was widened below that edge.

## Context

`WhirrMetadataProminence` publishes one fixed opacity ladder — 1.0, 0.88, 0.80, 0.72, 0.64 — and
the ambient page's lightness bands are the *solution* to "the dimmest of those rungs clears WCAG AA
at every hue". That inverted dependency is why the light band stops at OKLab lightness 0.75: below
it, black ink at alpha 0.64 falls under 4.5:1.

The consequence was that Dark appearance could not dim a light-pole page below 0.75, and 0.75 is
where most light-pole artwork already sat. Measured over the reference corpus, a gold cover
rendered `#DAA42B` in both appearances; only artwork brighter than 0.75 moved at all. Fixing the
dark pole (commit `1f9e7136`) left this half untouched, because the light pole's floor is a
contrast constraint rather than a design choice.

## Decision

The ladder becomes a **function of the page it is drawn on**, resolved once when the palette is
built and carried on `AmbientCanvas`.

- `WhirrMetadataLadder` (DesignSystem) is a value carrying a floor alpha and the five rungs. Its
  `standard` case is today's table. `WhirrMetadataLadder(liftingFloorTo:)` maps that table affinely
  into `[floor, 1.0]`, preserving the ladder's shape — the wide title-to-author break and the even
  steps below it — instead of clamping rungs together.
- `CoverAmbientPalette` solves the least floor alpha at which the page's own ink clears
  `minimumAmbientInkContrast`, by the same binary search `timelineReadoutOpacity` already uses, and
  builds the canvas's ladder from it. A page with room to spare resolves to `standard` and nothing
  changes.
- `WhirrMetadataProminence.adaptiveStyle` becomes a `ShapeStyle` that reads the ladder from the
  environment at resolve time. Every existing call site is unchanged; the ambient surfaces publish
  their canvas's ladder alongside the tint they already publish.

With the ladder no longer fixed, the light band gains a night floor: `lightPageNightLightness`
= 0.64, where a light-pole page sits under Dark appearance.

## Why this shape

**The precedent already exists in this file.** `timelineReadoutOpacity` binary-searches its own
opacity up until it clears the same 4.5:1 bar, because a fixed 0.64 readout is not legible on every
page either. The metadata ladder had the identical problem and solved it in the opposite direction
— by constraining the page instead of the ink. Making both resolve against the page removes the
inversion rather than adding a second mechanism.

**Solving per page costs less hierarchy than a fixed night table.** Alpha 0.80 is the floor for the
*worst hue at the gamut's maximum chroma*. Real artwork is well inside that: at lightness 0.64 the
reference corpus resolves to 0.715–0.738, so those pages keep a ladder spanning about 0.27 rather
than the 0.20 a fixed 0.80 table would impose on every cover.

**The dead zone is unchanged as a statement about the standard ladder.** Between 0.4027 and 0.7456
no rung of the *standard* ladder is legible for either ink, and that is still what chooses polarity
at 0.5743. A night page at 0.64 sits inside that range and is legible only because it carries a
lifted ladder. Polarity is untouched: white ink at alpha 0.80 fails above 0.4804, so black is still
the only viable ink at 0.64, which is the pole the artwork already resolved to.

## Costs, accepted

The night ladder is flatter. Five prominence levels spanning roughly 0.73 to 1.0 express less
separation than 0.64 to 1.0 does, so on a dimmed night page the credit block's internal hierarchy
is compressed — the break between title and author narrows most, because it is the widest gap and
the affine map scales all gaps alike. This is the price of the deeper page and was chosen
deliberately over keeping 0.75.

Increase Contrast is unaffected: it takes the light band's bright end (0.92) in either appearance
and therefore always resolves to the standard ladder.

## Alternatives rejected

**Floor 0.72, band to 0.676.** Half the dimming for a ladder that still has to compress. Since the
compression is what costs the hierarchy, taking the smaller step pays most of the price for less of
the benefit.

**Clamping rungs at the floor rather than compressing.** `max(opacity, floor)` collapses quinary,
quaternary and tertiary into one shade at floor 0.80 — a ladder whose bottom three rungs are the
same colour is not a hierarchy.

**Sending mid-tone covers to the dark pole at night.** Genuinely dark nights for cool covers, but
ink polarity would flip at sunset for some covers and not others, and polarity would stop being a
property of the artwork alone — the invariant commit `84b400f0` established.
