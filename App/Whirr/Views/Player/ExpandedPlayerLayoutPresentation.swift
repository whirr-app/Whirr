import CoreGraphics
import DesignSystem

/// Pure geometry policy for the expanded player. The view supplies measured page and metadata
/// dimensions; this type only decides which composition can fit and how that composition spends
/// its available space.
nonisolated enum ExpandedPlayerLayoutPresentation {
  /// A platform-neutral replacement for reading SwiftUI's `UserInterfaceSizeClass` in the resolver.
  nonisolated enum WidthClass: Equatable, Sendable {
    case compact
    case regular
  }

  nonisolated enum ChromePlacement: Equatable, Sendable {
    case pageBottom
  }

  nonisolated enum OverflowPolicy: Equatable, Sendable {
    case upperRegionScroll
  }

  nonisolated struct StackedPlan: Equatable, Sendable {
    let horizontalPadding: CGFloat
    let contentWidth: CGFloat
    let artworkSize: CGFloat
    /// Compact: the slack-bearing seam. Regular: a fixed design gap between artwork and metadata.
    let artworkToMetadataSpacing: CGFloat
    let metadataHeight: CGFloat
    let upperRegionHeight: CGFloat
    let clusterHeight: CGFloat
    let upperSlack: CGFloat
    let upperSlackAbove: CGFloat
    let upperSlackBelow: CGFloat
    let chromePlacement: ChromePlacement
    let overflowPolicy: OverflowPolicy
    let allowsVerticalOverflow: Bool
    let quickActionMinimumHeight: CGFloat
  }

  /// A short page's two columns: the cover on the left, and on the right the metadata above the
  /// chrome. The page's padding, cover, gap and detail column always sum to its width.
  nonisolated struct SideBySidePlan: Equatable, Sendable {
    let horizontalPadding: CGFloat
    let artworkSize: CGFloat
    let columnSpacing: CGFloat
    let detailColumnWidth: CGFloat
    let quickActionMinimumHeight: CGFloat
  }

  nonisolated enum Plan: Equatable, Sendable {
    case compactStacked(StackedPlan)
    case regularStacked(StackedPlan)
    case sideBySide(SideBySidePlan)

    var stackedPlan: StackedPlan? {
      switch self {
      case .compactStacked(let plan), .regularStacked(let plan): plan
      case .sideBySide: nil
      }
    }

    var sideBySidePlan: SideBySidePlan? {
      if case .sideBySide(let plan) = self { plan } else { nil }
    }
  }

  /// The regular-width geometry: 64pt side insets leave 706pt on an 834pt page.
  nonisolated static let regularSideInset: CGFloat = 64
  nonisolated static let regularColumnMaximum: CGFloat = 720
  private nonisolated static let compactArtworkMaximumSize: CGFloat = 380
  /// The regular-width artwork cap. It is reachable in portrait and height-bound in landscape,
  /// where the shorter upper region keeps the resolved cover below this value.
  nonisolated static let regularArtworkMaximumSize: CGFloat = 620
  nonisolated static let artworkMinimumSize: CGFloat = 210
  nonisolated static let artworkHeightShare: CGFloat = 0.70
  nonisolated static let artworkToMetadataSpacing: CGFloat = WhirrSpacing.xLarge
  /// The narrowest right-hand column that still fits the chrome's quick actions on one row. The
  /// cover gives way to it, so an iPhone SE landscape page keeps a usable column.
  nonisolated static let sideBySideDetailMinimumWidth: CGFloat = 300
  /// Below this the side-by-side cover stops reading as the page's subject, and the page stays
  /// stacked instead. Lower than the stacked floor because this cover never scrolls away.
  nonisolated static let sideBySideArtworkMinimumSize: CGFloat = 160
  /// The gap kept above and below the side-by-side cover inside the region under the handle.
  private nonisolated static let sideBySideVerticalInset: CGFloat = WhirrSpacing.small
  /// The compact column ceiling used by the horizontal-padding equation.
  private nonisolated static let compactColumnMaximum: CGFloat = 560

  // Mirror the compact metrics so the nonisolated resolver need not reach into the MainActor view
  // type. `ExpandedPlayerView` keeps the canonical named surface for its callers.
  private nonisolated static let compactCoverHeightShare: CGFloat = artworkHeightShare
  private nonisolated static let compactUpperTopSlackShare: CGFloat = 0.3
  private nonisolated static let compactUpperTopSlackCap: CGFloat = 40

  /// A regular-width page shorter than this has no room to stack: the chrome takes most of it and
  /// the regular cover lands on its floor. An opened iPhone Duo (669pt) is below it; the shortest
  /// iPad landscape page (iPad mini, 744pt) is above it.
  nonisolated static let shortRegularPageMaximumHeight: CGFloat = 700

  /// Orientation is not an input; vertical size class and page height are. A regular-height page
  /// at least `shortRegularPageMaximumHeight` tall (every iPad, in either orientation) keeps one
  /// stacked arrangement and differs only through the shorter `upperRegionHeight` it passes, since
  /// two columns on iPad landscape leave a void beside the capped cover. A compact-height page (an
  /// iPhone in landscape) or a short regular-width page (an opened iPhone Duo) has no height to
  /// stack in, so it puts the cover beside the details whenever both columns fit their minimums.
  /// `pageHeight` is the whole page's; a caller that re-resolves only the stacked upper region
  /// omits it, so that region never changes composition.
  nonisolated static func resolve(
    widthClass: WidthClass,
    isCompactHeight: Bool = false,
    pageWidth: CGFloat,
    pageHeight: CGFloat? = nil,
    upperRegionHeight: CGFloat,
    measuredMetadataHeight: CGFloat,
    isAccessibilitySize: Bool
  ) -> Plan {
    let width = finiteNonnegative(pageWidth)
    let upperHeight = finiteNonnegative(upperRegionHeight)
    let isShortRegularPage =
      widthClass == .regular
      && pageHeight.map { finiteNonnegative($0) < shortRegularPageMaximumHeight } == true

    if isCompactHeight || isShortRegularPage,
      let side = sideBySidePlan(
        pageWidth: width, regionHeight: upperHeight, isAccessibilitySize: isAccessibilitySize)
    {
      return .sideBySide(side)
    }

    guard widthClass == .regular else {
      return .compactStacked(
        compactStackedPlan(
          pageWidth: width, upperRegionHeight: upperHeight,
          measuredMetadataHeight: measuredMetadataHeight,
          isAccessibilitySize: isAccessibilitySize))
    }

    return .regularStacked(
      regularStackedPlan(
        pageWidth: width, upperRegionHeight: upperHeight,
        measuredMetadataHeight: measuredMetadataHeight,
        isAccessibilitySize: isAccessibilitySize))
  }

  private nonisolated static func compactStackedPlan(
    pageWidth: CGFloat,
    upperRegionHeight: CGFloat,
    measuredMetadataHeight: CGFloat,
    isAccessibilitySize: Bool
  ) -> StackedPlan {
    // Keep in lockstep with `ExpandedPlayerView.upperLayout`: 24pt seam, 30/70 slack split and
    // 40pt top-slack cap.
    let horizontalPadding = max(WhirrSpacing.large, (pageWidth - compactColumnMaximum) / 2)
    let contentWidth = max(0, pageWidth - (horizontalPadding * 2))
    let metadataHeight = measuredBandHeight(measuredMetadataHeight)
    let heightBound = upperRegionHeight - WhirrSpacing.large - metadataHeight
    let coverUpperBound = min(
      contentWidth,
      min(
        compactArtworkMaximumSize,
        min(compactCoverHeightShare * upperRegionHeight, heightBound)))
    let artworkSize = max(artworkMinimumSize, coverUpperBound)
    let upperSlack = max(
      0,
      upperRegionHeight - artworkSize - WhirrSpacing.large - metadataHeight)
    let upperSlackAbove = min(
      upperSlack * compactUpperTopSlackShare,
      compactUpperTopSlackCap)
    let artworkToMetadataSpacing = WhirrSpacing.large + (upperSlack - upperSlackAbove)

    return StackedPlan(
      horizontalPadding: horizontalPadding,
      contentWidth: contentWidth,
      artworkSize: artworkSize,
      artworkToMetadataSpacing: artworkToMetadataSpacing,
      metadataHeight: metadataHeight,
      upperRegionHeight: upperRegionHeight,
      clusterHeight: artworkSize + artworkToMetadataSpacing + metadataHeight,
      upperSlack: upperSlack,
      upperSlackAbove: upperSlackAbove,
      upperSlackBelow: 0,
      chromePlacement: .pageBottom,
      overflowPolicy: .upperRegionScroll,
      allowsVerticalOverflow: true,
      quickActionMinimumHeight: quickActionMinimumHeight(isAccessibilitySize: isAccessibilitySize))
  }

  private nonisolated static func regularStackedPlan(
    pageWidth: CGFloat,
    upperRegionHeight: CGFloat,
    measuredMetadataHeight: CGFloat,
    isAccessibilitySize: Bool
  ) -> StackedPlan {
    let availableColumnWidth = max(0, pageWidth - (regularSideInset * 2))
    let contentWidth = min(regularColumnMaximum, availableColumnWidth)
    let horizontalPadding = max(regularSideInset, (pageWidth - contentWidth) / 2)
    let metadataHeight = measuredBandHeight(measuredMetadataHeight)
    let availableByHeight = min(
      artworkHeightShare * upperRegionHeight,
      upperRegionHeight - artworkToMetadataSpacing - metadataHeight)
    let artworkSize = ExpandedPlayerViewMetrics.clampedCoverSize(
      preferredSize: regularArtworkMaximumSize,
      availableWidth: min(contentWidth, availableByHeight),
      minimumSize: artworkMinimumSize,
      maximumSize: regularArtworkMaximumSize)
    let clusterHeight = artworkSize + artworkToMetadataSpacing + metadataHeight
    let upperSlack = max(0, upperRegionHeight - clusterHeight)
    let upperSlackAbove = upperSlack / 2

    return StackedPlan(
      horizontalPadding: horizontalPadding,
      contentWidth: contentWidth,
      artworkSize: artworkSize,
      artworkToMetadataSpacing: artworkToMetadataSpacing,
      metadataHeight: metadataHeight,
      upperRegionHeight: upperRegionHeight,
      clusterHeight: clusterHeight,
      upperSlack: upperSlack,
      upperSlackAbove: upperSlackAbove,
      upperSlackBelow: upperSlack - upperSlackAbove,
      chromePlacement: .pageBottom,
      overflowPolicy: .upperRegionScroll,
      allowsVerticalOverflow: true,
      quickActionMinimumHeight: quickActionMinimumHeight(isAccessibilitySize: isAccessibilitySize))
  }

  private nonisolated static func sideBySidePlan(
    pageWidth: CGFloat,
    regionHeight: CGFloat,
    isAccessibilitySize: Bool
  ) -> SideBySidePlan? {
    let horizontalPadding = WhirrSpacing.large
    let columnSpacing = WhirrSpacing.xLarge
    let contentWidth = pageWidth - (horizontalPadding * 2)
    let widthBound = contentWidth - columnSpacing - sideBySideDetailMinimumWidth
    let heightBound = regionHeight - (sideBySideVerticalInset * 2)
    let artworkSize = min(compactArtworkMaximumSize, heightBound, widthBound)
    guard artworkSize >= sideBySideArtworkMinimumSize else { return nil }

    return SideBySidePlan(
      horizontalPadding: horizontalPadding,
      artworkSize: artworkSize,
      columnSpacing: columnSpacing,
      detailColumnWidth: contentWidth - columnSpacing - artworkSize,
      quickActionMinimumHeight: quickActionMinimumHeight(isAccessibilitySize: isAccessibilitySize))
  }

  /// Whether the page scroll view clips to its bounds. While the content fits nothing scrolls, so
  /// the clip only cuts the cover's drop shadow along the edge under the dismiss handle; once the
  /// content overflows, the clip keeps scrolled text off the handle and the chrome below. The
  /// point of slack absorbs layout rounding.
  ///
  /// The Up Next header never clips: its content fits by construction (it is shown only at
  /// non-accessibility sizes), but its frame springs past that content as the cover lands, and a
  /// clip for those frames cuts the cover's shadow along the header's bottom edge.
  nonisolated static func pageScrollClipsContent(
    contentHeight: CGFloat, containerHeight: CGFloat, isInlineQueueHeader: Bool
  ) -> Bool {
    !isInlineQueueHeader && contentHeight > containerHeight + 1
  }

  private nonisolated static func measuredBandHeight(_ height: CGFloat) -> CGFloat {
    height.isFinite && height > 0 ? height : 72
  }

  private nonisolated static func quickActionMinimumHeight(isAccessibilitySize: Bool) -> CGFloat {
    PlayerQuickActionLayoutValues.resolve(isAccessibilitySize: isAccessibilitySize).minimumHeight
  }

  private nonisolated static func finiteNonnegative(_ value: CGFloat) -> CGFloat {
    value.isFinite ? max(0, value) : 0
  }
}
