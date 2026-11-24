import DesignSystem
import SwiftUI
import UIKit

/// The regular-width grid's column count and tile width for one layout pass, resolved through
/// `LibraryBrowseLayoutPresentation`.
nonisolated struct LibraryBrowseCollectionMetrics: Equatable {
  let columns: Int
  let tileWidth: CGFloat

  /// The width tiles share: the visible width inside the horizontal safe area, less the page's
  /// `WhirrSpacing.medium` inset on each side. The section's own leading and trailing insets are
  /// those same 16 points, so they are not subtracted again. A non-positive width, as on a first
  /// layout pass before the view has a size, is `nil` rather than `0`: `nil` keeps the two-column
  /// first-frame fallback, `0` would resolve one column.
  static func availableWidth(
    containerWidth: CGFloat, safeAreaLeading: CGFloat, safeAreaTrailing: CGFloat
  ) -> CGFloat? {
    let width = containerWidth - safeAreaLeading - safeAreaTrailing - 2 * WhirrSpacing.medium
    guard width.isFinite, width > 0 else { return nil }
    return width
  }

  static func resolve(
    for mode: LibraryBrowsePresentation.Mode,
    availableWidth: CGFloat?,
    isAccessibilitySize: Bool
  ) -> Self {
    let layout = LibraryBrowseLayoutPresentation.resolve(
      for: mode,
      horizontalSizeClass: .regular,
      availableWidth: availableWidth,
      isAccessibilitySize: isAccessibilitySize)
    let columns: Int = if case .grid(let count) = layout { count } else { 1 }
    guard let availableWidth else {
      return Self(
        columns: columns,
        tileWidth: LibraryBrowseLayoutPresentation.minimumTileWidth(
          for: mode, isAccessibilitySize: isAccessibilitySize))
    }
    return Self(
      columns: columns,
      tileWidth: LibraryBrowseLayoutPresentation.tileWidth(
        forAvailableWidth: availableWidth, columns: columns))
  }

  /// The width of one full row of tiles and the gaps between them. At most the available width,
  /// because `tileWidth` rounds down.
  var rowWidth: CGFloat {
    CGFloat(columns) * tileWidth
      + CGFloat(max(0, columns - 1)) * LibraryBrowseLayoutPresentation.gridSpacing
  }
}

/// The compositional layout for the regular-width Library. One flat layout, one section per
/// letter, so nothing above a tile is created or discarded a letter at a time.
@MainActor
enum LibraryBrowseCollectionLayout {
  static let letterHeaderKind = "library-letter-header"

  /// A title tile's height beyond its square cover: two reserved title lines, an optional
  /// two-line subtitle and the status row. Only an estimate; cells self-size.
  private static let tileTextHeightEstimate: CGFloat = 110
  private static let authorCardHeightEstimate: CGFloat = 96
  private static let fullWidthHeightEstimate: CGFloat = 44

  static func make(
    sectionAt: @escaping (Int) -> LibraryBrowseCollectionSection?,
    metrics: @escaping (LibraryBrowsePresentation.Mode) -> LibraryBrowseCollectionMetrics
  ) -> UICollectionViewCompositionalLayout {
    UICollectionViewCompositionalLayout { index, _ in
      guard let section = sectionAt(index) else { return nil }
      return layoutSection(for: section, isFirst: index == 0, metrics: metrics)
    }
  }

  private static func layoutSection(
    for section: LibraryBrowseCollectionSection,
    isFirst: Bool,
    metrics: (LibraryBrowsePresentation.Mode) -> LibraryBrowseCollectionMetrics
  ) -> NSCollectionLayoutSection {
    let layoutSection: NSCollectionLayoutSection
    // `WhirrSpacing.small` between stacked sections and at the top of the page, with the controls
    // row's own bottom padding added beneath it.
    var bottom = WhirrSpacing.small
    switch section {
    case .letter(let mode, _):
      let resolved = metrics(mode)
      let heightEstimate: CGFloat
      switch mode {
      case .authors: heightEstimate = authorCardHeightEstimate
      case .titles, .series: heightEstimate = resolved.tileWidth + tileTextHeightEstimate
      case .collections:
        preconditionFailure("Collections never reaches the collection-view host")
      }
      let item = NSCollectionLayoutItem(
        layoutSize: NSCollectionLayoutSize(
          widthDimension: .absolute(resolved.tileWidth),
          heightDimension: .estimated(heightEstimate)))
      let group = NSCollectionLayoutGroup.horizontal(
        layoutSize: NSCollectionLayoutSize(
          widthDimension: .absolute(resolved.rowWidth),
          heightDimension: .estimated(heightEstimate)),
        repeatingSubitem: item,
        count: resolved.columns)
      group.interItemSpacing = .fixed(LibraryBrowseLayoutPresentation.gridSpacing)
      layoutSection = NSCollectionLayoutSection(group: group)
      layoutSection.interGroupSpacing = LibraryBrowseLayoutPresentation.gridSpacing
      let header = NSCollectionLayoutBoundarySupplementaryItem(
        layoutSize: NSCollectionLayoutSize(
          widthDimension: .fractionalWidth(1),
          heightDimension: .estimated(fullWidthHeightEstimate)),
        elementKind: letterHeaderKind,
        alignment: .top)
      layoutSection.boundarySupplementaryItems = [header]
    case .controls, .banner, .state, .loadMore:
      let size = NSCollectionLayoutSize(
        widthDimension: .fractionalWidth(1),
        heightDimension: .estimated(fullWidthHeightEstimate))
      let group = NSCollectionLayoutGroup.horizontal(
        layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)])
      layoutSection = NSCollectionLayoutSection(group: group)
      if section == .controls { bottom += WhirrSpacing.small }
    }
    layoutSection.contentInsetsReference = .safeArea
    layoutSection.contentInsets = NSDirectionalEdgeInsets(
      top: isFirst ? WhirrSpacing.small : 0,
      leading: WhirrSpacing.medium,
      bottom: bottom,
      trailing: WhirrSpacing.medium)
    return layoutSection
  }
}
