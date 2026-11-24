import Foundation
import SwiftUI

/// Which column layout the storage and resolution-center screens use for a given horizontal size
/// class. A pure mapping for `WhirrTests`. `nonisolated` so the App target's `MainActor` default
/// doesn't block plain test functions from comparing it.
nonisolated enum AdaptiveListLayout: Equatable {
  /// Compact width (iPhone portrait, most iPad multitasking splits): one full-width row per line,
  /// the ordinary `List` presentation.
  case singleColumn
  /// Regular width (iPad full-screen/most split, Mac): a `columns`-wide grid, so a wide screen
  /// does not strand a single narrow column of rows in the middle.
  case grid(columns: Int)
  /// Podcast episodes are a chronological index rather than a browse shelf. Regular width keeps
  /// their one reading stream and bounds each row to its measured reading width instead of adding
  /// a second column.
  case measuredSingleColumn(maxWidth: CGFloat)

  static func resolve(horizontalSizeClass: UserInterfaceSizeClass?) -> AdaptiveListLayout {
    horizontalSizeClass == .regular ? .grid(columns: 2) : .singleColumn
  }

  /// A measured measure at regular width, single column everywhere else. An unusable measure
  /// falls back to `.singleColumn` rather than zero, so a bad measurement cannot collapse a list.
  static func resolve(
    horizontalSizeClass: UserInterfaceSizeClass?,
    measure: CGFloat
  ) -> AdaptiveListLayout {
    guard horizontalSizeClass == .regular, measure.isFinite, measure > 0 else {
      return .singleColumn
    }
    return .measuredSingleColumn(maxWidth: measure)
  }

  /// Resolves a regular-width list from the width available inside its explicit insets. A nil
  /// measurement gives a two-column first-frame fallback until layout reports a width; a measured
  /// width, including an invalid one, goes through the safe width arithmetic.
  static func resolve(
    horizontalSizeClass: UserInterfaceSizeClass?,
    availableWidth: CGFloat?,
    minimumTileWidth: CGFloat,
    spacing: CGFloat
  ) -> AdaptiveListLayout {
    guard horizontalSizeClass == .regular else { return .singleColumn }
    guard let availableWidth else { return .grid(columns: 2) }
    return .grid(
      columns: columnCount(
        forContentWidth: availableWidth,
        minimumTileWidth: minimumTileWidth,
        spacing: spacing))
  }

  /// Returns the number of minimum-width tiles that fit in a measured content width. Invalid or
  /// non-positive values leave one safe column for the first usable layout pass.
  static func columnCount(
    forContentWidth width: CGFloat,
    minimumTileWidth: CGFloat,
    spacing: CGFloat
  ) -> Int {
    guard isPositiveFinite(width), isPositiveFinite(minimumTileWidth), isPositiveFinite(spacing)
    else { return 1 }

    let numerator = width + spacing
    let denominator = minimumTileWidth + spacing
    guard numerator.isFinite, denominator.isFinite, denominator > 0 else { return 1 }

    let count = floor(numerator / denominator)
    guard count.isFinite, count > 0 else { return 1 }
    // Avoid a trapping floating-point-to-Int conversion for an unusually large finite width.
    guard count < CGFloat(Int.max) else { return Int.max }
    return max(1, Int(count))
  }

  /// Returns one fixed tile width after reserving the gaps between `columns`. The result is rounded
  /// down so the tiles and their gaps cannot exceed the supplied content width.
  static func tileWidth(
    forContentWidth width: CGFloat,
    columns: Int,
    spacing: CGFloat
  ) -> CGFloat {
    guard isPositiveFinite(width), columns > 0, isPositiveFinite(spacing) else { return 0 }

    let columnCount = CGFloat(columns)
    let interColumnSpacing = spacing * CGFloat(columns - 1)
    guard
      columnCount.isFinite,
      interColumnSpacing.isFinite,
      interColumnSpacing >= 0
    else { return 0 }

    let availableWidth = width - interColumnSpacing
    guard availableWidth.isFinite, availableWidth > 0 else { return 0 }

    let tileWidth = floor(availableWidth / columnCount)
    guard tileWidth.isFinite, tileWidth >= 0 else { return 0 }
    return min(width, tileWidth)
  }

  private static func isPositiveFinite(_ value: CGFloat) -> Bool {
    value.isFinite && value > 0
  }
}
