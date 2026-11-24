import ABSApi
import Foundation
import SwiftUI
import TestSupport
import Testing
import UIKit

@testable import Whirr

@Suite(.timeLimit(.minutes(1)))
struct ArtworkImagePipelineTests {
  @MainActor
  @Test("selection preflight and destination share one exact fetch and decode")
  func selectionPreflightCoalescesWithDestination() async throws {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let fetcher = RecordingArtworkFetcher()
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let decoder = BlockingArtworkDecoder(image: image)
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: decoder)
    let preflight = LibrarySelectionArtworkPreflight()
    let key = ArtworkKey(
      accountScope: ArtworkAccountScope("https://example.test"),
      itemID: "item-1",
      variant: .highFidelity(pixelWidth: 1024),
      revision: .unversioned)

    preflight.start(key: key) { key in
      _ = await pipeline.image(for: key, priority: .visible, client: fetcher)
    }
    await waitUntil { await decoder.callCount == 1 }
    let destination = Task {
      await pipeline.image(for: key, priority: .visible, client: fetcher)
    }
    // Carries the claim: the destination joined this operation. Decode counts cannot show that,
    // since a destination that has not joined also leaves the count at 1 and then reads the
    // finished image from the cache, so the test would pass with no subscriber sharing the work.
    await waitUntil { await pipeline.subscriberCount(for: key) == 2 }

    #expect(await fetcher.callCount == 1)
    #expect(await decoder.callCount == 1)
    await decoder.release()
    #expect(await destination.value === image)
  }

  @MainActor
  @Test("identical subscribers share one transport and one decode")
  func identicalSubscribersShareOneOperation() async throws {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let fetcher = RecordingArtworkFetcher()
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let decoder = BlockingArtworkDecoder(image: image)
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: decoder)
    let key = ArtworkKey(
      accountScope: ArtworkAccountScope("https://example.test"),
      itemID: "item-1",
      variant: .libraryThumbnail(pixelWidth: 132),
      revision: .unversioned)

    let tasks = (0..<5).map { _ in
      Task { await pipeline.image(for: key, priority: .visible, client: fetcher) }
    }
    // Waiting on the first decode would let this pass without coalescing. It breaks once one
    // subscriber gets that far, and the four that have not started leave the fetch count at 1, as a
    // coalesced run does. Wait for all five to be sharing.
    await waitUntil { await pipeline.subscriberCount(for: key) == 5 }

    #expect(await fetcher.callCount == 1)
    #expect(await decoder.callCount == 1)
    await decoder.release()
    for task in tasks {
      #expect(await task.value === image)
    }
    #expect(cache.image(for: key) === image)
  }

  @MainActor
  @Test("a prepared hit skips compressed, network, and decode work")
  func memoryHitSkipsLowerTiers() async {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let fetcher = RecordingArtworkFetcher()
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let decoder = BlockingArtworkDecoder(image: image)
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: decoder)
    let key = ArtworkKey(
      accountScope: ArtworkAccountScope("https://example.test"),
      itemID: "item-1",
      variant: .libraryThumbnail(pixelWidth: 132),
      revision: .unversioned)
    cache.insert(image, for: key)

    let result = await pipeline.image(for: key, priority: .visible, client: fetcher)

    #expect(result === image)
    #expect(await fetcher.callCount == 0)
    #expect(await decoder.callCount == 0)
  }

  @MainActor
  @Test("a prepared hit returns at once and changed revalidation replaces it")
  func rssPreparedHitServesWarmBytesThenRevalidatesChangedBytes() async throws {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let prepared = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let refreshed = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let decoder = CountingArtworkDecoder(image: refreshed)
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: decoder)
    let source = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:1", artworkURL: URL(string: "https://img.test/show.jpg")!,
        feedURL: URL(string: "https://feed.test/show.xml")!))
    let key = ArtworkKey(
      source: .rss(source), itemID: "rss:1", variant: .libraryThumbnail(pixelWidth: 132),
      revision: .unversioned)
    cache.insert(prepared, for: key)
    let client = RevalidatingArtworkFetcher(
      cachedData: Data([1]), responseData: Data([2]), blocksFetch: true)

    #expect(await pipeline.image(for: key, priority: .visible, client: client) === prepared)
    #expect(await client.fetchCount == 0)
    #expect(await client.refreshCheckCount == 0)

    let first = Task {
      await pipeline.revalidate(for: key, priority: .visible, client: client)
    }
    await waitUntil { await client.fetchCount == 1 }
    let second = Task {
      await pipeline.revalidate(for: key, priority: .visible, client: client)
    }
    await waitUntil { await pipeline.revalidationSubscriberCount(for: key) == 2 }

    #expect(await client.dataReadCount == 1)
    await client.release()
    #expect(await first.value === refreshed)
    #expect(await second.value === refreshed)
    #expect(await client.fetchCount == 1)
    #expect(await client.refreshCheckCount == 1)
    #expect(cache.image(for: key) === refreshed)
    #expect(await decoder.callCount == 1)
  }

  @MainActor
  @Test("unchanged revalidation bytes replace nothing")
  func unchangedRevalidationBytesReplaceNothing() async throws {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let prepared = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let decoded = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let decoder = CountingArtworkDecoder(image: decoded)
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: decoder)
    let source = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:1", artworkURL: URL(string: "https://img.test/show.jpg")!,
        feedURL: URL(string: "https://feed.test/show.xml")!))
    let key = ArtworkKey(
      source: .rss(source), itemID: "rss:1", variant: .libraryThumbnail(pixelWidth: 132),
      revision: .unversioned)
    let bytes = Data([1])
    cache.insert(prepared, for: key)
    let client = RevalidatingArtworkFetcher(cachedData: bytes, responseData: bytes)

    #expect(await pipeline.revalidate(for: key, priority: .visible, client: client) == nil)
    #expect(await client.fetchCount == 1)
    #expect(await client.refreshCheckCount == 1)
    #expect(await client.dataReadCount == 1)
    #expect(await decoder.callCount == 0)
    #expect(cache.image(for: key) === prepared)
  }

  @MainActor
  @Test("pipeline forwards request priority and seeds decode visibly")
  func forwardsDecodePriority() async {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let fetcher = RecordingArtworkFetcher()
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let decoder = RecordingPriorityArtworkDecoder(image: image)
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: decoder)
    let visibleKey = makeSeedKey(variant: .homeCard(pixelWidth: 420))
    let prefetchKey = makeSeedKey(variant: .libraryThumbnail(pixelWidth: 132))
    let seedKey = makeSeedKey(variant: .highFidelity(pixelWidth: 1024))

    #expect(await pipeline.image(for: visibleKey, priority: .visible, client: fetcher) === image)
    #expect(
      await pipeline.image(for: prefetchKey, priority: .scrollPrefetch, client: fetcher) === image)
    let seedReader = FakeArtworkByteReading(responses: [seedKey: Data([1])])
    #expect(
      (await pipeline.seedImage(candidates: [seedKey], byteReader: seedReader))?.image === image)

    #expect(await decoder.priorities == [.visible, .scrollPrefetch, .visible])
  }

  /// The variant's width is the bound the decoder sizes the bitmap to. Each key must carry its own.
  /// A seed candidate decoded to the visible key's width would be inserted under the candidate's
  /// key at the wrong size. A revalidation decoded unbounded would put back the bitmap the first
  /// decode was bounded to avoid.
  @Test("every decode is bounded by its own key's variant width")
  func forwardsVariantWidthToTheDecoder() async {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let decoder = RecordingLimitArtworkDecoder(image: image)
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: decoder)
    let visibleKey = makeSeedKey(variant: .homeCard(pixelWidth: 420))
    let seedKey = makeSeedKey(variant: .libraryThumbnail(pixelWidth: 132))
    let revalidatedKey = makeSeedKey(variant: .highFidelity(pixelWidth: 1024))
    cache.insert(image, for: revalidatedKey)

    _ = await pipeline.image(for: visibleKey, priority: .visible, client: RecordingArtworkFetcher())
    let seedReader = FakeArtworkByteReading(responses: [seedKey: Data([1])])
    _ = await pipeline.seedImage(candidates: [seedKey], byteReader: seedReader)
    let fetcher = RevalidatingArtworkFetcher(cachedData: Data([1]), responseData: Data([2]))
    _ = await pipeline.revalidate(for: revalidatedKey, priority: .visible, client: fetcher)

    #expect(await decoder.limits == [420, 132, 1024])
  }

  /// Scrolling cancels a prefetch batch on every row that appears. An operation whose only
  /// subscriber has gone must stop before the decode, the expensive half. Otherwise the abandoned
  /// work runs to completion and burns CPU long after the scroll ends.
  @MainActor
  @Test("an abandoned operation stops before decoding")
  func cancellingTheSoleSubscriberSkipsTheDecode() async throws {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let fetcher = BlockingArtworkFetcher()
    let decoder = CountingArtworkDecoder(image: image)
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: decoder)
    let key = ArtworkKey(
      accountScope: ArtworkAccountScope("https://example.test"),
      itemID: "item-1",
      variant: .libraryThumbnail(pixelWidth: 132),
      revision: .unversioned)

    let task = Task { await pipeline.image(for: key, priority: .scrollPrefetch, client: fetcher) }
    _ = await awaitCondition(
      "artwork fetch starts before cancellation",
      observing: { "fetches=\(await fetcher.callCount)" },
      until: { await fetcher.callCount > 0 })
    task.cancel()
    _ = await awaitCondition(
      "cancelled artwork subscriber is removed",
      observing: { "subscribers=\(await pipeline.subscriberCount(for: key))" },
      until: { await pipeline.subscriberCount(for: key) == 0 })
    await fetcher.release()

    #expect(await task.value == nil)
    #expect(await decoder.callCount == 0)
    #expect(cache.image(for: key) == nil)
  }

  /// Cancellation is reference counted. One subscriber walking away must not strand the others
  /// still waiting on the same shared key.
  @MainActor
  @Test("one subscriber cancelling leaves the shared operation running for the rest")
  func cancellingOneSubscriberKeepsSharedWorkAlive() async throws {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let fetcher = BlockingArtworkFetcher()
    let decoder = CountingArtworkDecoder(image: image)
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: decoder)
    let key = ArtworkKey(
      accountScope: ArtworkAccountScope("https://example.test"),
      itemID: "item-1",
      variant: .libraryThumbnail(pixelWidth: 132),
      revision: .unversioned)

    let keeper = Task { await pipeline.image(for: key, priority: .visible, client: fetcher) }
    _ = await awaitCondition(
      "shared artwork fetch starts",
      observing: { "fetches=\(await fetcher.callCount)" },
      until: { await fetcher.callCount > 0 })
    let leaver = Task { await pipeline.image(for: key, priority: .visible, client: fetcher) }
    _ = await awaitCondition(
      "both artwork subscribers join",
      observing: { "subscribers=\(await pipeline.subscriberCount(for: key))" },
      until: { await pipeline.subscriberCount(for: key) == 2 })
    leaver.cancel()
    _ = await awaitCondition(
      "one artwork subscriber remains after cancellation",
      observing: { "subscribers=\(await pipeline.subscriberCount(for: key))" },
      until: { await pipeline.subscriberCount(for: key) == 1 })
    await fetcher.release()

    #expect(await keeper.value === image)
    #expect(await fetcher.callCount == 1)
    #expect(await decoder.callCount == 1)
    #expect(cache.image(for: key) === image)
  }

  @MainActor
  @Test("a prepared seed hit skips byte reading and decoding")
  func seedPreparedHitSkipsLowerTiers() async {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let decoder = CountingArtworkDecoder(image: image)
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: decoder)
    let candidate = makeSeedKey(variant: .homeCard(pixelWidth: 420))
    let byteReader = FakeArtworkByteReading(responses: [:])
    cache.insert(image, for: candidate)

    let result = await pipeline.seedImage(candidates: [candidate], byteReader: byteReader)

    #expect(result?.image === image)
    #expect(result?.key == candidate)
    #expect(await byteReader.requestedKeys.isEmpty)
    #expect(await decoder.callCount == 0)
  }

  @MainActor
  @Test("a byte-cache hit decodes once and is inserted under its candidate key")
  func seedByteHitDecodesOnceAndUsesCandidateKey() async {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let decoder = CountingArtworkDecoder(image: image)
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: decoder)
    let candidate = makeSeedKey(variant: .libraryThumbnail(pixelWidth: 420))
    let highFidelityKey = makeSeedKey(variant: .highFidelity(pixelWidth: 1024))
    let byteReader = FakeArtworkByteReading(responses: [candidate: Data([1])])

    let result = await pipeline.seedImage(candidates: [candidate], byteReader: byteReader)

    #expect(result?.image === image)
    #expect(result?.key == candidate)
    #expect(await byteReader.requestedKeys == [candidate])
    #expect(await decoder.callCount == 1)
    #expect(cache.image(for: candidate) === image)
    #expect(cache.image(for: highFidelityKey) == nil)
  }

  @MainActor
  @Test("all seed candidates missing from the byte cache return nil")
  func seedAllMissesReturnNil() async {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let decoder = CountingArtworkDecoder(
      image: UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in })
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: decoder)
    let candidates = [
      makeSeedKey(variant: .homeCard(pixelWidth: 420)),
      makeSeedKey(variant: .libraryThumbnail(pixelWidth: 132)),
    ]
    let byteReader = FakeArtworkByteReading(responses: [:])

    let result = await pipeline.seedImage(candidates: candidates, byteReader: byteReader)

    #expect(result == nil)
    #expect(await byteReader.requestedKeys == candidates)
    #expect(await decoder.callCount == 0)
  }

  @MainActor
  @Test("a first-candidate hit never probes a later candidate")
  func seedFirstHitStopsBeforeTheSecondProbe() async {
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }
    let decoder = CountingArtworkDecoder(image: image)
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: decoder)
    let first = makeSeedKey(variant: .homeCard(pixelWidth: 420))
    let second = makeSeedKey(variant: .libraryThumbnail(pixelWidth: 132))
    let byteReader = FakeArtworkByteReading(
      responses: [first: Data([1]), second: Data([2])])

    let result = await pipeline.seedImage(
      candidates: [first, second], byteReader: byteReader)

    #expect(result?.image === image)
    #expect(result?.key == first)
    #expect(await byteReader.requestedKeys == [first])
    #expect(await decoder.callCount == 1)
  }
}

/// The placeholder promotes itself to generated art on `.unavailable`, and only on `.unavailable`.
/// How a failed attempt is classified therefore decides whether an offline listener sees their
/// cached cover or a generated one the item does not have.
@Suite(.timeLimit(.minutes(1)))
struct ArtworkFetchOutcomeTests {
  @MainActor
  @Test("a transport failure is not evidence that the item has no artwork")
  func transportFailureIsNotUnavailable() async {
    let outcome = await outcome(throwing: URLError(.notConnectedToInternet))

    guard case .failed = outcome else {
      Issue.record("offline must not resolve to .unavailable")
      return
    }
  }

  @MainActor
  @Test("a server 404 is the one ending that proves the item has no artwork")
  func notFoundIsUnavailable() async {
    let outcome = await outcome(throwing: APIError.notFound)

    guard case .unavailable = outcome else {
      Issue.record("a 404 must resolve to .unavailable")
      return
    }
  }

  @MainActor
  @Test("a server-side failure leaves the item's artwork an open question")
  func serverFailureIsNotUnavailable() async {
    let outcome = await outcome(throwing: APIError.serverFailure(statusCode: 503))

    guard case .failed = outcome else {
      Issue.record("a 5xx must not resolve to .unavailable")
      return
    }
  }

  @MainActor
  @Test("bytes that arrived but will not decode are as good as no artwork")
  func undecodableBytesAreUnavailable() async {
    let pipeline = ArtworkImagePipeline(
      cache: PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10),
      decoder: FailingArtworkDecoder())

    let outcome = await pipeline.outcome(
      for: makeSeedKey(variant: .libraryThumbnail(pixelWidth: 132)),
      priority: .visible,
      client: RecordingArtworkFetcher())

    guard case .unavailable = outcome else {
      Issue.record("an undecodable response must resolve to .unavailable")
      return
    }
  }

  /// An abandoned decode says nothing about the item. Classifying it as `.unavailable` would put a
  /// generated cover upstream of a verdict the surface then has to expire. The decoder reports
  /// cancellation separately from unreadable bytes, so `release(key:token:cancelling:)` cannot
  /// reach this branch by changing underneath it.
  @MainActor
  @Test("a cancelled decode is not evidence that the item has no artwork")
  func cancelledDecodeIsNotUnavailable() async {
    let pipeline = ArtworkImagePipeline(
      cache: PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10),
      decoder: CancellingArtworkDecoder())

    let outcome = await pipeline.outcome(
      for: makeSeedKey(variant: .libraryThumbnail(pixelWidth: 132)),
      priority: .visible,
      client: RecordingArtworkFetcher())

    guard case .failed = outcome else {
      Issue.record("a cancelled decode must not resolve to .unavailable")
      return
    }
  }

  /// The mini-player blink for a followed show, reduced to its mechanism. ABS covers arrive resized
  /// to the variant's width and stay prepared across every re-host of the bottom accessory. RSS
  /// artwork arrives at native size: a 3000 px square decodes to 36 MB, more than the whole 28 MiB
  /// prepared tier, so it is evicted on insert and every fresh `CoverImageView` starts from the
  /// placeholder. The decoded bitmap must be bounded by the key's variant, not by the bytes.
  @Test("an oversized source decodes to its variant's size so the prepared tier can retain it")
  func oversizedSourceDecodesToVariantSize() async throws {
    // A 1000 px square decodes to 4 MB at native size, four times this tier's whole budget.
    let cache = PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10)
    let pipeline = ArtworkImagePipeline(cache: cache, decoder: UtilityCoverImageDecoder())
    let fetcher = FixedBytesArtworkFetcher(
      data: ImageTestFixtures.solidPNGData(width: 1000, height: 1000), contentType: "image/png")
    let key = makeSeedKey(variant: .libraryThumbnail(pixelWidth: 132))

    let outcome = await pipeline.outcome(for: key, priority: .visible, client: fetcher)

    let image = try #require(outcome.image)
    #expect(image.cgImage?.width == 132)
    #expect(image.cgImage?.height == 132)
    #expect(cache.image(for: key) === image)
  }

  @MainActor
  private func outcome(throwing error: any Error) async -> ArtworkFetchOutcome {
    let pipeline = ArtworkImagePipeline(
      cache: PreparedArtworkCache(totalCostLimit: 1_000_000, countLimit: 10),
      decoder: CountingArtworkDecoder(
        image: UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { _ in }))

    return await pipeline.outcome(
      for: makeSeedKey(variant: .libraryThumbnail(pixelWidth: 132)),
      priority: .visible,
      client: ThrowingArtworkFetcher(error: error))
  }
}

@Suite("Cover image motion")
struct CoverImageMotionTests {
  @Test("a prepared-memory hit is final on its first frame and never crossfades")
  func preparedHitNeverAnimates() {
    #expect(
      CoverImageView.completionAnimation(
        isPreparedHit: true, isPromptCompletion: false, reduceMotion: false) == nil)
  }

  @Test("a cold completion crossfades unless Reduce Motion is enabled")
  func coldCompletionRespectsReduceMotion() {
    #expect(
      CoverImageView.completionAnimation(
        isPreparedHit: false, isPromptCompletion: false, reduceMotion: true) == nil)
    #expect(
      CoverImageView.completionAnimation(
        isPreparedHit: false, isPromptCompletion: false, reduceMotion: false)
        == .easeInOut(duration: 0.2))
  }

  @Test("a completion inside the prompt window lands without a crossfade")
  func promptCompletionNeverAnimates() {
    #expect(
      CoverImageView.completionAnimation(
        isPreparedHit: false, isPromptCompletion: true, reduceMotion: false) == nil)
  }

  @Test("only a completion inside the window counts as prompt")
  func promptWindowBoundary() {
    #expect(CoverImageView.isPromptCompletion(elapsed: .zero))
    #expect(CoverImageView.isPromptCompletion(elapsed: CoverImageView.promptCompletionWindow))
    #expect(
      CoverImageView.isPromptCompletion(
        elapsed: CoverImageView.promptCompletionWindow + .milliseconds(1)) == false)
  }
}

private actor RecordingArtworkFetcher: ArtworkDataFetching {
  private(set) var callCount = 0

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    callCount += 1
    return CoverImageResult(data: Data([1]), contentType: "image/webp")
  }
}

private struct FixedBytesArtworkFetcher: ArtworkDataFetching {
  let data: Data
  let contentType: String

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    CoverImageResult(data: data, contentType: contentType)
  }
}

private actor RevalidatingArtworkFetcher: ArtworkServing {
  nonisolated let defaultSource: ArtworkSource? = nil
  private let cachedData: Data?
  private let responseData: Data
  private let blocksFetch: Bool
  private(set) var fetchCount = 0
  private(set) var dataReadCount = 0
  private(set) var refreshCheckCount = 0
  private var continuation: CheckedContinuation<Void, Never>?

  init(cachedData: Data?, responseData: Data, blocksFetch: Bool = false) {
    self.cachedData = cachedData
    self.responseData = responseData
    self.blocksFetch = blocksFetch
  }

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    fetchCount += 1
    if blocksFetch {
      await withCheckedContinuation { continuation = $0 }
    }
    return CoverImageResult(data: responseData, contentType: "image/webp")
  }

  func data(for key: ArtworkKey) async -> Data? {
    dataReadCount += 1
    return cachedData
  }

  func needsRefresh(_ key: ArtworkKey) async -> Bool {
    refreshCheckCount += 1
    return true
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

/// Holds the transport open until released. A test can cancel a subscriber while the operation is
/// parked mid-fetch, which is the state a scroll cancellation actually interrupts.
private actor BlockingArtworkFetcher: ArtworkDataFetching {
  private(set) var callCount = 0
  private var continuation: CheckedContinuation<Void, Never>?

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    callCount += 1
    await withCheckedContinuation { continuation = $0 }
    return CoverImageResult(data: Data([1]), contentType: "image/webp")
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private struct ThrowingArtworkFetcher: ArtworkDataFetching {
  let error: any Error

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    throw error
  }
}

private struct FailingArtworkDecoder: CoverImageDecoding {
  func decodedImage(from data: Data, priority: ArtworkPriority, shortSidePixelLimit: Int) async
    -> CoverDecodeOutcome
  {
    .undecodable
  }
}

/// Reports the ending an abandoned decode produces, without needing a real cancelled task to drive
/// `CoverDecodeAdmission` into throwing.
private struct CancellingArtworkDecoder: CoverImageDecoding {
  func decodedImage(from data: Data, priority: ArtworkPriority, shortSidePixelLimit: Int) async
    -> CoverDecodeOutcome
  {
    .cancelled
  }
}

private actor CountingArtworkDecoder: CoverImageDecoding {
  private(set) var callCount = 0
  private let image: UIImage

  init(image: UIImage) {
    self.image = image
  }

  func decodedImage(from data: Data, priority: ArtworkPriority, shortSidePixelLimit: Int) async
    -> CoverDecodeOutcome
  {
    callCount += 1
    return .image(image)
  }
}

private actor RecordingPriorityArtworkDecoder: CoverImageDecoding {
  private let image: UIImage
  private(set) var priorities: [ArtworkPriority] = []

  init(image: UIImage) {
    self.image = image
  }

  func decodedImage(from data: Data, priority: ArtworkPriority, shortSidePixelLimit: Int) async
    -> CoverDecodeOutcome
  {
    priorities.append(priority)
    return .image(image)
  }
}

private actor RecordingLimitArtworkDecoder: CoverImageDecoding {
  private let image: UIImage
  private(set) var limits: [Int] = []

  init(image: UIImage) {
    self.image = image
  }

  func decodedImage(from data: Data, priority: ArtworkPriority, shortSidePixelLimit: Int) async
    -> CoverDecodeOutcome
  {
    limits.append(shortSidePixelLimit)
    return .image(image)
  }
}

private actor BlockingArtworkDecoder: CoverImageDecoding {
  private(set) var callCount = 0
  private let image: UIImage
  private var continuation: CheckedContinuation<Void, Never>?

  init(image: UIImage) {
    self.image = image
  }

  func decodedImage(from data: Data, priority: ArtworkPriority, shortSidePixelLimit: Int) async
    -> CoverDecodeOutcome
  {
    callCount += 1
    await withCheckedContinuation { continuation = $0 }
    return .image(image)
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private actor FakeArtworkByteReading: ArtworkByteReading {
  private let responses: [ArtworkKey: Data]
  private(set) var requestedKeys: [ArtworkKey] = []

  init(responses: [ArtworkKey: Data]) {
    self.responses = responses
  }

  func data(for key: ArtworkKey) async -> Data? {
    requestedKeys.append(key)
    return responses[key]
  }
}

private func makeSeedKey(variant: ArtworkVariant) -> ArtworkKey {
  ArtworkKey(
    accountScope: ArtworkAccountScope("https://example.test"),
    itemID: "item-1",
    variant: variant,
    revision: .unversioned)
}

@Suite(.timeLimit(.minutes(1)))
struct ArtworkScrollActivityTests {
  @MainActor
  @Test("a cover revalidates only once every scroll surface is at rest")
  func aggregatesAcrossSources() {
    let activity = ArtworkScrollActivity()
    #expect(activity.isScrolling == false)

    activity.setScrolling(true, source: "libraryBrowse")
    activity.setScrolling(true, source: "homeWash")
    #expect(activity.isScrolling)

    // One surface settling is not the question. A cover on the still-moving surface would pay its
    // conditional fetch on the scroll path again.
    activity.setScrolling(false, source: "libraryBrowse")
    #expect(activity.isScrolling)

    activity.setScrolling(false, source: "homeWash")
    #expect(activity.isScrolling == false)
  }

  @MainActor
  @Test("repeated phase callbacks for one surface do not accumulate")
  func repeatedCallbacksAreIdempotent() {
    let activity = ArtworkScrollActivity()
    for _ in 0..<5 { activity.setScrolling(true, source: "libraryBrowse") }
    activity.setScrolling(false, source: "libraryBrowse")
    #expect(activity.isScrolling == false)
  }

  @MainActor
  @Test("retiring releases a surface that never delivered an idle phase")
  func retireReleasesEverySource() {
    let activity = ArtworkScrollActivity()
    activity.setScrolling(true, source: "libraryBrowse")
    activity.setScrolling(true, source: "homeWash")

    activity.retireAllScrollSources()

    #expect(activity.isScrolling == false)
  }
}
