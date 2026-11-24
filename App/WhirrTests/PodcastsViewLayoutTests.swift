import CoreGraphics
import DesignSystem
import SwiftUI
import Testing

@testable import Whirr

/// Page-column arithmetic for the Podcasts root: the regular-width inset, and the episode and shows
/// grid column counts and preview limit. All derive from one column width, so no two sections
/// disagree about the room the page has. The show detail screen keeps its own
/// `boundedContentWidth` arithmetic.
@Suite("Podcasts root page layout")
struct PodcastsViewLayoutTests {

  // MARK: - Page column inset

  @Test("compact stays at the base inset regardless of width")
  func pageColumnInsetCompactUsesBase() {
    #expect(
      PodcastsViewPresentation.pageColumnInset(availableWidth: 834, horizontalSizeClass: .compact)
        == 16)
    #expect(
      PodcastsViewPresentation.pageColumnInset(availableWidth: 2000, horizontalSizeClass: .compact)
        == 16)
    #expect(
      PodcastsViewPresentation.pageColumnInset(availableWidth: 320, horizontalSizeClass: nil) == 16)
  }

  @Test("regular stays at the base inset across every full-screen iPad width")
  func pageColumnInsetRegularStaysBaseAtDeviceWidths() {
    for width: CGFloat in [1376, 1210, 1032, 834] {
      #expect(
        PodcastsViewPresentation.pageColumnInset(availableWidth: width, horizontalSizeClass: .regular)
          == 16,
        "width \(width)")
    }
  }

  @Test("regular grows the inset to center the page once the window exceeds its maximum width")
  func pageColumnInsetRegularCentersBeyondPageMaxWidth() {
    #expect(
      PodcastsViewPresentation.pageColumnInset(availableWidth: 2000, horizontalSizeClass: .regular)
        == 232)
    // At the centering inset, the column itself is exactly `pageMaxWidth` wide.
    #expect(
      PodcastsViewPresentation.pageColumnWidth(availableWidth: 2000, horizontalSizeClass: .regular)
        == PodcastsViewPresentation.pageMaxWidth)
  }

  @Test("an invalid width falls back to the base inset")
  func pageColumnInsetInvalidWidthUsesBase() {
    for width: CGFloat in [.nan, 0, -100, .infinity] {
      #expect(
        PodcastsViewPresentation.pageColumnInset(availableWidth: width, horizontalSizeClass: .regular)
          == 16,
        "width \(width)")
    }
  }

  // MARK: - Page column width

  @Test("the column width is the available width less both insets")
  func pageColumnWidthSubtractsBothInsets() {
    #expect(
      PodcastsViewPresentation.pageColumnWidth(availableWidth: 1376, horizontalSizeClass: .regular)
        == 1344)
    #expect(
      PodcastsViewPresentation.pageColumnWidth(availableWidth: 1210, horizontalSizeClass: .regular)
        == 1178)
    #expect(
      PodcastsViewPresentation.pageColumnWidth(availableWidth: 1032, horizontalSizeClass: .regular)
        == 1000)
    #expect(
      PodcastsViewPresentation.pageColumnWidth(availableWidth: 834, horizontalSizeClass: .regular)
        == 802)
    // Compact uses the same base inset on both edges, so the same subtraction applies.
    #expect(
      PodcastsViewPresentation.pageColumnWidth(availableWidth: 400, horizontalSizeClass: .compact)
        == 368)
  }

  @Test("an invalid width passes through unchanged")
  func pageColumnWidthInvalidWidthPassesThrough() {
    #expect(
      PodcastsViewPresentation.pageColumnWidth(availableWidth: 0, horizontalSizeClass: .regular) == 0
    )
    #expect(
      PodcastsViewPresentation.pageColumnWidth(availableWidth: -50, horizontalSizeClass: .regular)
        == -50)
    #expect(
      PodcastsViewPresentation.pageColumnWidth(availableWidth: .infinity, horizontalSizeClass: .regular)
        .isInfinite)
    #expect(
      PodcastsViewPresentation.pageColumnWidth(availableWidth: .nan, horizontalSizeClass: .regular)
        .isNaN)
  }

  // MARK: - Episode column count

  @Test("compact never gains a second column, whatever its width")
  func episodeColumnCountCompactStaysSingle() {
    for width: CGFloat in [0, 320, 656, 1344, .infinity] {
      #expect(
        PodcastsViewPresentation.episodeColumnCount(columnWidth: width, horizontalSizeClass: .compact)
          == 1,
        "width \(width)")
    }
  }

  @Test("regular gains a second column exactly at the threshold")
  func episodeColumnCountRegularThreshold() {
    #expect(
      PodcastsViewPresentation.episodeColumnCount(columnWidth: 655, horizontalSizeClass: .regular)
        == 1)
    #expect(
      PodcastsViewPresentation.episodeColumnCount(columnWidth: 656, horizontalSizeClass: .regular)
        == 2)
    #expect(
      PodcastsViewPresentation.episodeColumnCount(columnWidth: 657, horizontalSizeClass: .regular)
        == 2)
  }

  @Test("every full-screen iPad column width clears the threshold")
  func episodeColumnCountRegularAtDeviceColumnWidths() {
    for columnWidth: CGFloat in [1344, 1178, 1000, 802] {
      #expect(
        PodcastsViewPresentation.episodeColumnCount(
          columnWidth: columnWidth, horizontalSizeClass: .regular) == 2,
        "columnWidth \(columnWidth)")
    }
  }

  @Test("a narrow regular column, such as a split-view scene, stays single")
  func episodeColumnCountNarrowRegularStaysSingle() {
    #expect(
      PodcastsViewPresentation.episodeColumnCount(columnWidth: 320, horizontalSizeClass: .regular)
        == 1)
  }

  @Test("an invalid column width stays single rather than guessing")
  func episodeColumnCountInvalidStaysSingle() {
    for width: CGFloat in [.nan, 0, -100, .infinity] {
      #expect(
        PodcastsViewPresentation.episodeColumnCount(columnWidth: width, horizontalSizeClass: .regular)
          == 1,
        "width \(width)")
    }
  }

  // MARK: - Episode pairing

  @Test("pairing groups row-major, preserving order, with an odd trailing single")
  func episodePairsGroupsInOrder() {
    #expect(PodcastsViewPresentation.episodePairs([Int]()) == [])
    #expect(PodcastsViewPresentation.episodePairs([1]) == [[1]])
    #expect(PodcastsViewPresentation.episodePairs([1, 2]) == [[1, 2]])
    #expect(PodcastsViewPresentation.episodePairs([1, 2, 3, 4, 5]) == [[1, 2], [3, 4], [5]])
  }

  // MARK: - Episode card widths

  @Test("each two-column card is half the column, less one gutter")
  func episodeColumnWidthSplitsTheColumn() {
    #expect(PodcastsViewPresentation.episodeColumnWidth(columnWidth: 1344) == 664)
    // At the threshold, each card is exactly the minimum width that set the threshold.
    #expect(
      PodcastsViewPresentation.episodeColumnWidth(
        columnWidth: PodcastsViewPresentation.episodeTwoColumnThreshold)
        == PodcastsViewPresentation.episodeTwoColumnCardMinWidth)
  }

  @Test("an invalid column leaves the two-column card unconstrained rather than collapsed")
  func episodeColumnWidthInvalidIsUnconstrained() {
    #expect(PodcastsViewPresentation.episodeColumnWidth(columnWidth: 0).isInfinite)
    #expect(PodcastsViewPresentation.episodeColumnWidth(columnWidth: -10).isInfinite)
  }

  @Test("the single-column card caps at the reading measure and never exceeds the column")
  func episodeSingleColumnCardWidthCapsAtReadingMeasure() {
    #expect(PodcastsViewPresentation.episodeSingleColumnCardWidth(columnWidth: 500) == 500)
    #expect(PodcastsViewPresentation.episodeSingleColumnCardWidth(columnWidth: 802) == 760)
    #expect(PodcastsViewPresentation.episodeSingleColumnCardWidth(columnWidth: 760) == 760)
  }

  @Test("an invalid column leaves the single-column card unconstrained rather than collapsed")
  func episodeSingleColumnCardWidthInvalidIsUnconstrained() {
    #expect(PodcastsViewPresentation.episodeSingleColumnCardWidth(columnWidth: 0).isInfinite)
    #expect(PodcastsViewPresentation.episodeSingleColumnCardWidth(columnWidth: -10).isInfinite)
    #expect(PodcastsViewPresentation.episodeSingleColumnCardWidth(columnWidth: .nan).isInfinite)
  }

  // MARK: - Shows grid columns

  @Test("show grid columns mirror the adaptive formula at the standard tile width")
  func showGridColumnCountStandardTile() {
    let tileWidth = PodcastsViewPresentation.showGridTileWidth(isAccessibilitySize: false)
    #expect(tileWidth == 164)
    #expect(PodcastsViewPresentation.showGridColumnCount(columnWidth: 1344, tileWidth: tileWidth) == 7)
    #expect(PodcastsViewPresentation.showGridColumnCount(columnWidth: 1178, tileWidth: tileWidth) == 6)
    #expect(PodcastsViewPresentation.showGridColumnCount(columnWidth: 1000, tileWidth: tileWidth) == 5)
    #expect(PodcastsViewPresentation.showGridColumnCount(columnWidth: 343, tileWidth: tileWidth) == 2)
  }

  @Test("show grid columns use the wider tile at accessibility sizes")
  func showGridColumnCountAccessibilityTile() {
    let tileWidth = PodcastsViewPresentation.showGridTileWidth(isAccessibilitySize: true)
    #expect(tileWidth == 224)
    #expect(PodcastsViewPresentation.showGridColumnCount(columnWidth: 1344, tileWidth: tileWidth) == 5)
    #expect(PodcastsViewPresentation.showGridColumnCount(columnWidth: 1000, tileWidth: tileWidth) == 4)
  }

  @Test("an invalid column or tile width leaves one safe column")
  func showGridColumnCountInvalidStaysOne() {
    #expect(PodcastsViewPresentation.showGridColumnCount(columnWidth: 0, tileWidth: 164) == 1)
    #expect(PodcastsViewPresentation.showGridColumnCount(columnWidth: 1000, tileWidth: 0) == 1)
    #expect(PodcastsViewPresentation.showGridColumnCount(columnWidth: .nan, tileWidth: 164) == 1)
  }

  // MARK: - Shows grid rows

  @Test("only the unbounded filters keep the shows grid lazy")
  func showsGridIsLazyOnlyForUnboundedFilters() {
    #expect(PodcastsViewPresentation.showsGridIsLazy(filter: .all) == false)
    #expect(PodcastsViewPresentation.showsGridIsLazy(filter: .yourShows))
    #expect(PodcastsViewPresentation.showsGridIsLazy(filter: .downloaded))
  }

  @Test("eager show rows are row-major and leave a short last row unpadded")
  func showGridRowsGroupInOrder() {
    #expect(PodcastsViewPresentation.showGridRows([Int](), columns: 2) == [])
    #expect(PodcastsViewPresentation.showGridRows([1, 2, 3], columns: 2) == [[1, 2], [3]])
    #expect(
      PodcastsViewPresentation.showGridRows([1, 2, 3, 4, 5, 6, 7], columns: 3)
        == [[1, 2, 3], [4, 5, 6], [7]])
    #expect(PodcastsViewPresentation.showGridRows([1, 2], columns: 0) == [[1], [2]])
  }

  @Test("eager show rows use the grid's column count, or two before the first measurement")
  func showGridRowColumnCountFallsBackToTwo() {
    let tileWidth = PodcastsViewPresentation.showGridTileWidth(isAccessibilitySize: false)
    #expect(
      PodcastsViewPresentation.showGridRowColumnCount(columnWidth: 1000, tileWidth: tileWidth)
        == PodcastsViewPresentation.showGridColumnCount(columnWidth: 1000, tileWidth: tileWidth))
    #expect(
      PodcastsViewPresentation.showGridRowColumnCount(columnWidth: 0, tileWidth: tileWidth) == 2)
    #expect(
      PodcastsViewPresentation.showGridRowColumnCount(columnWidth: .nan, tileWidth: tileWidth)
        == 2)
  }

  // MARK: - Shows preview limit

  @Test("compact keeps the curated preview count regardless of column width")
  func showsPreviewLimitCompactStaysEight() {
    #expect(
      PodcastsViewPresentation.showsPreviewLimit(
        columnWidth: 1344, horizontalSizeClass: .compact, isAccessibilitySize: false) == 8)
    #expect(
      PodcastsViewPresentation.showsPreviewLimit(
        columnWidth: 0, horizontalSizeClass: .compact, isAccessibilitySize: true) == 8)
  }

  @Test("regular previews exactly two full rows of whatever the grid can lay out")
  func showsPreviewLimitRegularIsTwoRows() {
    #expect(
      PodcastsViewPresentation.showsPreviewLimit(
        columnWidth: 1344, horizontalSizeClass: .regular, isAccessibilitySize: false) == 14)
    #expect(
      PodcastsViewPresentation.showsPreviewLimit(
        columnWidth: 1000, horizontalSizeClass: .regular, isAccessibilitySize: false) == 10)
    #expect(
      PodcastsViewPresentation.showsPreviewLimit(
        columnWidth: 1344, horizontalSizeClass: .regular, isAccessibilitySize: true) == 10)
  }

  @Test("regular keeps the curated count until the page column has been measured")
  func showsPreviewLimitRegularUnmeasuredStaysEight() {
    for width: CGFloat in [0, -1, .nan, .infinity] {
      #expect(
        PodcastsViewPresentation.showsPreviewLimit(
          columnWidth: width, horizontalSizeClass: .regular, isAccessibilitySize: false) == 8)
    }
  }

  @Test("the Shows chip lists every show; the other filters keep the preview")
  func showsSectionLimitFollowsFilter() {
    for sizeClass: UserInterfaceSizeClass in [.compact, .regular] {
      #expect(
        PodcastsViewPresentation.showsSectionLimit(
          filter: .yourShows, columnWidth: 1344, horizontalSizeClass: sizeClass,
          isAccessibilitySize: false) == .max)
    }
    #expect(
      PodcastsViewPresentation.showsSectionLimit(
        filter: .all, columnWidth: 1344, horizontalSizeClass: .compact,
        isAccessibilitySize: false) == 8)
    #expect(
      PodcastsViewPresentation.showsSectionLimit(
        filter: .all, columnWidth: 1344, horizontalSizeClass: .regular,
        isAccessibilitySize: false) == 14)
  }

  // MARK: - The column width, not the raw width, drives the grid and its preview limit

  @Test("a naive raw-width column count disagrees with the page column's own count")
  func rawWidthAndColumnWidthDisagreeOnColumnCount() {
    let availableWidth: CGFloat = 2000
    let tileWidth = PodcastsViewPresentation.showGridTileWidth(isAccessibilitySize: false)

    // Subtracting only the base inset ignores the centring once the window exceeds
    // `pageMaxWidth`.
    let naiveWidth = availableWidth - 2 * WhirrSpacing.medium
    let naiveColumns = PodcastsViewPresentation.showGridColumnCount(
      columnWidth: naiveWidth, tileWidth: tileWidth)

    // The page column width accounts for the centring inset.
    let columnWidth = PodcastsViewPresentation.pageColumnWidth(
      availableWidth: availableWidth, horizontalSizeClass: .regular)
    let columns = PodcastsViewPresentation.showGridColumnCount(
      columnWidth: columnWidth, tileWidth: tileWidth)

    #expect(naiveColumns == 11)
    #expect(columns == 8)
    #expect(naiveColumns != columns)

    // The same divergence reaches the preview limit.
    let naiveLimit = naiveColumns * 2
    let limit = PodcastsViewPresentation.showsPreviewLimit(
      columnWidth: columnWidth, horizontalSizeClass: .regular, isAccessibilitySize: false)
    #expect(naiveLimit == 22)
    #expect(limit == 16)
  }

}
