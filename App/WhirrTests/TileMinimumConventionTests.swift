import DesignSystem
import Foundation
import Testing

@testable import Whirr

/// Cross-section conflict 2 in the iPad plan: Sections 1 and 2 derived five columns at 802 pt from
/// a 140 pt minimum, Sections 3 and 6 four from a 164 pt one; both were right, measuring different
/// things.
///
/// The convention: the minimum is a cover width, and every surface converts it to its tile's outer
/// width before it reaches `AdaptiveListLayout.columnCount`, by adding the card's padding
/// (`WhirrSpacing.small`, including `EditorialCardSurfaceModifier.contentPadding`). A tile with no
/// card adds nothing, so the Library title grid passes its cover minimum straight through.
///
/// 140 and 200 are the only independent numbers; 164 and 224 are derived, and a surface
/// hard-coding either has left the convention.
@Suite("Tile minimum convention")
struct TileMinimumConventionTests {
  private static let cardPadding = WhirrSpacing.small

  @Test("every surface starts from the same standard and accessibility cover minimums")
  func surfacesShareOneCoverMinimumPair() {
    #expect(LibraryBrowseLayoutPresentation.regularCoverMinimumWidth == 140)
    #expect(LibraryBrowseLayoutPresentation.accessibilityCoverMinimumWidth == 200)

    #expect(AuthorSeriesGridMetrics.coverTileMinimumWidth == 140)
    #expect(AuthorSeriesGridMetrics.accessibilityCoverTileMinimumWidth == 200)

    #expect(PodcastsViewPresentation.showGridMinimumWidth(isAccessibilitySize: false) == 140)
    #expect(PodcastsViewPresentation.showGridMinimumWidth(isAccessibilitySize: true) == 200)

    #expect(HomeViewPresentation.ShelfLayout.standardCoverMinimumWidth == 140)
    #expect(HomeViewPresentation.ShelfLayout.accessibilityCoverMinimumWidth == 200)
  }

  @Test("a carded surface converts its cover minimum by exactly the card's own padding")
  func cardedSurfacesConvertByCardPadding() {
    for isAccessibilitySize in [false, true] {
      let cover = PodcastsViewPresentation.showGridMinimumWidth(
        isAccessibilitySize: isAccessibilitySize)
      #expect(
        PodcastsViewPresentation.showGridTileWidth(isAccessibilitySize: isAccessibilitySize)
          == cover + 2 * Self.cardPadding)

      let shelf = HomeViewPresentation.ShelfLayout.resolve(
        horizontalSizeClass: .regular,
        availableWidth: 802,
        isAccessibilitySize: isAccessibilitySize)
      #expect(shelf.outerCardWidth == shelf.minimumCoverWidth + 2 * Self.cardPadding)
    }

    #expect(
      AuthorSeriesGridMetrics.columnMinimumWidth(forTileMinimumWidth: 140)
        == 140 + 2 * EditorialCardSurfaceModifier.contentPadding)
    #expect(EditorialCardSurfaceModifier.contentPadding == Self.cardPadding)
  }

  /// The Library title and series grids draw covers with no card around them, so their conversion
  /// adds nothing and the cover minimum is the outer width. This is the convention holding, not
  /// an exception to it.
  @Test("an uncarded surface passes its cover minimum through unchanged")
  func uncardedSurfacePassesTheCoverMinimumThrough() {
    #expect(
      LibraryBrowseLayoutPresentation.minimumTileWidth(for: .titles, isAccessibilitySize: false)
        == LibraryBrowseLayoutPresentation.regularCoverMinimumWidth)
    #expect(
      LibraryBrowseLayoutPresentation.minimumTileWidth(for: .series, isAccessibilitySize: true)
        == LibraryBrowseLayoutPresentation.accessibilityCoverMinimumWidth)
  }

  /// The author card is the one surface whose minimum is genuinely an outer width, because what it
  /// must fit is a stacked-cover cluster and a name rather than one cover. It says so in its name.
  @Test("the author card states an outer minimum in its own name")
  func authorCardNamesItsOuterMinimum() {
    #expect(
      LibraryBrowseLayoutPresentation.authorCardOuterMinimumWidth
        == LibraryBrowseLayoutPresentation.authorCardInnerMinimumWidth + 2 * Self.cardPadding)
    #expect(
      LibraryBrowseLayoutPresentation.minimumTileWidth(for: .authors, isAccessibilitySize: false)
        == LibraryBrowseLayoutPresentation.authorCardOuterMinimumWidth)
  }

  /// The whole point of the convention: the same 802 pt pane gives different, correct answers, and
  /// the difference is the card, not a disagreement about the number.
  @Test("the audited portrait pane seats five uncarded covers and four carded ones")
  func auditedPortraitPaneSeatsFiveCoversAndFourCards() {
    #expect(
      AdaptiveListLayout.columnCount(
        forContentWidth: 802,
        minimumTileWidth: LibraryBrowseLayoutPresentation.regularCoverMinimumWidth,
        spacing: WhirrSpacing.small) == 5)
    #expect(
      AdaptiveListLayout.columnCount(
        forContentWidth: 802,
        minimumTileWidth: PodcastsViewPresentation.showGridTileWidth(isAccessibilitySize: false),
        spacing: WhirrSpacing.small) == 4)
  }
}
