import CoreGraphics
import SwiftUI

/// Draws `GeneratedCoverArtView` into a bitmap for surfaces that need pixels, such as
/// `MPNowPlayingInfoCenter`, so an item with no server-side cover shows its paperback placeholder
/// on the lock screen and Control Center too.
///
/// Renders at scale 1 with a point size equal to the pixel width. Every metric in
/// `GeneratedCoverArtView` is proportional to its width, so the layout is identical at any size.
@MainActor
public enum GeneratedCoverArtRasterizer {

  /// Nil whenever there is nothing to draw. Uses the same condition as `CoverPlaceholder` for
  /// generated art versus a blank tile, so both surfaces agree on which items get generated art.
  public static func cgImage(title: String?, author: String?, pixelWidth: Int) -> CGImage? {
    guard let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      return nil
    }
    return cgImage(for: GeneratedCoverArt(title: title, author: author), pixelWidth: pixelWidth)
  }

  public static func cgImage(for art: GeneratedCoverArt, pixelWidth: Int) -> CGImage? {
    guard pixelWidth > 0 else { return nil }
    let side = CGFloat(pixelWidth)
    let renderer = ImageRenderer(
      content: GeneratedCoverArtView(art: art).frame(width: side, height: side))
    renderer.scale = 1
    renderer.isOpaque = true
    return renderer.cgImage
  }
}
