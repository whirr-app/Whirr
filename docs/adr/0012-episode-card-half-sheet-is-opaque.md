# ADR 0012: The episode card's half sheet is opaque

- Status: **Superseded** 2026-10-02 by [ADR 0013](0013-episode-card-half-sheet-glass-with-hierarchical-ink.md)
- Date: 2026-10-01

## Context

On iPhone, the podcast episode card (`PodcastEpisodeCardSheet`, `.compactDetents`) opens at the
`.medium` detent. On iOS 26 and later a partial-height sheet with no `presentationBackground` is a
floating Liquid Glass surface, so the Home screen behind it — cover art included — shows through,
blurred, under the show notes. At `.large` the system makes the sheet opaque.

The notes, their "Show notes" label and the date line use `WhirrColorToken.textSecondary`. Measured
from device captures on an iOS 27 iPhone with the system glass, Home behind the sheet:

| Ground under the text | Dark | Light |
|---|---|---|
| Neutral glass | 5.6–6.3:1 | 5.5–6.0:1 |
| Glass over a bright cover (yellow artwork) | 1.85–1.96:1 | ≈3.0:1 |

The first figure clears WCAG 1.4.3 AA; the second does not. Toggling the iOS 27 glass appearance
setting made no measurable difference. `SecondaryTextContrastTests` asserts the token against the
opaque grounds the app paints, and the system sheet's glass is not one of them, so it could not
catch this.

An earlier draft of this record accepted the glass as a known exception, on the reasoning that a
listener who wants to read the notes drags the card to `.large`. Tried on device, the opaque half
sheet looked better as well as reading better, and the exception was withdrawn before it merged.

## Decision

The `.compactDetents` branch applies `.presentationBackground(Color(uiColor: .systemBackground))`,
so the half sheet is opaque at every detent. The token is not changed to compensate for a surface
the system supplies.

## Consequences

- Notes text at `.medium` sits on the same opaque ground as at `.large` and must clear AA in both.
  A failure at either detent is a real finding.
- `.regularPage` is a full page sheet and is unaffected.
- Do not tune `textSecondary` or add per-surface ink for the sheet. If the glass is ever brought
  back, the contrast measurements above are what that decision has to answer.
