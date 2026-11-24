import SwiftUI
import Testing

@testable import DesignSystem

/// The `List` variant of the editorial card surface: the card's fill becomes the row's background
/// instead of being drawn inside the cell. It has to stay visually identical to
/// `editorialCardSurface` (same radius, same inner padding), and the fill has to land under the
/// content rather than spanning the row's insets.
@Suite("Editorial card list row")
@MainActor
struct EditorialCardListRowTests {
  @Test("nil wash leaves the row without card chrome")
  func nilWashDoesNotApplyChrome() {
    #expect(EditorialCardListRowModifier(wash: nil).appliesChrome == false)
    #expect(EditorialCardListRowModifier(wash: .neutral).appliesChrome)
  }

  @Test("the row card is the same shape as the non-list card")
  func rowCardMatchesTheSurfaceCard() {
    // Two modifiers drawing the same card must never drift into two radii or two paddings: a row
    // and a grid tile for the same content sit on the same screen.
    #expect(EditorialCardListRowModifier.cornerRadius == EditorialCardSurfaceModifier.cornerRadius)
    #expect(
      EditorialCardListRowModifier.contentPadding == EditorialCardSurfaceModifier.contentPadding)
  }

  @Test("the fill is inset to exactly the row's own insets")
  func fillIsInsetToTheRowInsets() {
    // A `.listRowBackground` spans the whole row including its insets, so the fill has to be
    // padded back by those same insets or the card bleeds past the content it sits under.
    let modifier = EditorialCardListRowModifier(
      wash: .neutral, horizontalInset: 17, verticalInset: 5)

    #expect(modifier.rowInsets == EdgeInsets(top: 5, leading: 17, bottom: 5, trailing: 17))
    #expect(modifier.fillInsets == modifier.rowInsets)
  }

  @Test("the row defaults to the editorial list margin")
  func defaultInsetsMatchTheEditorialMargin() {
    let modifier = EditorialCardListRowModifier(wash: .neutral)

    #expect(
      modifier.rowInsets
        == EdgeInsets(
          top: WhirrSpacing.xSmall, leading: WhirrSpacing.medium,
          bottom: WhirrSpacing.xSmall, trailing: WhirrSpacing.medium))
  }

  @Test("exactly one card fill is visible in each state")
  func exactlyOneFillIsVisible() {
    for fillsInsideCell in [false, true] {
      let inside = EditorialCardListRowModifier.fillOpacity(
        insideCell: true, fillsInsideCell: fillsInsideCell)
      let outside = EditorialCardListRowModifier.fillOpacity(
        insideCell: false, fillsInsideCell: fillsInsideCell)

      #expect(inside + outside == 1)
    }
  }

  @Test("selecting moves the card fill inside the cell, so it follows the indented content")
  func selectingMovesTheFillInsideTheCell() {
    // The list indents the row's content to open the gutter for its selection circle, but a
    // `.listRowBackground` spans the whole cell. A card left outside stays put while its content
    // slides right, and the circle ends up on the card's leading edge.
    #expect(
      EditorialCardListRowModifier.fillsInsideCell(isSelecting: true, isOutsideList: false))
    #expect(EditorialCardListRowModifier.fillOpacity(insideCell: false, fillsInsideCell: false) == 1)
    #expect(EditorialCardListRowModifier.fillOpacity(insideCell: true, fillsInsideCell: true) == 1)
  }

  @Test("a row outside any list paints the fill inside the row")
  func aRowOutsideAListPaintsTheFillInside() {
    // Stack content has no `.listRowBackground` to draw into: an outside fill would simply not
    // draw.
    #expect(
      EditorialCardListRowModifier.fillsInsideCell(isSelecting: false, isOutsideList: true))
  }

  @Test("the swipeable state keeps its fill outside the cell")
  func theSwipeableStateKeepsTheFillOutside() {
    // Inside a `List`, the inner fill is only safe where there are no swipe actions to mask it: a
    // list in edit mode. The state that does have them must keep painting the card as the row's
    // background. See `EditorialCardSwipeChromeTests` for what an inner fill costs there.
    #expect(
      EditorialCardListRowModifier.fillsInsideCell(isSelecting: false, isOutsideList: false)
        == false)
    #expect(EditorialCardListRowModifier.fillOpacity(insideCell: true, fillsInsideCell: false) == 0)
  }

  @Test("view extension installs the editorial card list row modifier")
  func viewExtensionInstallsModifier() {
    let row = Color.clear.editorialCardListRow(.neutral)

    #expect(String(reflecting: type(of: row)).contains("EditorialCardListRowModifier"))
  }

  @Test("the row pads its content like the non-list card unless told otherwise")
  func contentPaddingDefaultsToTheSharedCardPadding() {
    #expect(
      EditorialCardListRowModifier(wash: .neutral).contentPadding
        == EditorialCardSurfaceModifier.contentPadding)
    #expect(EditorialCardListRowModifier(wash: .neutral, contentPadding: 0).contentPadding == 0)
  }

  @Test("a podcast episode card's inner padding is applied exactly once, by the row")
  func podcastEpisodeChromeLeavesTheContentPaddingToTheRow() {
    // Padding added by the modifier lands outside every control the row declares, so it becomes a
    // dead ring inside the card's edge. The row applies it instead (`PodcastEpisodeCardRow`).
    #expect(
      PodcastEpisodeCardRowMetrics.contentPadding == EditorialCardSurfaceModifier.contentPadding)
    #expect(
      PodcastEpisodeCardRow<Color>.cardContentPadding
        == PodcastEpisodeCardRowMetrics.contentPadding)
  }

  @Test("every podcast episode card sits on the same rhythm")
  func podcastEpisodeRowsShareOneVerticalInset() {
    // One modifier for every episode list, so the Podcasts shelf and the Latest Episodes screen
    // cannot drift into two spacings.
    #expect(PodcastEpisodeCardRowMetrics.verticalInset == WhirrSpacing.xSmall)

    let row = Color.clear.podcastEpisodeCardListRow(.neutral)

    #expect(String(reflecting: type(of: row)).contains("EditorialCardListRowModifier"))
  }
}
