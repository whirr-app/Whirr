import CoreGraphics
import SwiftUI
import Testing

@testable import DesignSystem

/// Pins the glow behind a drained card's cover. See `CoverGlow`.
@Suite("Cover glow")
struct CoverGlowTests {
  private static let drained = CoverWash.from(
    hue: 0.08, saturation: 0.8, brightness: 0.7)

  @Test("the glow takes the drained mark's colour, and only where the marks take it")
  func tintScope() {
    #expect(
      CoverGlow.tint(colorScheme: .dark, wash: Self.drained, increasedContrast: false)
        == Self.drained.darkAccent)
    #expect(Self.drained.darkAccent != nil)
    #expect(CoverGlow.tint(colorScheme: .light, wash: Self.drained, increasedContrast: false) == nil)
    #expect(CoverGlow.tint(colorScheme: .dark, wash: Self.drained, increasedContrast: true) == nil)
    // The plain neutral wash is not drained.
    #expect(CoverGlow.tint(colorScheme: .dark, wash: .neutral, increasedContrast: false) == nil)
    // A cover with no hue has no colour to glow with.
    #expect(
      CoverGlow.tint(colorScheme: .dark, wash: .drainedNeutral, increasedContrast: false) == nil)
    #expect(CoverGlow.tint(colorScheme: .dark, wash: nil, increasedContrast: false) == nil)
  }

  @Test("the profile is full behind the artwork, half at its edge, and gone three sigma out")
  func profile() {
    let sigma = Double(CoverGlow.sigma)
    let span = 0.0...144.0
    #expect(CoverGlow.profile(72, across: span) > 0.99)
    #expect(abs(CoverGlow.profile(0, across: span) - 0.5) < 0.01)
    #expect(abs(CoverGlow.profile(144, across: span) - 0.5) < 0.01)
    #expect(CoverGlow.profile(-3 * sigma, across: span) < 0.002)
    #expect(CoverGlow.profile(144 + 3 * sigma, across: span) < 0.002)
  }

  @Test("an artwork shape's image frames the artwork with three sigma on every side")
  func imageGeometry() {
    for aspect in [1.0, 2.0 / 3, 1.5] {
      let shape = CoverGlow.ArtworkShape(aspectRatio: aspect)
      let margin = 3 * CoverGlow.sigma
      #expect(abs(max(shape.artwork.width, shape.artwork.height) - 144) < 1e-9)
      #expect(abs(shape.artwork.width / shape.artwork.height - shape.aspectRatio) < 1e-9)
      #expect(abs(shape.canvas.width - shape.artwork.width - 2 * margin) < 1e-9)
      #expect(abs(shape.canvas.height - shape.artwork.height - 2 * margin) < 1e-9)
    }
  }

  @Test("aspect ratios share an image within a bucket, and stay inside a cover's range")
  func buckets() {
    #expect(CoverGlow.ArtworkShape(aspectRatio: 0.667) == CoverGlow.ArtworkShape(aspectRatio: 0.661))
    #expect(CoverGlow.ArtworkShape(aspectRatio: 0.667) != CoverGlow.ArtworkShape(aspectRatio: 0.70))
    #expect(CoverGlow.ArtworkShape(aspectRatio: 0.01) == CoverGlow.ArtworkShape(aspectRatio: 0.4))
    #expect(CoverGlow.ArtworkShape(aspectRatio: 40) == CoverGlow.ArtworkShape(aspectRatio: 2.5))
    #expect(CoverGlow.ArtworkShape(aspectRatio: .nan) == CoverGlow.ArtworkShape(aspectRatio: 1))
  }

  @Test("the image is white, opaque behind the artwork and clear at its corners")
  @MainActor
  func image() throws {
    let images = CoverGlow.Images()
    let image = try #require(images.image(for: CoverGlow.ArtworkShape(aspectRatio: 1)))
    let pixels = try #require(Self.rgba(image))
    let centre = pixels.pixel(image.width / 2, image.height / 2)
    #expect(centre.alpha > 250)
    #expect(centre.red == centre.alpha)
    #expect(pixels.pixel(0, 0).alpha == 0)
    #expect(pixels.pixel(image.width - 1, image.height - 1).alpha == 0)
  }

  @Test("each artwork shape's image is built once and reused")
  @MainActor
  func cache() {
    let images = CoverGlow.Images()
    let first = images.image(for: CoverGlow.ArtworkShape(aspectRatio: 2.0 / 3))
    let again = images.image(for: CoverGlow.ArtworkShape(aspectRatio: 0.665))
    #expect(first != nil)
    #expect(first === again)
    #expect(images.builds == 1)
    _ = images.image(for: CoverGlow.ArtworkShape(aspectRatio: 1))
    #expect(images.builds == 2)
  }

  private struct Pixels {
    let bytes: [UInt8]
    let width: Int
    func pixel(_ x: Int, _ y: Int) -> (red: UInt8, alpha: UInt8) {
      let offset = (y * width + x) * 4
      return (bytes[offset], bytes[offset + 3])
    }
  }

  private static func rgba(_ image: CGImage) -> Pixels? {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    return drawn ? Pixels(bytes: bytes, width: image.width) : nil
  }
}
