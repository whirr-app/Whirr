import CoreGraphics
import Testing

@testable import DesignSystem

/// Covers `GeneratedCoverArtRasterizer`: the bitmap form of the generated paperback cover.
///
/// `GeneratedCoverArtView` is a SwiftUI view, so it only reaches SwiftUI surfaces. Surfaces that
/// need actual pixels, above all `MPNowPlayingInfoCenter`'s lock-screen/Control Center artwork,
/// need this bitmap form so a title with no server-side cover still shows one.
@MainActor
@Suite("Generated cover art rasterizer")
struct GeneratedCoverArtRasterizerTests {

  /// Samples one pixel of a `CGImage` by redrawing it into a known 8-bit sRGB buffer, since the
  /// image's own backing format is SwiftUI's business.
  private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = bytes.withUnsafeMutableBytes { buffer in
      CGContext(
        data: buffer.baseAddress,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
    context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let offset = (y * image.width + x) * 4
    return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
  }

  @Test("rasterizes to an opaque square bitmap of the requested pixel width")
  func rasterizesToRequestedPixelSize() throws {
    let image = try #require(
      GeneratedCoverArtRasterizer.cgImage(title: "The Time Machine", author: "H. G. Wells", pixelWidth: 512))
    #expect(image.width == 512)
    #expect(image.height == 512)
  }

  @Test("the band and the paper panel are actually drawn, not a blank tile")
  func drawsBandAndPanel() throws {
    let image = try #require(
      GeneratedCoverArtRasterizer.cgImage(title: "Walden", author: "Thoreau", pixelWidth: 256))

    // Top band: GeneratedCoverArtView reserves the top 23.5% for the orange band.
    let band = pixel(image, x: 128, y: 12)
    // Paper panel: the cream stock between the two bands. Sampled off-centre horizontally so the
    // serif title glyphs don't land on the sample.
    let paper = pixel(image, x: 8, y: 128)

    // The band is warm orange and the paper bright cream. A blank tile would give the two samples
    // the same value (a transparent one would give both zero).
    #expect(band.r > band.g && band.g > band.b, "band should read warm orange, got \(band)")
    #expect(band.r > 150, "band should be a saturated orange, got \(band)")
    #expect(paper.r > 200 && paper.g > 200 && paper.b > 180, "paper should be bright cream, got \(paper)")
    #expect(paper.b > band.b + 100, "paper and band must not be the same fill, got \(paper) vs \(band)")
  }

  @Test("a missing or blank title has nothing to draw")
  func blankTitleRastersNothing() {
    #expect(GeneratedCoverArtRasterizer.cgImage(title: nil, author: "Thoreau", pixelWidth: 256) == nil)
    #expect(GeneratedCoverArtRasterizer.cgImage(title: "   ", author: "Thoreau", pixelWidth: 256) == nil)
  }

  @Test("a non-positive pixel width has nothing to draw")
  func nonPositiveWidthRastersNothing() {
    #expect(GeneratedCoverArtRasterizer.cgImage(title: "Walden", author: nil, pixelWidth: 0) == nil)
    #expect(GeneratedCoverArtRasterizer.cgImage(title: "Walden", author: nil, pixelWidth: -1) == nil)
  }
}
