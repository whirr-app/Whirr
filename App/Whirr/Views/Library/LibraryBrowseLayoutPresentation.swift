import DesignSystem
import Foundation
import SwiftUI

/// Pure layout and navigation ownership for the Library browse surface. Callers provide the local
/// measured width; this type only selects the presentation and delegates all column arithmetic to
/// `AdaptiveListLayout`.
nonisolated enum LibraryBrowseLayoutPresentation {
  nonisolated enum IndexOwner: Equatable {
    case nativeList
    case jumpMenu
  }

  /// Minimum width of the cover itself, not the outer card that contains it.
  static let regularCoverMinimumWidth: CGFloat = 140
  /// Minimum width of the cover itself at accessibility sizes, not an outer card width.
  static let accessibilityCoverMinimumWidth: CGFloat = 200
  static let gridSpacing: CGFloat = WhirrSpacing.small

  /// The inner width budget for the stacked-cover and author-name content. The card's own padding
  /// is added below, so the outer minimum is named separately from the cover widths.
  static let authorCardInnerMinimumWidth: CGFloat = 296
  static let authorCardContentPadding: CGFloat = WhirrSpacing.small
  static let authorCardOuterMinimumWidth: CGFloat =
    authorCardInnerMinimumWidth + 2 * authorCardContentPadding

  static func resolve(
    for mode: LibraryBrowsePresentation.Mode,
    horizontalSizeClass: UserInterfaceSizeClass?,
    availableWidth: CGFloat?,
    isAccessibilitySize: Bool = false
  ) -> AdaptiveListLayout {
    AdaptiveListLayout.resolve(
      horizontalSizeClass: horizontalSizeClass,
      availableWidth: availableWidth,
      minimumTileWidth: minimumTileWidth(for: mode, isAccessibilitySize: isAccessibilitySize),
      spacing: gridSpacing)
  }

  static func minimumTileWidth(
    for mode: LibraryBrowsePresentation.Mode,
    isAccessibilitySize: Bool
  ) -> CGFloat {
    switch mode {
    case .titles, .series:
      isAccessibilitySize ? accessibilityCoverMinimumWidth : regularCoverMinimumWidth
    case .authors:
      authorCardOuterMinimumWidth
    case .collections:
      // Never laid out as tiles (`indexOwner(for:mode:)`); the cover rung keeps the value finite.
      isAccessibilitySize ? accessibilityCoverMinimumWidth : regularCoverMinimumWidth
    }
  }

  static func tileWidth(forAvailableWidth width: CGFloat, columns: Int) -> CGFloat {
    AdaptiveListLayout.tileWidth(
      forContentWidth: width, columns: columns, spacing: gridSpacing)
  }

  static func indexOwner(for horizontalSizeClass: UserInterfaceSizeClass?) -> IndexOwner {
    horizontalSizeClass == .regular ? .jumpMenu : .nativeList
  }

  /// Collections uses the compact list at every width. A library holds tens of collections, not
  /// thousands of titles, so the collection-view host never sees the mode.
  static func indexOwner(
    for horizontalSizeClass: UserInterfaceSizeClass?, mode: LibraryBrowsePresentation.Mode
  ) -> IndexOwner {
    switch mode {
    case .titles, .authors, .series: indexOwner(for: horizontalSizeClass)
    case .collections: .nativeList
    }
  }

  static func indexMenuIsVisible(isQueryEffective: Bool) -> Bool {
    isQueryEffective == false
  }

  /// The scroll target for one alphabet section, qualified by the mode that owns it.
  ///
  /// All modes share one lazy container, so a bare letter has the same identity in Titles, Authors
  /// and Series and a mode switch would keep the old mode's realised cells until scrolled out.
  /// Qualifying it makes the switch a replacement.
  static func sectionTargetID(
    for sectionID: String,
    in mode: LibraryBrowsePresentation.Mode,
    hasItems: Bool
  ) -> String? {
    guard hasItems else { return nil }
    let normalizedID = sectionID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard normalizedID.isEmpty == false else { return nil }
    return "library-section-\(targetIDScope(for: mode))-\(normalizedID)"
  }

  /// Not `Mode.label`: a scroll target is not display copy, and a localised or reworded label
  /// must not repoint every section anchor.
  private static func targetIDScope(for mode: LibraryBrowsePresentation.Mode) -> String {
    switch mode {
    case .titles: "titles"
    case .authors: "authors"
    case .series: "series"
    case .collections: "collections"
    }
  }
}
