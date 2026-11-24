import ABSApi
import Testing
import UIKit

@testable import Whirr

struct PreparedArtworkCacheTests {
  @Test("a prepared image is returned synchronously without loading or decoding")
  func preparedHitReturnsBeforeAnyAsyncDataLoad() {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let key = makeKey()
    let image = makeImage()

    cache.insert(image, for: key)

    #expect(cache.image(for: key) === image)
  }

  @Test("variants and revisions are separate prepared entries")
  func cacheSeparatesVariantsAndRevisions() {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let thumbnail = makeKey()
    let home = ArtworkKey(
      accountScope: thumbnail.accountScope,
      itemID: thumbnail.itemID,
      variant: .homeCard(pixelWidth: 420),
      revision: thumbnail.revision)
    let revised = ArtworkKey(
      accountScope: thumbnail.accountScope,
      itemID: thumbnail.itemID,
      variant: thumbnail.variant,
      revision: ArtworkRevision("2"))

    cache.insert(makeImage(), for: thumbnail)

    #expect(cache.image(for: thumbnail) != nil)
    #expect(cache.image(for: home) == nil)
    #expect(cache.image(for: revised) == nil)
  }

  @Test("the first prepared variant is available synchronously for immediate reuse")
  func firstPreparedVariantIsAvailableSynchronously() throws {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let exact = makeKey()
    let firstCandidate = ArtworkKey(
      accountScope: exact.accountScope,
      itemID: exact.itemID,
      variant: .homeCard(pixelWidth: 420),
      revision: exact.revision)
    let secondCandidate = ArtworkKey(
      accountScope: exact.accountScope,
      itemID: exact.itemID,
      variant: .highFidelity(pixelWidth: 1024),
      revision: exact.revision)
    let expected = makeImage(width: 20, height: 20)
    cache.insert(expected, for: secondCandidate)

    let hit = try #require(cache.firstImage(for: [exact, firstCandidate, secondCandidate]))

    #expect(hit.key == secondCandidate)
    #expect(hit.image === expected)
  }

  @Test("decoded allocation uses bytes-per-row multiplied by height")
  func cacheCostUsesDecodedAllocation() {
    let image = makeImage(width: 11, height: 17)
    let cgImage = image.cgImage!

    #expect(PreparedArtworkCache.cost(of: image) == cgImage.bytesPerRow * cgImage.height)
  }

  @Test("an explicit purge silently degrades to a miss")
  func explicitPurgeDegradesToAMiss() {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let key = makeKey()
    cache.insert(makeImage(), for: key)

    cache.removeAll()

    #expect(cache.image(for: key) == nil)
  }

  private func makeKey() -> ArtworkKey {
    ArtworkKey(
      accountScope: ArtworkAccountScope("https://example.test"),
      itemID: "item-1",
      variant: .libraryThumbnail(pixelWidth: 132),
      revision: ArtworkRevision("1"))
  }

  private func makeImage(width: Int = 10, height: Int = 10) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
    return renderer.image { context in
      UIColor.red.setFill()
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
  }
}
