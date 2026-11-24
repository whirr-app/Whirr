import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import SwiftUI

/// Layout values for the destination's cover grid, and the arithmetic that turns a measured card
/// width into a column count and an exact tile width.
///
/// Sized, not adaptive: `CoverImageView` declares no size, so an `.aspectRatio` frame with no
/// resolved height falls back to the decoded image's dimensions (a portrait cover at full tile
/// width, a square one at a fraction).
///
/// The request rung stays the 140-point `.homeCard` variant shared with Home; tiles draw wider
/// with a mild upscale rather than fetching a second variant. The accessibility minimum keeps a
/// phone at one readable column.
enum AuthorSeriesGridMetrics {
  static let coverDisplaySize: CGFloat = 140
  /// Two columns on every phone width: three columns of roughly 107 points are too narrow for the
  /// title, sequence, badges and duration, and the sequence wraps one character per line. This is
  /// the minimum width of the cover tile itself, before any editorial-card padding.
  static let coverTileMinimumWidth: CGFloat = 140
  /// This is the accessibility minimum width of the cover tile itself, before card padding.
  static let accessibilityCoverTileMinimumWidth: CGFloat = 200
  static let gridSpacing: CGFloat = WhirrSpacing.small
  static let coverCornerRadius: CGFloat = WhirrSpacing.xSmall

  /// How many cover tiles fit across `width`, never fewer than one: a width narrower than a single
  /// cover tile minimum still has to draw its content rather than collapse.
  static func columnCount(forContentWidth width: CGFloat, minimumTileWidth: CGFloat) -> Int {
    AdaptiveListLayout.columnCount(
      forContentWidth: width,
      minimumTileWidth: minimumTileWidth,
      spacing: gridSpacing)
  }

  /// The exact width of one tile. Rounded down so the columns plus their gaps can never total more
  /// than the card's inner width and push the last column out of the card.
  static func tileWidth(forContentWidth width: CGFloat, columns: Int) -> CGFloat {
    guard width.isFinite, width > 0, columns > 0 else { return coverTileMinimumWidth }
    // A tile never collapses: more columns than the width can seat is a caller error, not a reason
    // to hand back a zero-width frame.
    return max(
      1,
      AdaptiveListLayout.tileWidth(
        forContentWidth: width,
        columns: columns,
        spacing: gridSpacing))
  }

  /// The box every tile's artwork in one grid is drawn into, whatever shape that artwork is. The
  /// grid chooses the shape once, from what it holds (see `AuthorSeriesCoverShape`).
  static func coverHeight(forTileWidth width: CGFloat, shape: AuthorSeriesCoverShape) -> CGFloat {
    (width / shape.aspectRatio).rounded()
  }

  /// The column width a run of self-carded tiles needs. A loose book carries its own card, so its
  /// column has to hold that card's padding on top of the width the tile inside it needs: choosing
  /// columns by the bare tile minimum would size them to the card and then draw the tile 24 points
  /// narrower than the minimum that chose them.
  static func columnMinimumWidth(forTileMinimumWidth width: CGFloat) -> CGFloat {
    width + 2 * EditorialCardSurfaceModifier.contentPadding
  }

  /// The tile drawn inside one of those columns: the column less the card's own padding.
  static func tileWidth(insideColumnWidth width: CGFloat) -> CGFloat {
    max(1, width - 2 * EditorialCardSurfaceModifier.contentPadding)
  }
}
