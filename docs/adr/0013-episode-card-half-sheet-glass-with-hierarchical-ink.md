# ADR 0013: The episode card's half sheet keeps the system glass, with hierarchical ink

- Status: Accepted (2026-10-02)
- Date: 2026-10-02
- Supersedes: [ADR 0012](0012-episode-card-half-sheet-is-opaque.md)

## Context

ADR 0012 made the compact half sheet (`PodcastEpisodeCardSheet`, `.compactDetents`) opaque because
the system Liquid Glass at `.medium` let bright cover art behind the sheet drop the notes' secondary
text, drawn in `WhirrColorToken.textSecondary`, to 1.85–1.96:1 in the dark appearance and about
3.0:1 in the light. The opaque sheet read well but looked flat, and a cover-wash ground tried in its
place did not look right either.

The failure was the ink, not only the surface. `textSecondary` is one fixed grey solved against
the opaque grounds the app paints, so it cannot answer a ground that changes under it. The system's
hierarchical styles are drawn against the glass instead. `.secondary` is not usable here: it tops
out near 3.4:1 on white (`SecondaryTextContrastTests`), and the same sheet is opaque at `.large`.

Estimated from iPhone captures on 2026-10-02, glass at `.medium` over Home, sampling glyph cores
against the glass directly behind them:

| Text | Dark | Light |
|---|---|---|
| Header (show line, title, date) | ≥ 8.7:1 | ≥ 11.7:1 |
| Show notes, over a faint yellow cover behind the sheet | ≈ 4.6:1 at worst | ≥ 10.8:1 |

These come from scaled, compressed screenshots, so they are estimates. The dark notes figure sits
close to the line, and its yellow was fainter than the artwork ADR 0012 measured.

## Decision

The half sheet paints no `presentationBackground`, so the system glass shows at `.medium`. Its
secondary copy (the date line, the notes, the "Show notes" label, and the folded links and credits)
takes the system's hierarchical `.primary` through
`PodcastEpisodeCardViewPresentation.secondaryInk(onSystemGlass:)`. Hierarchy rests on size and
weight: the bold title3 title above callout notes and a small uppercase label. Every other host of
the card is opaque and keeps `textSecondary`.

## Consequences

- Accepted without a dark-appearance capture over bright yellow artwork, the case ADR 0012
  failed. The dark notes may dip under 4.5:1 over the brightest covers at `.medium`. The owner
  accepts that, as a drop of the same kind the system's own glass surfaces show; an audit finding
  there is this record, not a regression. At `.large` the sheet is opaque and must clear AA.
- This is per-surface ink, which ADR 0012 ruled out. It is scoped to the one surface on the
  system's glass, and the token itself is unchanged.
- `PodcastEpisodeCardGlassInkTests` pins the scope: no background on the half sheet, and no direct
  use of `textSecondary` in the card. It cannot measure the glass. Contrast there is evidence from
  the device.
