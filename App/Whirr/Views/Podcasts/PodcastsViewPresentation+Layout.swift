import CoreGraphics
import DesignSystem
import Persistence
import SwiftUI

/// Fixed metrics and width and size-class policy for the Podcasts browse surfaces. The callers
/// provide the width measured inside their own insets; this extension only returns stable
/// presentation values.
nonisolated extension PodcastsViewPresentation {
  /// The shows grid sizes itself to the available width rather than to a device class: one cover
  /// plus its gutter is the unit, so an iPhone gets two or three columns and an iPad several more
  /// without a second layout to maintain.
  static let showGridMinimumWidth: CGFloat = 140

  /// Show tiles carry the editorial surface's two small inner insets. Keeping the content width
  /// at the existing minimum preserves the cover metric while allowing the card chrome to occupy
  /// its own space in both show grids.
  static let showGridTileWidth = showGridMinimumWidth + 2 * WhirrSpacing.small

  /// Feeds publish square, tall or wide artwork, and one library holds all three; a cover with no
  /// ratio of its own would give different tile heights in one grid row. Every podcast cover is
  /// pinned to this ratio and cropped to fill, as `HomeCardView` does on Home.
  static let coverAspectRatio: CGFloat = 1

  /// The latest-episodes list is scanned, not browsed, so its thumbnail stays far below show-tile
  /// size; otherwise the artwork decides how many episodes fit. The row owns the square:
  /// `HomeMoreView` lists the same card, so a size owned here would let the two drift.
  static let episodeThumbnailSize: CGFloat = PodcastEpisodeCardRowMetrics.coverSize

  /// The separator starts after the thumbnail and both horizontal spacing units, without moving
  /// the row content.
  static let episodeSeparatorLeadingInset = episodeThumbnailSize + WhirrSpacing.medium * 2

  /// Row height needs a ceiling that does not depend on how verbose a publisher is: unclamped, a
  /// single paragraph-length episode title pushes every row after it off the screen.
  static let episodeTitleLineLimit = 2
  static let episodeShowTitleLineLimit = 1

  /// The title area is reserved at this maximum whatever the title needs, so a two-line title does
  /// not leave its tile taller than its neighbour, as `HomeCardView`'s `titleLineLimit` does.
  static let showTileTitleReservedLineCount = 2

  /// The minimum cover width for a show grid. Accessibility sizes buy a larger cover rather than
  /// making the grid denser with the same small tile.
  static func showGridMinimumWidth(isAccessibilitySize: Bool) -> CGFloat {
    isAccessibilitySize ? 200 : Self.showGridMinimumWidth
  }

  /// The outer show-grid unit: the cover minimum plus the editorial surface's two small insets.
  static func showGridTileWidth(isAccessibilitySize: Bool) -> CGFloat {
    showGridMinimumWidth(isAccessibilitySize: isAccessibilitySize) + 2 * WhirrSpacing.small
  }

  /// A named exception for podcast episode content and headers. The general reading measure stays
  /// where it is; an episode row carries a title, date, duration, and 44 pt play control on one
  /// line, which the narrower prose measure cannot hold without wrapping the metadata.
  static let episodeReadingMeasure: CGFloat = 760

  /// Bounds regular-width episode content while leaving compact and unknown size classes at the
  /// width their parent supplied. Invalid measurements pass through unchanged so layout never
  /// invents a replacement width for a missing or transient geometry value.
  static func boundedContentWidth(
    availableWidth: CGFloat,
    horizontalSizeClass: UserInterfaceSizeClass?
  ) -> CGFloat {
    guard availableWidth.isFinite, availableWidth > 0 else { return availableWidth }
    guard horizontalSizeClass == .regular else { return availableWidth }
    return min(availableWidth, episodeReadingMeasure)
  }

  /// Keeps a regular-width episode card at the named measure while preserving the compact row
  /// margin. The base inset remains part of the row's cell geometry, so the card and its swipe
  /// container narrow together instead of only shrinking the row's content.
  static func boundedRowHorizontalInset(
    availableWidth: CGFloat,
    horizontalSizeClass: UserInterfaceSizeClass?,
    baseInset: CGFloat = WhirrSpacing.medium
  ) -> CGFloat {
    guard horizontalSizeClass == .regular,
      availableWidth.isFinite,
      availableWidth > 0
    else { return baseInset }
    return baseInset + max(0, (availableWidth - episodeReadingMeasure) / 2)
  }

  /// The larger header belongs to a window that is regular in both directions: every iPad
  /// full-screen window and an opened iPhone Duo. A Plus or Pro Max iPhone in landscape is regular
  /// width but compact height, and keeps the card header.
  private static func usesRegularHeader(
    horizontalSizeClass: UserInterfaceSizeClass?, verticalSizeClass: UserInterfaceSizeClass?
  ) -> Bool {
    horizontalSizeClass == .regular && verticalSizeClass == .regular
  }

  /// Compact headers share the existing Home/show-card variant; bulk warming continues to use that
  /// smaller variant. Only a regular header requests the larger one.
  static func headerArtworkRequestSize(
    horizontalSizeClass: UserInterfaceSizeClass?, verticalSizeClass: UserInterfaceSizeClass?
  ) -> CGFloat {
    usesRegularHeader(horizontalSizeClass: horizontalSizeClass, verticalSizeClass: verticalSizeClass)
      ? 240 : 140
  }

  /// Regular show headers use the available width for metadata beside a 240 pt cover, or 200 pt
  /// at accessibility sizes. Compact headers keep their 120 pt cover.
  static func headerArtworkSize(
    horizontalSizeClass: UserInterfaceSizeClass?,
    verticalSizeClass: UserInterfaceSizeClass?,
    isAccessibilitySize: Bool
  ) -> CGFloat {
    guard
      usesRegularHeader(
        horizontalSizeClass: horizontalSizeClass, verticalSizeClass: verticalSizeClass)
    else { return 120 }
    return isAccessibilitySize ? 200 : 240
  }

  // MARK: - Podcasts root page column (iPad width)
  //
  // Every regular-width root section shares one horizontal inset; `PodcastShowContentView` keeps
  // its own `boundedRowHorizontalInset` above.

  /// The gutter between the two cards in an episode row, and between the two reading-measure
  /// columns that set the page's own maximum width below. One value for both keeps a two-column
  /// row and the page's own cap agreeing about how much space sits between two 760 pt cards.
  static let episodeColumnGutter: CGFloat = WhirrSpacing.medium

  /// Two reading-measure columns plus the gutter between them: the widest the page ever needs to
  /// be, since neither an episode card nor a two-column pair grows past `episodeReadingMeasure`
  /// per card. Beyond this, extra width buys nothing, so the page centers instead of stretching.
  static let pageMaxWidth: CGFloat = 2 * episodeReadingMeasure + episodeColumnGutter

  /// The inset shared by every regular-width section of the root: the browse page margin Home
  /// uses too (`HomePodcastsBrowseLayout.pageInset`), capped at this root's `pageMaxWidth`.
  static func pageColumnInset(
    availableWidth: CGFloat,
    horizontalSizeClass: UserInterfaceSizeClass?,
    baseInset: CGFloat = WhirrSpacing.medium
  ) -> CGFloat {
    HomePodcastsBrowseLayout.pageInset(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass,
      maxContentWidth: pageMaxWidth, baseInset: baseInset)
  }

  /// The width left inside `pageColumnInset` on both edges. The episode columns, the shows grid
  /// and the preview limit all derive from it, so none can disagree about how much room the page
  /// has. Invalid measurements pass through unchanged, as in `boundedContentWidth`.
  static func pageColumnWidth(
    availableWidth: CGFloat,
    horizontalSizeClass: UserInterfaceSizeClass?
  ) -> CGFloat {
    guard availableWidth.isFinite, availableWidth > 0 else { return availableWidth }
    let inset = pageColumnInset(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass)
    return max(0, availableWidth - 2 * inset)
  }

  // MARK: - Latest Episodes columns

  /// A card's fixed chrome (two 12 pt content paddings, a 56 pt cover, two 12 pt inner gaps and
  /// a 44 pt play control) takes 148 pt before any metadata. Below roughly 172 additional points
  /// the title/date/duration column is too narrow to stay legible, which sets this floor at 320 pt.
  static let episodeTwoColumnCardMinWidth: CGFloat = 320

  /// Two minimum-width cards plus the gutter between them. Measured against the page column's own
  /// width, not the raw container width, so the threshold means the same thing everywhere it is
  /// evaluated.
  static let episodeTwoColumnThreshold: CGFloat =
    2 * episodeTwoColumnCardMinWidth + episodeColumnGutter

  /// Compact never gains a second column, whatever its width. Regular needs the page column to
  /// clear the threshold; an unmeasured or invalid column stays at one rather than guessing.
  static func episodeColumnCount(
    columnWidth: CGFloat,
    horizontalSizeClass: UserInterfaceSizeClass?
  ) -> Int {
    guard horizontalSizeClass == .regular, columnWidth.isFinite, columnWidth > 0 else { return 1 }
    return columnWidth >= episodeTwoColumnThreshold ? 2 : 1
  }

  /// How many Latest Episodes rows the page itself shows. The heading opens the full list.
  static let latestEpisodePreviewLimit = 10

  static func latestEpisodePreview(_ episodes: [HomePodcastEpisode]) -> [HomePodcastEpisode] {
    Array(episodes.prefix(latestEpisodePreviewLimit))
  }

  /// Row-major pairing for the two-column layout: newest at top-left, next at top-right, and so on.
  /// An odd count leaves its last row holding a single element rather than a padded pair.
  static func episodePairs<Element>(_ elements: [Element]) -> [[Element]] {
    guard elements.isEmpty == false else { return [] }
    return stride(from: 0, to: elements.count, by: 2).map { start in
      Array(elements[start..<Swift.min(start + 2, elements.count)])
    }
  }

  /// Each two-column card's width: the page column minus one gutter, split evenly between the
  /// pair. An unmeasured or invalid column returns `.infinity` (no constraint) rather than
  /// collapsing both cards to zero while a geometry pass is still pending.
  static func episodeColumnWidth(columnWidth: CGFloat) -> CGFloat {
    guard columnWidth.isFinite, columnWidth > 0 else { return .infinity }
    return max(0, (columnWidth - episodeColumnGutter) / 2)
  }

  /// The single-column card's width: the page column, capped at the same reading measure a
  /// two-column pair's card could never exceed either. The caller leading-aligns it instead of
  /// centering, since the page column itself is what centres on an oversized window.
  static func episodeSingleColumnCardWidth(columnWidth: CGFloat) -> CGFloat {
    guard columnWidth.isFinite, columnWidth > 0 else { return .infinity }
    return min(columnWidth, episodeReadingMeasure)
  }

  // MARK: - Your Shows grid columns

  /// Mirrors `GridItem(.adaptive(minimum:))`'s own column formula, so an explicit `.flexible`
  /// column count lays out identically to the adaptive grid it replaces, while also being a number
  /// the preview limit can read instead of guessing at a second copy of this arithmetic.
  static func showGridColumnCount(
    columnWidth: CGFloat,
    tileWidth: CGFloat,
    spacing: CGFloat = WhirrSpacing.small
  ) -> Int {
    guard columnWidth.isFinite, columnWidth > 0, tileWidth > 0 else { return 1 }
    let columns = Int(((columnWidth + spacing) / (tileWidth + spacing)).rounded(.down))
    return max(1, columns)
  }

  /// A lazy grid tears down rows that leave range and rebuilds them on return: two tiles' full
  /// view graphs in one scroll frame, which ran inside the Podcasts root's scroll hitches on
  /// device. The All view's preview is bounded, so it lays out eagerly and builds each tile once;
  /// the Shows and Downloaded filters list every show and stay lazy.
  static func showsGridIsLazy(filter: Filter) -> Bool {
    filter != .all
  }

  /// Row-major rows for the eager grid. A short last row stays short; the view pads it so its
  /// tiles keep the full rows' column width.
  static func showGridRows<Element>(_ elements: [Element], columns: Int) -> [[Element]] {
    let columns = max(1, columns)
    return stride(from: 0, to: elements.count, by: columns).map { start in
      Array(elements[start..<Swift.min(start + columns, elements.count)])
    }
  }

  /// The eager grid has no adaptive column to size from before the page's first geometry pass, so
  /// it assumes the compact phone's two columns rather than one, which would regroup and rebuild
  /// every tile when the width arrives.
  static func showGridRowColumnCount(columnWidth: CGFloat, tileWidth: CGFloat) -> Int {
    guard columnWidth.isFinite, columnWidth > 0 else { return 2 }
    return showGridColumnCount(columnWidth: columnWidth, tileWidth: tileWidth)
  }

  /// The Shows chip narrows the page to shows, so it lists every one; a capped preview there would
  /// hide most of what the chip was chosen to see. The header still pushes the all-shows page,
  /// which is also the route to Edit.
  static func showsSectionLimit(
    filter: Filter,
    columnWidth: CGFloat,
    horizontalSizeClass: UserInterfaceSizeClass?,
    isAccessibilitySize: Bool
  ) -> Int {
    guard filter != .yourShows else { return .max }
    return showsPreviewLimit(
      columnWidth: columnWidth, horizontalSizeClass: horizontalSizeClass,
      isAccessibilitySize: isAccessibilitySize)
  }

  /// `previewLimit` is a curated taste on compact, unrelated to how many would fit. Regular has
  /// the width for full rows, so the preview is two rows of whatever the grid can lay out, never
  /// a count the grid would wrap or under-fill.
  static func showsPreviewLimit(
    columnWidth: CGFloat,
    horizontalSizeClass: UserInterfaceSizeClass?,
    isAccessibilitySize: Bool
  ) -> Int {
    // An unmeasured width (before the page's first geometry pass) keeps the curated count rather
    // than a one-column count that would shrink the preview for a frame.
    guard horizontalSizeClass == .regular, columnWidth.isFinite, columnWidth > 0 else {
      return previewLimit
    }
    let columns = showGridColumnCount(
      columnWidth: columnWidth,
      tileWidth: showGridTileWidth(isAccessibilitySize: isAccessibilitySize))
    return columns * 2
  }
}
