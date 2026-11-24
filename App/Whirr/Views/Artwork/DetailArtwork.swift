import ABSApi
import Foundation
import ImageIO

/// The one place the item-detail cover's cache key is decided.
///
/// The hero, menu preview, tap-time preflight and bulk cover pass must ask for the same key, or
/// the pass warms a file no screen reads: the width fitted to the measured shape once the pass has
/// stored those bytes, the shared high-fidelity width until then (`DetailArtworkSizing`).
nonisolated enum DetailArtwork {
  /// Every measured shape, filled from the `coverShape` table when the bulk pass first runs and
  /// updated as it measures. Process-wide, like `PreparedArtworkCache.shared`, because a view
  /// building a key has no composition root to ask.
  static let shapes = CoverShapeIndex()

  /// The hero's frame side and the context-menu preview's longest edge, in points.
  static let heroSide: Double = 300
  static let previewEdge: Double = 220

  static func sizing(displayScale: Double) -> DetailArtworkSizing {
    DetailArtworkSizing(
      fallbackDisplaySize: Double(ItemDetailView.coverDisplaySize),
      heroSide: heroSide, previewEdge: previewEdge, displayScale: displayScale)
  }

  static func variant(
    itemID: String, revision: ArtworkRevision, displayScale: Double
  ) -> ArtworkVariant {
    sizing(displayScale: displayScale)
      .variant(for: shapes.shape(itemID: itemID, revision: revision))
  }

  /// An image's pixel dimensions from its header, without decoding it.
  static let pixelSize: @Sendable (Data) -> (width: Int, height: Int)? = { data in
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
  }
}
