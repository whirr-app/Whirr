# ADR 0005: Dark appearance vetoes light ambient canvases

- Status: Superseded by the app-owned details and player appearance plan (private,
  `plans/app-owned-ambient-appearance-2026-09-06.md`), approved 2026-09-06.
- Date: 2026-08-28

## Context

The ambient-page experiment let bright artwork keep a light-pole canvas in Dark appearance and
reduced its OKLab lightness from the light band's `0.75` floor to `0.64`. Device review showed that
this still emitted too much light compared with the Apple Music reference. It also created a
visible load transition: the unresolved fallback appeared at dark-pole lightness `0.26`, then the
resolved page brightened to `0.64`.

Because the resolved canvas publishes its own colour scheme, that bright page also made native
controls use their light appearance. On item detail, the selected Chapters/History segment was a
literal white surface even though the app preference was Dark.

## Decision

Dark appearance is an absolute veto on the light pole — but a pole veto, not a floor pin.

- Light appearance keeps the artwork-led rule: pale artwork may resolve to a light canvas, while
  darker artwork remains dark.
- Dark appearance always resolves to the dark pole, independent of the artwork's source lightness.
  Where in the dark band (`0.26...0.40`) the page sits depends on the pole the artwork came from:
  - A **native dark-pole cover** dims to the band's floor, `0.26`. The unresolved fallback uses
    that floor too, so for these covers palette arrival changes hue and chroma without raising the
    page's luminance.
  - A **vetoed light-pole cover** sits *above* the band at `0.46`, on the per-page lifted ladder
    ADR 0007 built. The veto has already charged it its own band and most of its chroma; the first
    cut of this decision pinned it to the `0.26` floor and rendered every bright cover near-black,
    and the second sent it to the `0.40` ceiling, where saturated gold still read as olive mud.
    The band's ceiling is the wall for the *standard* ladder, not for a page: at `0.46` fully
    opaque white ink clears 6.69:1 at the worst hue, and the worst floor lift the 1° sweep finds
    is `0.754` against the standard `0.64` — a mild flattening real artwork rarely needs in full.
    A saturated gold keeps 56% of its source chroma at `0.46`, against 45% at the ceiling and 29%
    at the floor — the difference between dark gold and olive.
- The canvas publishes the dark colour scheme, which keeps status/navigation chrome and native
  controls—including the item-detail segmented control—on their low-glare dark treatment.
- Increase Contrast takes the dark-pole floor in Dark appearance for every cover. For native dark
  covers it coincides with the night page; for vetoed covers it sits below it, trading the retained
  chroma for the band's maximum contrast.

The rule applies to both artwork-led full-page canvases: item detail and the expanded player.

## Consequences

Bright warm artwork cannot retain all of its source chroma on any white-ink page; saturated yellow
reads as dark gold at `0.46`, and nothing brighter is available — above roughly `0.55` neither ink
clears AA at any ladder alpha, and going past that wall means a black-ink page, which is the `0.64`
canvas this decision retired for emitting too much light and flipping system chrome. `0.46` is the
deliberate stopping point on that dial. Hue remains artwork-derived, and Light appearance still
presents the full bright treatment.

A vetoed cover's night ladder floor is lifted per page, so its dimmest metadata rung sits a little
higher than on an in-band page. And the page arrives `0.26` → `0.46` after extraction; that step
stays inside one pole and one colour scheme, where the flash this decision removed was the
pole-crossing jump to a black-ink canvas.

[ADR 0007](0007-page-resolved-metadata-ladder.md) (numbered 0004 until 2026-08-31) remains
accepted for its central decision: the
metadata hierarchy is resolved against the page it is drawn on, and the vetoed cover's `0.46`
night page is now the production user of its lifted ladder. Only its `0.64` black-ink night canvas
is superseded and no longer reachable.
