import ABSApi
import Testing
import UIKit

@testable import Whirr

/// `UIImage(data:)` defers the pixel-buffer decode to first draw, so moving only the initializer
/// off the main actor does little. These cover the seam that forces the real decode off main, and
/// the main-actor boundary where the result is assigned to view state.
struct CoverImageDecodingTests {

  // Off-main execution comes from `Task.detached(priority: .utility)` in
  // `UtilityCoverImageDecoder.decodedImage`, a Swift concurrency guarantee a test double could
  // only re-prove, so the valid-image tests below use the production type. The device pass checks
  // decode against the 50 ms hitch threshold.

  @Test("Preparing a valid image produces a distinct, display-ready instance")
  func preparingAValidImageProducesADistinctInstance() {
    // `preparingForDisplay()` returns a distinct, decoded `UIImage` when it succeeds, and falls
    // back to the original instance when it cannot prepare the image. Identity is the
    // discriminator: if `UtilityCoverImageDecoder.prepare` skipped `preparingForDisplay()`,
    // `prepared` would be the same instance as `source` and this would fail.
    let source = UIImage(data: ImageTestFixtures.knownGoodCoverData)!
    let prepared = UtilityCoverImageDecoder.prepare(source)
    #expect(prepared !== source)
  }

  @Test("The decoder returns an image for valid bytes")
  func decoderReturnsAnImageForValidBytes() async {
    let decoder = UtilityCoverImageDecoder()
    let decoded = await decoder.decodedImage(
      from: ImageTestFixtures.knownGoodCoverData, priority: .visible, shortSidePixelLimit: 512)
    #expect(decoded.image != nil)
  }

  @Test("The decoder returns nil, without throwing, for malformed bytes")
  func decoderReturnsNilForMalformedBytes() async {
    let decoder = UtilityCoverImageDecoder()
    let malformed = await decoder.decodedImage(
      from: Data([0x00, 0x01, 0x02, 0x03]), priority: .visible, shortSidePixelLimit: 132)
    guard case .undecodable = malformed else {
      Issue.record("malformed bytes must report .undecodable, not .cancelled")
      return
    }
  }

  /// An abandoned request reports `.cancelled` and leaves the permit pool untouched: a decoder
  /// that swallowed the `CancellationError` or took a permit first would starve the three-permit
  /// pool one scroll at a time. Not `.undecodable`, which promotes a placeholder to generated
  /// art and hides a cover the item has.
  @Test("An already-cancelled request reports cancellation without consuming a decode permit")
  func alreadyCancelledRequestSkipsDecode() async {
    let admission = CoverDecodeAdmission(maximumConcurrent: 1)
    let decoder = UtilityCoverImageDecoder(admission: admission)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await decoder.decodedImage(
        from: ImageTestFixtures.knownGoodCoverData, priority: .scrollPrefetch,
        shortSidePixelLimit: 132)
    }

    guard case .cancelled = await task.value else {
      Issue.record("an abandoned decode must report .cancelled")
      return
    }
    #expect(await admission.inFlightCount == 0)
    #expect(await admission.queuedCount == 0)
  }

  // MARK: - Bounding the bitmap to the variant

  /// ABS resizes covers to the requested width; RSS artwork is whatever the feed published
  /// (Apple asks for 1400 to 3000 px squares), and a 3000 px square at native size costs 36 MB,
  /// more than the whole 28 MiB prepared tier. These pin how the key's variant width bounds it.

  @Test("a source within the limit keeps its native size")
  func sourceWithinTheLimitIsNotDownsampled() {
    #expect(
      UtilityCoverImageDecoder.downsampledMaxPixelSize(
        pixelWidth: 132, pixelHeight: 198, shortSidePixelLimit: 132) == nil)
    #expect(
      UtilityCoverImageDecoder.downsampledMaxPixelSize(
        pixelWidth: 100, pixelHeight: 100, shortSidePixelLimit: 132) == nil)
    #expect(
      UtilityCoverImageDecoder.downsampledMaxPixelSize(
        pixelWidth: 3000, pixelHeight: 3000, shortSidePixelLimit: 0) == nil)
  }

  @Test("the shorter side lands on the limit whatever the source's shape")
  func shorterSideLandsOnTheLimit() {
    // Square: the limit itself.
    #expect(
      UtilityCoverImageDecoder.downsampledMaxPixelSize(
        pixelWidth: 3000, pixelHeight: 3000, shortSidePixelLimit: 132) == 132)
    // Portrait: the width is bounded, as the ABS server bounds a 2:3 cover.
    #expect(
      UtilityCoverImageDecoder.downsampledMaxPixelSize(
        pixelWidth: 2000, pixelHeight: 3000, shortSidePixelLimit: 132) == 198)
    // Landscape: the height is bounded, so the bitmap still fills a square slot.
    #expect(
      UtilityCoverImageDecoder.downsampledMaxPixelSize(
        pixelWidth: 3000, pixelHeight: 1000, shortSidePixelLimit: 132) == 396)
    // Rounded up, never down: the shorter side must not fall below the limit.
    #expect(
      UtilityCoverImageDecoder.downsampledMaxPixelSize(
        pixelWidth: 1000, pixelHeight: 999, shortSidePixelLimit: 132) == 133)
  }

  @Test("an oversized square decodes to the limit on both sides")
  func oversizedSquareDecodesToTheLimit() throws {
    let decoded = try #require(
      UtilityCoverImageDecoder.decode(
        ImageTestFixtures.knownGoodCoverData, shortSidePixelLimit: 132))
    #expect(decoded.cgImage?.width == 132)
    #expect(decoded.cgImage?.height == 132)
  }

  @Test("an oversized portrait keeps its shape with its width on the limit")
  func oversizedPortraitKeepsItsShape() throws {
    let decoded = try #require(
      UtilityCoverImageDecoder.decode(
        ImageTestFixtures.solidPNGData(width: 600, height: 900), shortSidePixelLimit: 132))
    #expect(decoded.cgImage?.width == 132)
    #expect(decoded.cgImage?.height == 198)
  }

  @Test("an oversized landscape keeps its shape with its height on the limit")
  func oversizedLandscapeKeepsItsShape() throws {
    let decoded = try #require(
      UtilityCoverImageDecoder.decode(
        ImageTestFixtures.solidPNGData(width: 900, height: 300), shortSidePixelLimit: 132))
    #expect(decoded.cgImage?.width == 396)
    #expect(decoded.cgImage?.height == 132)
  }

  @Test("a source already at the requested width decodes at its native size")
  func sourceAtTheRequestedWidthIsUntouched() throws {
    let decoded = try #require(
      UtilityCoverImageDecoder.decode(
        ImageTestFixtures.solidPNGData(width: 132, height: 198), shortSidePixelLimit: 132))
    #expect(decoded.cgImage?.width == 132)
    #expect(decoded.cgImage?.height == 198)
    let larger = try #require(
      UtilityCoverImageDecoder.decode(ImageTestFixtures.knownGoodCoverData, shortSidePixelLimit: 1024))
    #expect(larger.cgImage?.width == 512)
    #expect(larger.cgImage?.height == 512)
  }
}
