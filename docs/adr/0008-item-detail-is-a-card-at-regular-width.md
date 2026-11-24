# ADR 0008: Item detail is a centred card at regular width

- Status: Accepted
- Date: 2026-09-04

## Context

The iPad audit found two defects on item detail, and both were width defects rather than
composition defects. In `24-detail-landscape.png` the synopsis runs the full ~930 pt content pane
and the Resume control stretches to roughly 1,300 pt. Nothing about the page's *arrangement* was
implicated.

The first remedy tried the arrangement anyway. Section 6 of the iPad plan proposed a regular-width
hero placing the 300 pt cover beside its metadata, and it was built and reverted in one sitting
(`15f08fd4`). It fails for a structural reason that no unit test reaches: the metadata column is
short and the cover is tall, so pairing them opens an L-shaped hole under the credits which grows
with every sparsely described item. It also needed two compounding fixes on the way down —
`36-detail-sidebyside-v1-truncated.png` shows the title truncating once the hero is capped at the
640 pt reading measure, and `37-detail-sidebyside-v2-misaligned.png` shows the hero, action row and
prose taking three different leading edges once the hero is widened past it. Both were symptoms.

Capping prose at the reading measure and the action row at the control ceiling does fix the audited
defects, and `39-detail-reverted-capped.png` is a coherent page. But it exposes the real problem:
every block on item detail is phone-scaled — a 300 pt cover, a 640 pt measure, a 480 pt control
ceiling — so the page is a 640 pt column centred in a 1,178 pt pane with roughly 270 pt of dead
margin on each side, and the promoted cover pushes Details below the fold. The content has no wider
natural measure to grow into. A full screen is a dishonest container for it.

A split view (navigation left, detail right) was considered and rejected by the owner: it spends
half the screen permanently on a pane that is empty until something is tapped.

## Decision

At regular width, item detail is presented as a centred card over the dimmed section root. At
compact width it remains a push. This is a presentation decision made by the shell before the screen
exists; item detail itself is unchanged by it.

**Size is `.presentationSizing(.form)`, about 570 pt.** Measured against the two alternatives on the
audited 1,210 × 834 landscape: `.page` at about 930 pt (`41-detail-card-page-930pt.png`) is the
full-screen page with rounded corners and reproduces the marooned column it was meant to fix, and a
440 pt card (`42-detail-card-440pt.png`) is a phone floating on a tablet, truncating the title
harder while using less of the screen. `40-detail-card-form-570pt.png` is the accepted composition.
`.form` is what `SheetViewPresentation.Mode.regularForm` already denotes, so this adds no new sizing
vocabulary.

**The card follows the podcast episode card rather than introducing a mechanism.** That card is
already a shell-level `.sheet(item:)` bound to a `NavigationModel` presentation property, with a
binding that writes `nil` back so an interactive dismissal and a programmatic one take the same path
(`LibraryShellView.swift:424-444`, `LibraryShellView.swift:816-829`). Item detail takes the same
shape, including an explicit Close affordance: a card at `.form` sizing has no detents to drag, so
the drag indicator is not a dismissal affordance.

**Onward navigation drops the card and pushes behind it.** Author, series, chapters and the reader
remain pushes on the section's own path. This is the established behaviour of `navigate(to:)`, which
already clears `presentedEpisode` so the card drops and the destination pushes in one call. The card
does host a `NavigationStack`, as the episode card does, but only to carry the Close toolbar: item
detail has no `NavigationLink` or `navigationDestination` of its own, so nothing can push into it —
every onward route leaves through the `onOpenMetadata` callback and lands on the section path.

**Play dismisses the card.** The mini-player is the continuation of the action, and leaving a modal
standing over a shell whose mini-player has just appeared underneath it puts the two in conflict.

**Detail joins the editorial-wash suspension policy**, alongside settings, the episode card and the
expanded player, and the artwork-preflight teardown that `onDisappear` drives on the pushed
destination must fire on card dismissal.

**A `.itemDetail` route arriving from a deep link or state restoration opens the card at regular
width** and pushes at compact. The route itself is unchanged, so the two presentations stay one
navigation vocabulary.

## Consequences

One screen now has two presentations to keep working, and tests have to cover both. The compact push
is the shipping behaviour and does not change; the risk is that future work verifies only the card.

**Inside the card the horizontal size class reports `.compact`.** This corrects the assumption this
ADR was written under. Section 4's empirical finding — that sheet content reports `.regular` — was
measured on the episode card, which is `.page`-sized at about 930 pt. A `.form` sheet is about
570 pt, and SwiftUI resolves *that* width to a compact size class even though the window behind it
is regular. The first shipped wrapper asked its own environment which mode it was in, got
`.compactDetents`, and put a draggable detent stack with no Close control where the card should
have been (`51-detail-card-form-portrait.png` is the fix). So the window's size class is the
shell's to read, and the wrapper composes the card unconditionally.

Item detail itself is unaffected because its width policy reads a locally measured width rather
than the size class: `ItemDetailLayoutPresentation` takes `availableWidth` from the content's own
geometry, and its hero choice is keyed on Dynamic Type alone. Any size-class branch added inside
item detail would be wrong in the card while looking correct on the page, so width remains the
input. The same trap is open to every `.adaptiveSheetPresentation` host that resolves a narrow
presentation from inside its own sheet.

Because onward pushes land behind the card, tapping an author from the card dismisses it and the
Back control returns to the section root rather than to the item. That is a real behaviour change
from the push, and it is the same trade the episode card already makes.

A card reached by deep link on a cold launch stands over the section root rather than over the list
the user came from, since there is no history behind it.

Two of the three things unverified when this decision was taken have since been checked, on the
`detail-card` harness screen (`UIHarness+DetailCard.swift`), which raises the shipped wrapper over
the real Library browse root: `51-detail-card-form-portrait.png` is the card in portrait over a
populated grid, and the dimming reads. What remains unverified is artwork sharpness — the harness
draws its placeholder, so the 272 pt request against the drawn 300 pt cover has still only been
judged on the page, not in the card.

One pre-existing behaviour is more visible in the card than on the page: a long title still stops
at `ItemDetailHeroTextPresentation.fullMeasureLineLimit` (2), so the fixture's title truncates
mid-word. That cap is the shipping decision for every width and is not introduced here.
