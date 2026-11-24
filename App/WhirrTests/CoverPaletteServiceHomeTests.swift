import ABSApi
import DesignSystem
import Foundation
import Persistence
import TestSupport
import Testing

@testable import Whirr

@Suite("Cover palette service for Home cards")
@MainActor
struct CoverPaletteServiceHomeTests {
  @Test("cached washes use one record store batch read")
  func cachedWashesUseOneRecordStoreBatchRead() async {
    let fixtures = EditorialWashTestFixtures()
    let warmItemID = "warm-batch"
    let staleItemID = "stale-batch"
    await fixtures.records.seed(fixtures.warmRecord(for: warmItemID))
    await fixtures.records.seed(
      CoverPaletteRecord(
        itemId: staleItemID, artworkKey: "wrong-artwork-key", accentHue: 0.2,
        accentSaturation: 0.4, accentBrightness: 0.6,
        averageRed: 0.2, averageGreen: 0.3, averageBlue: 0.4, extractedAt: Date()))

    let result = await fixtures.service().cachedWashes(
      itemIDs: [warmItemID, staleItemID, "missing-batch"], revisionsByID: [:])

    #expect(result[warmItemID] != nil)
    #expect(result[staleItemID] == nil)
    #expect(result["missing-batch"] == nil)
    #expect(await fixtures.records.batchFetchCount == 1)
    #expect(await fixtures.records.singleFetchCount == 0)
  }

  @Test("a derived wash persists the page evidence the detail palette accepts")
  func aDerivedWashPersistsThePageEvidenceTheDetailPaletteAccepts() async throws {
    let fixtures = EditorialWashTestFixtures()

    let result = await fixtures.service().resolveWashes(
      itemIDs: [fixtures.itemID], displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale, artworkRole: .homeCard, revisionsByID: [:])

    #expect(result[fixtures.itemID] != nil)
    let record = try #require(await fixtures.records.record(for: fixtures.itemID))
    #expect(record.artworkKey == fixtures.canonicalKey)
    #expect(record.carriesPageEvidence)

    // The detail screen opens on that row alone: no bytes and no second extraction.
    let detailExtractions = EditorialWashTestCallCounter()
    let paletteService = CoverPaletteService(
      extraction: .init(samples: { _ in
        await detailExtractions.increment()
        return nil
      }),
      recordStore: fixtures.records)
    await paletteService.show(
      CoverPaletteIdentity(
        accountScope: fixtures.accountScope, itemID: fixtures.itemID, revision: .unversioned),
      bytes: .init(cached: { nil }, awaitArrival: {}))
    #expect(paletteService.palette(forItem: fixtures.itemID) != nil)
    #expect(await detailExtractions.value == 0)
  }

  /// The admission is shared with the player in production, so a screenful of bulk cards must not
  /// sit ahead of the player's extraction in its queue.
  @Test("a bulk card's extraction queues behind a visible extraction on the shared admission")
  func bulkExtractionQueuesBehindVisibleWork() async throws {
    let fixtures = EditorialWashTestFixtures()
    let admission = CoverDecodeAdmission(maximumConcurrent: 1)
    try await admission.acquire(priority: .visible)
    let service = CoverPaletteService(
      accountScope: fixtures.accountScope, artwork: .init(reader: fixtures.bytes, joiner: fixtures.pipeline),
      extraction: fixtures.extraction, admission: admission, recordStore: fixtures.records)

    let bulk = Task {
      await service.resolveWashes(
        itemIDs: [fixtures.itemID], displaySize: HomeView.cardCoverSize,
        displayScale: EditorialWashTestFixtures.cardScale,
        artworkRole: .homeCard, intent: .bulk, revisionsByID: [:])
    }
    _ = await awaitCondition("bulk queued", until: { await admission.queuedCount == 1 })
    let visible = Task {
      try await admission.acquire(priority: .visible)
      let extractionsBefore = await fixtures.extractionCalls.value
      await admission.release(priority: .visible)
      return extractionsBefore
    }
    _ = await awaitCondition("visible queued", until: { await admission.queuedCount == 2 })
    await admission.release(priority: .visible)

    #expect(try await visible.value == 0)
    #expect((await bulk.value)[fixtures.itemID] != nil)
    #expect(await fixtures.extractionCalls.value == 1)
  }

  @Test("suspension starts no queued extraction")
  func suspensionStartsNoQueuedExtraction() async {
    let fixtures = EditorialWashTestFixtures(gatedExtraction: true)
    let service = fixtures.service()
    service.setCovered(true)

    let request = Task {
      await service.resolveWashes(
        itemIDs: [fixtures.itemID], displaySize: HomeView.cardCoverSize,
        displayScale: EditorialWashTestFixtures.cardScale,
        artworkRole: .homeCard, intent: .bulk, revisionsByID: [:])
    }
    await service.waitForSubscriberCount(
      service.cardIdentity(itemID: fixtures.itemID, revision: .unversioned, source: nil), minimum: 1)

    #expect(await fixtures.extractionCalls.value == 0)

    service.setCovered(false)
    await fixtures.extractionGate!.waitUntilStarted()
    await fixtures.extractionGate!.release()
    _ = await request.value
  }

  @Test("suspension defers completed batch publication")
  func suspensionDefersCompletedBatchPublication() async {
    let fixtures = EditorialWashTestFixtures(gatedExtraction: true)
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)
    let batch = Task { await observer.nextBatch() }

    provider.request(washesFor: [fixtures.itemID], intent: .bulk)
    await fixtures.extractionGate!.waitUntilStarted()
    provider.service.setCovered(true)
    await fixtures.extractionGate!.release()
    await fixtures.extractionGate!.waitUntilCompleted()

    #expect(observer.count == 0)

    provider.service.setCovered(false)
    _ = await batch.value
    #expect(observer.count == 1)
  }

  @Test("suspension defers record-hit publication")
  func suspensionDefersRecordHitPublication() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.records.seed(
      CoverPaletteRecord(
        itemId: fixtures.itemID, artworkKey: fixtures.canonicalKey,
        accentHue: 0.1, accentSaturation: 0.5, accentBrightness: 0.5,
        averageRed: 0.2, averageGreen: 0.3, averageBlue: 0.4, extractedAt: Date()))
    await fixtures.records.holdNextFetch()

    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)
    let batch = Task { await observer.nextBatch() }

    provider.request(washesFor: [fixtures.itemID], intent: .bulk)
    await fixtures.records.waitUntilFetchStarted()
    provider.service.setCovered(true)
    await fixtures.records.releaseFetch()
    await fixtures.records.waitUntilFetchReturned()

    #expect(observer.count == 0)

    provider.service.setCovered(false)
    _ = await batch.value
    #expect(observer.count == 1)
  }

  @Test("resume continues still relevant requests")
  func resumeContinuesStillRelevantRequests() async {
    let fixtures = EditorialWashTestFixtures(gatedExtraction: true)
    let service = fixtures.service()
    service.setCovered(true)

    let request = Task {
      await service.resolveWashes(
        itemIDs: [fixtures.itemID], displaySize: HomeView.cardCoverSize,
        displayScale: EditorialWashTestFixtures.cardScale,
        artworkRole: .homeCard, intent: .bulk, revisionsByID: [:])
    }
    await service.waitForSubscriberCount(
      service.cardIdentity(itemID: fixtures.itemID, revision: .unversioned, source: nil), minimum: 1)
    #expect(await fixtures.extractionCalls.value == 0)

    service.setCovered(false)
    await fixtures.extractionGate!.waitUntilStarted()
    await fixtures.extractionGate!.release()

    #expect((await request.value)[fixtures.itemID] != nil)
    #expect(await fixtures.extractionCalls.value == 1)
  }

  @Test("a suspended visible request resolves from cache or neutral without blocking")
  func suspendedVisibleRequestStillResolvesFromCacheOrNeutralWithoutBlocking() async {
    let fixtures = EditorialWashTestFixtures()
    let service = fixtures.service()
    service.setCovered(true)

    let cached = Task {
      await service.resolveWashes(
        itemIDs: [fixtures.itemID], displaySize: HomeView.cardCoverSize,
        displayScale: EditorialWashTestFixtures.cardScale,
        artworkRole: .homeCard, intent: .visible, revisionsByID: [:])
    }
    #expect((await cached.value)[fixtures.itemID] == nil)
    #expect(await fixtures.extractionCalls.value == 0)
    #expect(await fixtures.pipeline.joinCalls == 0)

    await fixtures.records.seed(
      CoverPaletteRecord(
        itemId: fixtures.itemID, artworkKey: fixtures.canonicalKey,
        accentHue: 0.1, accentSaturation: 0.5, accentBrightness: 0.5,
        averageRed: 0.2, averageGreen: 0.3, averageBlue: 0.4, extractedAt: Date()))
    let recordHit = await service.resolveWashes(
      itemIDs: [fixtures.itemID], displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      artworkRole: .homeCard, intent: .visible, revisionsByID: [:])

    #expect(recordHit[fixtures.itemID] != nil)
    #expect(await fixtures.extractionCalls.value == 0)
    #expect(await fixtures.pipeline.joinCalls == 0)
  }

  @Test("provider teardown cancels its service subscriber")
  func providerTeardownCancelsItsServiceSubscriber() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.bytes.clearDefault()
    let pipeline = EditorialWashSubscriberPipeline(bytes: fixtures.bytes)
    let service = CoverPaletteService(
      accountScope: fixtures.accountScope, artwork: .init(reader: fixtures.bytes, joiner: pipeline),
      extraction: fixtures.extraction, recordStore: fixtures.records)
    var provider: HomeWashProvider? = HomeWashProvider(
      service: service, displaySize: HomeView.cardCoverSize, displayScale: EditorialWashTestFixtures.cardScale)

    provider?.request(washesFor: [fixtures.itemID], intent: .visible)
    await pipeline.waitUntilJoined()
    provider = nil

    await pipeline.waitUntilCancelled()
    #expect(await pipeline.cancelledCalls == 1)
  }

  @Test("cancelling one subscriber keeps the shared task alive for the other")
  func cancellingOneSubscriberKeepsTheSharedTaskAliveForTheOther() async {
    let accountScope = ArtworkAccountScope("test-account")
    let records = EditorialWashTestRecordStore()
    let bytes = EditorialWashTestBytes()
    let pipeline = EditorialWashSubscriberPipeline(bytes: bytes)
    let extraction = CoverPaletteService.Extraction(samples: { _ in
      EditorialWashTestSamples.value
    })
    let service = CoverPaletteService(
      accountScope: accountScope, artwork: .init(reader: bytes, joiner: pipeline),
      extraction: extraction, recordStore: records)

    let first = Task {
      await service.resolveWashes(
        itemIDs: ["show-1"], displaySize: HomeView.cardCoverSize, displayScale: EditorialWashTestFixtures.cardScale,
        artworkRole: .homeCard, intent: .visible, revisionsByID: [:])
    }
    await pipeline.waitUntilJoined()
    let second = Task {
      await service.resolveWashes(
        itemIDs: ["show-1"], displaySize: 120, displayScale: 2,
        artworkRole: .libraryThumbnail, intent: .visible, revisionsByID: [:])
    }
    await service.waitForSubscriberCount(
      service.cardIdentity(itemID: "show-1", revision: .unversioned, source: nil), minimum: 2)

    first.cancel()
    await pipeline.releaseArrival()
    let result = await second.value

    #expect(result["show-1"] != nil)
    #expect(await pipeline.joinCalls == 1)
    #expect(await pipeline.cancelledCalls == 0)
  }

}

actor EditorialWashSubscriberPipeline: CoverPaletteArtworkJoining {
  let bytes: EditorialWashTestBytes
  private(set) var joinCalls = 0
  private(set) var cancelledCalls = 0
  private var joined: CheckedContinuation<Void, Never>?
  private var arrival: CheckedContinuation<Void, Never>?
  private var cancellationWaiter: CheckedContinuation<Void, Never>?
  private var arrivalReleased = false

  init(bytes: EditorialWashTestBytes) {
    self.bytes = bytes
  }

  func awaitArrival(for key: ArtworkKey) async {
    joinCalls += 1
    joined?.resume()
    joined = nil
    await withTaskCancellationHandler {
      if arrivalReleased { return }
      await withCheckedContinuation { arrival = $0 }
    } onCancel: {
      Task { await self.noteCancellation() }
    }
    await bytes.seed(key: key, data: Data([0x01]))
  }

  func waitUntilJoined() async {
    if joinCalls > 0 { return }
    await withCheckedContinuation { joined = $0 }
  }

  func releaseArrival() {
    arrivalReleased = true
    arrival?.resume()
    arrival = nil
  }

  func waitUntilCancelled() async {
    if cancelledCalls > 0 { return }
    await withCheckedContinuation { cancellationWaiter = $0 }
  }

  private func noteCancellation() {
    cancelledCalls += 1
    cancellationWaiter?.resume()
    cancellationWaiter = nil
    arrival?.resume()
    arrival = nil
  }
}
