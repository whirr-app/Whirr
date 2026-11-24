import ABSApi
import DesignSystem
import Foundation
import Persistence
import SwiftUI
import TestSupport
import Testing

@testable import Whirr

@Suite("Home wash provider", .timeLimit(.minutes(1)))
@MainActor
struct HomeWashProviderTests {

  // MARK: - RSS subjects and their artwork source

  @Test("RSS preload resolves a stored wash when its source is supplied")
  func rssPreloadResolvesStoredWashWithSource() async throws {
    let fixtures = EditorialWashTestFixtures()
    let rssArtwork = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:7", artworkURL: URL(string: "https://example.com/show.jpg")!,
        feedURL: URL(string: "https://example.com/feed.xml")!))
    let source = ArtworkSource.rss(rssArtwork)
    let itemID = "rss:7"
    await fixtures.records.seed(
      CoverPaletteRecord(
        itemId: itemID,
        artworkKey: CoverPaletteWriter.recordIdentity(
          accountScope: source.cacheScope, itemID: itemID, revision: .unversioned),
        accentHue: 0.1, accentSaturation: 0.5, accentBrightness: 0.5,
        averageRed: 0.2, averageGreen: 0.3, averageBlue: 0.4, extractedAt: Date()))
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale)

    await provider.preloadCachedWashes([
      EditorialWashSubject(itemID: itemID, artworkSource: source, artworkRevision: .unversioned)
    ])

    #expect(provider.washes[itemID] != nil)
    #expect(
      provider.wash(
        for: EditorialWashSubject(itemID: itemID, artworkSource: source, artworkRevision: .unversioned))
        != .drainedNeutral)
  }

  @Test("an RSS subject that carries its source resolves through the lazy request path")
  func rssRequestResolvesWithSubjectSource() async throws {
    let fixtures = EditorialWashTestFixtures()
    let rssArtwork = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:7", artworkURL: URL(string: "https://example.com/show.jpg")!,
        feedURL: URL(string: "https://example.com/feed.xml")!))
    let subject = EditorialWashSubject(itemID: "rss:7", artworkSource: .rss(rssArtwork), artworkRevision: .unversioned)
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)

    provider.request([subject], intent: .visible)
    _ = await observer.nextBatch()

    #expect(provider.washes["rss:7"] != nil)
  }

  @Test("an RSS subject without a source is a feed with no artwork, and stays neutral")
  func rssRequestWithoutSourceStaysNeutral() {
    let fixtures = EditorialWashTestFixtures()
    let subject = EditorialWashSubject(itemID: "rss:7", artworkSource: nil, artworkRevision: .unversioned)
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale)

    // Skipped at admission, so nothing is in flight. The read stays neutral.
    provider.request([subject], intent: .visible)

    #expect(provider.washes["rss:7"] == nil)
    #expect(provider.wash(for: subject) == .drainedNeutral)
  }

  @Test("RSS preload skips an item when no source is supplied")
  func rssPreloadSkipsWithoutSource() async throws {
    let fixtures = EditorialWashTestFixtures()
    let rssArtwork = try #require(
      RSSArtworkSource(
        feedIdentity: "rss:7", artworkURL: URL(string: "https://example.com/show.jpg")!,
        feedURL: URL(string: "https://example.com/feed.xml")!))
    let source = ArtworkSource.rss(rssArtwork)
    let itemID = "rss:7"
    await fixtures.records.seed(
      CoverPaletteRecord(
        itemId: itemID,
        artworkKey: CoverPaletteWriter.recordIdentity(
          accountScope: source.cacheScope, itemID: itemID, revision: .unversioned),
        accentHue: 0.1, accentSaturation: 0.5, accentBrightness: 0.5,
        averageRed: 0.2, averageGreen: 0.3, averageBlue: 0.4, extractedAt: Date()))
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale)

    await provider.preloadCachedWashes([
      EditorialWashSubject(itemID: itemID, artworkSource: nil, artworkRevision: .unversioned)
    ])

    #expect(provider.washes[itemID] == nil)
  }

  // MARK: - Publication ordering and batching

  @Test("an early item publishes before its slow batch-mate")
  func earlyItemPublishesBeforeItsSlowBatchMate() async {
    let fixtures = EditorialWashTestFixtures()
    let slowItemID = "show-slow"
    await fixtures.records.holdFetch(for: slowItemID)
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)
    provider.request(washesFor: [fixtures.itemID, slowItemID], intent: .visible)
    await fixtures.records.waitUntilFetchStarted(for: slowItemID)

    let first = await observer.nextBatch()
    #expect(first[fixtures.itemID] != nil)
    #expect(provider.washes[fixtures.itemID] != nil)
    #expect(provider.washes[slowItemID] == nil)

    await fixtures.records.releaseFetch(for: slowItemID)
    let second = await observer.nextBatch()
    #expect(second[slowItemID] != nil)
  }

  @Test("a warm resolution stream publishes before the stream drains")
  func warmResolutionStreamPublishesBeforeTheStreamDrains() async {
    let fixtures = EditorialWashTestFixtures()
    let itemIDs = (0..<100).map { "warm-\($0)" }
    for itemID in itemIDs {
      await fixtures.records.seed(fixtures.warmRecord(for: itemID))
    }
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)
    provider.request(washesFor: itemIDs, intent: .bulk)
    let first = await observer.nextBatch()

    #expect(first.isEmpty == false)
    #expect(first.count < itemIDs.count)
  }

  @Test("a new item starts while a slow item remains in flight")
  func newItemStartsWhileSlowItemRemainsInFlight() async {
    let fixtures = EditorialWashTestFixtures()
    let slowItemID = "show-slow"
    let nextItemID = "show-next"
    await fixtures.records.holdFetch(for: slowItemID)
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)

    provider.request(washesFor: [slowItemID], intent: .visible)
    await fixtures.records.waitUntilFetchStarted(for: slowItemID)

    provider.request(washesFor: [nextItemID], intent: .visible)
    await fixtures.records.waitUntilFetchStarted(for: nextItemID)

    let next = await observer.nextBatch()
    #expect(next[nextItemID] != nil)
    #expect(provider.washes[nextItemID] != nil)
    #expect(provider.washes[slowItemID] == nil)

    await fixtures.records.releaseFetch(for: slowItemID)
    let slow = await observer.nextBatch()
    #expect(slow[slowItemID] != nil)
  }

  @Test("visible work is admitted before queued bulk work")
  func visibleWorkIsAdmittedBeforeQueuedBulkWork() async {
    let fixtures = EditorialWashTestFixtures()
    let bulkItemIDs = (0..<6).map { "bulk-\($0)" }
    let visibleItemID = "visible"
    for itemID in bulkItemIDs + [visibleItemID] {
      await fixtures.records.holdFetch(for: itemID)
    }
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)

    provider.request(washesFor: Array(bulkItemIDs.prefix(4)), intent: .bulk)
    for itemID in bulkItemIDs.prefix(4) {
      await fixtures.records.waitUntilFetchStarted(for: itemID)
    }

    provider.request(washesFor: Array(bulkItemIDs.dropFirst(4)), intent: .bulk)
    provider.request(washesFor: [visibleItemID], intent: .visible)
    await fixtures.records.releaseFetch(for: bulkItemIDs[0])
    await fixtures.records.waitUntilFetchStarted(for: visibleItemID)

    #expect(await fixtures.records.hasFetchStarted(for: bulkItemIDs[4]) == false)
    #expect(await fixtures.records.hasFetchStarted(for: bulkItemIDs[5]) == false)

    for itemID in bulkItemIDs + [visibleItemID] {
      await fixtures.records.releaseFetch(for: itemID)
    }
    _ = await awaitCondition(
      "all visible and bulk washes resolve",
      observing: { "resolved=\(observer.resolvedCount)/\(bulkItemIDs.count + 1)" },
      until: { observer.resolvedCount >= bulkItemIDs.count + 1 })
  }

  @Test("same-update requests eventually publish all 100 washes")
  func sameUpdateRequestsEventuallyPublishAll100Washes() async {
    let fixtures = EditorialWashTestFixtures()
    let observer = EditorialWashBatchObserver()
    let mutationObserver = EditorialWashMutationObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onWashesMutated: mutationObserver.record,
      onBatchResolved: observer.receive)
    let itemIDs = (0..<100).map { "show-\($0)" }

    for itemID in itemIDs {
      provider.request(washesFor: [itemID], intent: .bulk)
    }
    _ = await awaitCondition(
      "all 100 washes resolve",
      observing: { "resolved=\(observer.resolvedCount)/\(itemIDs.count)" },
      until: { observer.resolvedCount >= itemIDs.count })
    let resolved = observer.resolvedWashes

    #expect(resolved.count == 100)
    #expect(provider.washes.count == 100)
    #expect(mutationObserver.count > 0)
    #expect(observer.count > 0)
  }

  // MARK: - Seeding cached washes

  @Test("a seed publishes a wash the service already holds, without suspending")
  func seedPublishesCoordinatorMemoryWashSynchronously() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.records.seed(fixtures.warmRecord(for: fixtures.itemID))
    let service = fixtures.service()
    _ = await service.cachedWashes(itemIDs: [fixtures.itemID], revisionsByID: [:])
    let provider = HomeWashProvider(
      service: service, displaySize: HomeView.cardCoverSize, displayScale: EditorialWashTestFixtures.cardScale)

    provider.seedCachedWashes([.audiobookshelf(fixtures.itemID, revision: .unversioned)])

    #expect(provider.washes[fixtures.itemID] == fixtures.warmWash)
  }

  @Test("a seed never reads the record store, so a cold service leaves the card neutral")
  func seedOnColdCoordinatorReadsNoRecords() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.records.seed(fixtures.warmRecord(for: fixtures.itemID))
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale)

    provider.seedCachedWashes([.audiobookshelf(fixtures.itemID, revision: .unversioned)])

    #expect(provider.washes.isEmpty)
    #expect(await fixtures.records.batchFetchCount == 0)
    #expect(await fixtures.records.singleFetchCount == 0)
  }

  @Test("a seed during tracking publishes only at idle")
  func seedDuringTrackingPublishesOnlyAtIdle() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.records.seed(fixtures.warmRecord(for: fixtures.itemID))
    let service = fixtures.service()
    _ = await service.cachedWashes(itemIDs: [fixtures.itemID], revisionsByID: [:])
    let provider = HomeWashProvider(
      service: service, displaySize: HomeView.cardCoverSize, displayScale: EditorialWashTestFixtures.cardScale)
    let source = HomeWashProvider.ScrollSource(id: .podcastsOuter, generation: UUID())

    provider.setScrollInteractionActive(.tracking, source: source)
    provider.seedCachedWashes([.audiobookshelf(fixtures.itemID, revision: .unversioned)])

    #expect(provider.washes.isEmpty)
    provider.setScrollInteractionActive(.idle, source: source)
    #expect(provider.washes[fixtures.itemID] == fixtures.warmWash)
  }

  @Test("re-seeding a wash already published does not mutate the screen again")
  func reseedOfPublishedWashIsNotAMutation() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.records.seed(fixtures.warmRecord(for: fixtures.itemID))
    let service = fixtures.service()
    _ = await service.cachedWashes(itemIDs: [fixtures.itemID], revisionsByID: [:])
    let mutationObserver = EditorialWashMutationObserver()
    let provider = HomeWashProvider(
      service: service, displaySize: HomeView.cardCoverSize, displayScale: EditorialWashTestFixtures.cardScale,
      onWashesMutated: mutationObserver.record)
    let subjects: [EditorialWashSubject] = [
      .audiobookshelf(fixtures.itemID, revision: .unversioned)
    ]

    provider.seedCachedWashes(subjects)
    provider.seedCachedWashes(subjects)

    #expect(mutationObserver.count == 1)
  }

  @Test("the page preload after a seed does not publish the same washes again")
  func preloadAfterSeedIsNotASecondMutation() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.records.seed(fixtures.warmRecord(for: fixtures.itemID))
    let service = fixtures.service()
    _ = await service.cachedWashes(itemIDs: [fixtures.itemID], revisionsByID: [:])
    let mutationObserver = EditorialWashMutationObserver()
    let provider = HomeWashProvider(
      service: service, displaySize: HomeView.cardCoverSize, displayScale: EditorialWashTestFixtures.cardScale,
      onWashesMutated: mutationObserver.record)
    let subjects: [EditorialWashSubject] = [
      .audiobookshelf(fixtures.itemID, revision: .unversioned)
    ]

    provider.seedCachedWashes(subjects)
    await provider.preloadCachedWashes(subjects)

    #expect(provider.washes[fixtures.itemID] == fixtures.warmWash)
    #expect(mutationObserver.count == 1)
  }

  @Test("preload and resolution merge into one idle publication")
  func preloadAndResolutionMergeIntoOneIdlePublication() async {
    let fixtures = EditorialWashTestFixtures()
    let preloadItemID = "warm-preload"
    await fixtures.records.seed(fixtures.warmRecord(for: preloadItemID))
    let observer = EditorialWashBatchObserver()
    let mutationObserver = EditorialWashMutationObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onWashesMutated: mutationObserver.record,
      onBatchResolved: observer.receive)
    let source = HomeWashProvider.ScrollSource(id: .homeOuter, generation: UUID())
    provider.setScrollInteractionActive(.tracking, source: source)
    let preload = Task { await provider.preloadCachedWashes(for: [preloadItemID]) }
    provider.request(washesFor: [fixtures.itemID], intent: .bulk)
    await preload.value
    _ = await observer.nextBatch()

    #expect(provider.washes.isEmpty)
    #expect(mutationObserver.count == 0)
    provider.setScrollInteractionActive(.idle, source: source)
    #expect(provider.washes.count == 2)
    #expect(mutationObserver.count == 1)
  }

  // MARK: - Preloaded and persisted washes

  @Test("page preload publishes every persisted wash as one mutation")
  func pagePreloadPublishesEveryPersistedWashAsOneMutation() async {
    let fixtures = EditorialWashTestFixtures()
    let itemIDs = (0..<20).map { "warm-\($0)" }
    for itemID in itemIDs {
      await fixtures.records.seed(fixtures.warmRecord(for: itemID))
    }
    let mutationObserver = EditorialWashMutationObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onWashesMutated: mutationObserver.record)

    await provider.preloadCachedWashes(for: itemIDs + ["cold-miss"])

    #expect(provider.washes.count == itemIDs.count)
    #expect(provider.washes["cold-miss"] == nil)
    #expect(mutationObserver.count == 1)
    #expect(await fixtures.extractionCalls.value == 0)
    #expect(await fixtures.pipeline.joinCalls == 0)
  }

  @Test("a preloaded item is skipped by a later request")
  func preloadedItemIsSkippedByALaterRequest() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.records.seed(fixtures.warmRecord(for: fixtures.itemID))
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)

    await provider.preloadCachedWashes(for: [fixtures.itemID])
    // Re-arm the fetch tracker: a wrongly re-resolved preloaded item would fetch its record again.
    await fixtures.records.holdFetch(for: fixtures.itemID)
    provider.request(washesFor: [fixtures.itemID, "show-2"], intent: .bulk)
    let resolved = await observer.nextBatch()

    #expect(resolved["show-2"] != nil)
    #expect(resolved[fixtures.itemID] == nil)
    #expect(await fixtures.records.hasFetchStarted(for: fixtures.itemID) == false)
  }

  @Test("different display sizes share one persisted wash")
  func differentDisplaySizesShareOnePersistedWash() async {
    let fixtures = EditorialWashTestFixtures()
    let firstObserver = EditorialWashBatchObserver()
    let first = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: firstObserver.receive)
    first.request(washesFor: [fixtures.itemID], intent: .bulk)
    _ = await firstObserver.nextBatch()

    let secondObserver = EditorialWashBatchObserver()
    let second = HomeWashProvider(
      service: fixtures.service(), displaySize: 120, displayScale: 2,
      onBatchResolved: secondObserver.receive)
    second.request(washesFor: [fixtures.itemID], intent: .bulk)
    let resolved = await secondObserver.nextBatch()

    #expect(resolved[fixtures.itemID] != nil)
    #expect(await fixtures.extractionCalls.value == 1)
    #expect(await fixtures.records.record(for: fixtures.itemID)?.artworkKey == fixtures.canonicalKey)
  }

  @Test("concurrent surfaces share one extraction")
  func concurrentSurfacesShareOneExtraction() async {
    let fixtures = EditorialWashTestFixtures(gatedExtraction: true)
    let firstObserver = EditorialWashBatchObserver()
    let secondObserver = EditorialWashBatchObserver()
    let service = fixtures.service()
    let first = HomeWashProvider(
      service: service, displaySize: HomeView.cardCoverSize, displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: firstObserver.receive)
    let second = HomeWashProvider(
      service: service, displaySize: 120, displayScale: 2,
      onBatchResolved: secondObserver.receive)
    first.request(washesFor: [fixtures.itemID], intent: .bulk)
    second.request(washesFor: [fixtures.itemID], intent: .bulk)
    await fixtures.extractionGate!.waitUntilStarted()

    #expect(await fixtures.extractionCalls.value == 1)
    await fixtures.extractionGate!.release()
    _ = await firstObserver.nextBatch()
    _ = await secondObserver.nextBatch()
    #expect(await fixtures.extractionCalls.value == 1)
  }

  @Test("no accent record is still a cache hit")
  func noAccentRecordIsStillACacheHit() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.records.seed(
      CoverPaletteRecord(
        itemId: fixtures.itemID, artworkKey: fixtures.canonicalKey,
        accentHue: nil, accentSaturation: nil, accentBrightness: nil,
        averageRed: 0.2, averageGreen: 0.3, averageBlue: 0.4, extractedAt: Date()))
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)
    provider.request(washesFor: [fixtures.itemID], intent: .bulk)
    let resolved = await observer.nextBatch()

    #expect(resolved[fixtures.itemID].map { $0 == .drainedNeutral } == true)
    #expect(provider.washes[fixtures.itemID] == .drainedNeutral)
    #expect(await fixtures.extractionCalls.value == 0)
  }

  @Test("clearing entries makes a previously neutral record derive again")
  func clearingEntriesMakesPreviouslyNeutralRecordDeriveAgain() async {
    let fixtures = EditorialWashTestFixtures()
    let service = fixtures.service()
    await fixtures.records.seed(
      CoverPaletteRecord(
        itemId: fixtures.itemID, artworkKey: fixtures.canonicalKey,
        accentHue: nil, accentSaturation: nil, accentBrightness: nil,
        averageRed: 0.2, averageGreen: 0.3, averageBlue: 0.4, extractedAt: Date()))

    let first = await service.resolveWashes(
      itemIDs: [fixtures.itemID], displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale, intent: .bulk, revisionsByID: [:])
    #expect(first[fixtures.itemID] == .drainedNeutral)

    service.clear()
    await fixtures.records.removeAll()

    let second = await service.resolveWashes(
      itemIDs: [fixtures.itemID], displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale, intent: .bulk, revisionsByID: [:])

    #expect(second[fixtures.itemID] != .drainedNeutral)
    #expect(await fixtures.extractionCalls.value == 1)
  }

  @Test("artwork revision change invalidates the persisted wash")
  func artworkRevisionChangeInvalidatesThePersistedWash() async {
    let fixtures = EditorialWashTestFixtures()
    let oldRevision = ArtworkRevision("old")
    await fixtures.records.seed(
      CoverPaletteRecord(
        itemId: fixtures.itemID, artworkKey: fixtures.canonicalKey(for: oldRevision),
        accentHue: 0.1, accentSaturation: 0.5, accentBrightness: 0.5,
        averageRed: 0.2, averageGreen: 0.3, averageBlue: 0.4, extractedAt: Date()))
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: 120, displayScale: 3,
      onBatchResolved: observer.receive)
    provider.request(
      washesFor: [fixtures.itemID], intent: .bulk, artworkRevision: oldRevision)
    _ = await observer.nextBatch()
    #expect(provider.washes[fixtures.itemID] != nil)

    await fixtures.records.holdFetch(for: fixtures.itemID)
    provider.request(
      washesFor: [fixtures.itemID], intent: .bulk, artworkRevision: ArtworkRevision("new"))
    #expect(provider.washes[fixtures.itemID] == nil)
    await fixtures.records.waitUntilFetchStarted(for: fixtures.itemID)
    await fixtures.records.releaseFetch(for: fixtures.itemID)
    _ = await observer.nextBatch()

    #expect(await fixtures.extractionCalls.value == 1)
    #expect(
      await fixtures.records.record(for: fixtures.itemID)?.artworkKey
        == fixtures.canonicalKey(for: ArtworkRevision("new")))
  }

  // MARK: - Artwork arrival and cold misses

  @Test("bulk cold miss starts no artwork operation")
  func bulkColdMissStartsNoArtworkOperation() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.bytes.clearDefault()
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)
    provider.request(washesFor: [fixtures.itemID], intent: .bulk)
    let resolved = await observer.nextBatch()

    #expect(resolved.isEmpty)
    #expect(await fixtures.pipeline.joinCalls == 0)
    #expect(provider.washes[fixtures.itemID] ?? .drainedNeutral == .drainedNeutral)
  }

  @Test("visible cold miss shares the displayed artwork operation once")
  func visibleColdMissSharesTheDisplayedArtworkOperationOnce() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.bytes.clearDefault()
    let bytes = fixtures.bytes
    let sampleData = fixtures.sampleData
    await fixtures.pipeline.setArrival { key in
      await bytes.seed(key: key, data: sampleData)
    }
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)
    provider.request(washesFor: [fixtures.itemID], intent: .visible)
    let resolved = await observer.nextBatch()

    #expect(resolved[fixtures.itemID].map { $0 != .drainedNeutral } == true)
    #expect(await fixtures.pipeline.joinCalls == 1)
    #expect(await fixtures.extractionCalls.value == 1)
  }

  @Test("failed artwork arrival leaves the neutral fallback and clears in-flight state")
  func failedArtworkArrivalLeavesTheNeutralFallbackAndClearsInFlightState() async {
    let fixtures = EditorialWashTestFixtures()
    await fixtures.bytes.clearDefault()
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)
    provider.request(washesFor: [fixtures.itemID], intent: .visible)
    #expect((await observer.nextBatch())[fixtures.itemID] == nil)
    #expect(provider.washes[fixtures.itemID] ?? .drainedNeutral == .drainedNeutral)

    provider.request(washesFor: [fixtures.itemID], intent: .visible)
    #expect((await observer.nextBatch())[fixtures.itemID] == nil)
    #expect(await fixtures.pipeline.joinCalls == 2)
  }

  @Test("a satisfied pending upgrade does not republish the wash")
  func drainedSatisfiedUpgradeDoesNotRepublishWash() async {
    let fixtures = EditorialWashTestFixtures(gatedExtraction: true)
    let observer = EditorialWashBatchObserver()
    let mutationObserver = EditorialWashMutationObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onWashesMutated: mutationObserver.record,
      onBatchResolved: observer.receive)
    provider.request(washesFor: [fixtures.itemID], intent: .bulk)
    await fixtures.extractionGate!.waitUntilStarted()
    provider.request(washesFor: [fixtures.itemID], intent: .visible)
    await fixtures.extractionGate!.release()

    let first = await observer.nextBatch()
    #expect(first[fixtures.itemID] != nil)
    #expect(observer.count == 1)
    #expect(mutationObserver.count == 1)

    provider.request(washesFor: ["show-2"], intent: .bulk)
    let second = await observer.nextBatch()

    #expect(second.count == 1)
    #expect(second["show-2"] != nil)
    #expect(second[fixtures.itemID] == nil)
    #expect(observer.count == 2)
    #expect(mutationObserver.count == 2)
  }

  // MARK: - Service clear

  @Test("a service clear returns a published wash to neutral and re-derives it")
  func coordinatorClearReturnsWashToNeutralAndRederivesIt() async {
    let fixtures = EditorialWashTestFixtures()
    let service = fixtures.service()
    await fixtures.records.seed(fixtures.warmRecord(for: fixtures.itemID))
    let subject = EditorialWashSubject.audiobookshelf(fixtures.itemID, revision: .unversioned)
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: service, displaySize: HomeView.cardCoverSize, displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)
    provider.request([subject], intent: .visible)
    _ = await observer.nextBatch()
    let stale = provider.wash(for: subject)
    #expect(stale == fixtures.warmWash)

    // Production clears the persisted rows before the in-memory layer.
    await fixtures.records.removeAll()
    service.clear()

    #expect(provider.washes.isEmpty)
    #expect(provider.wash(for: subject) == .drainedNeutral)

    let rederived = await observer.nextBatch()
    #expect(rederived[fixtures.itemID] != nil)
    #expect(provider.wash(for: subject) != .drainedNeutral)
    #expect(provider.wash(for: subject) != stale)
    #expect(await fixtures.extractionCalls.value == 1)
  }

  @Test("a service clear re-resolves an item whose resolution was in flight")
  func coordinatorClearReresolvesAnInFlightItem() async {
    let fixtures = EditorialWashTestFixtures()
    let service = fixtures.service()
    await fixtures.records.seed(fixtures.warmRecord(for: fixtures.itemID))
    await fixtures.records.holdFetch(for: fixtures.itemID)
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: service, displaySize: HomeView.cardCoverSize, displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)
    provider.request(washesFor: [fixtures.itemID], intent: .visible)
    await fixtures.records.waitUntilFetchStarted(for: fixtures.itemID)

    await fixtures.records.removeAll()
    service.clear()
    await fixtures.records.releaseFetch(for: fixtures.itemID)

    // The pre-clear resolution must neither publish nor retire the bookkeeping of its successor.
    let rederived = await observer.nextBatch()
    #expect(rederived[fixtures.itemID] != nil)
    #expect(rederived[fixtures.itemID] != fixtures.warmWash)
    #expect(provider.washes[fixtures.itemID] == rederived[fixtures.itemID])
  }

  @Test("a service clear drops a wash deferred behind a moving scroll")
  func coordinatorClearDropsAWashDeferredBehindAMovingScroll() async {
    let fixtures = EditorialWashTestFixtures()
    let service = fixtures.service()
    await fixtures.records.seed(fixtures.warmRecord(for: fixtures.itemID))
    let observer = EditorialWashBatchObserver()
    let provider = HomeWashProvider(
      service: service, displaySize: HomeView.cardCoverSize, displayScale: EditorialWashTestFixtures.cardScale,
      onBatchResolved: observer.receive)
    let source = provider.scrollSource(for: .homeOuter)
    provider.setScrollInteractionActive(.tracking, source: source)
    provider.request(washesFor: [fixtures.itemID], intent: .visible)
    _ = await observer.nextBatch()
    #expect(provider.washes.isEmpty)

    await fixtures.records.removeAll()
    service.clear()
    _ = await observer.nextBatch()
    provider.setScrollInteractionActive(.idle, source: source)

    #expect(provider.washes[fixtures.itemID] != nil)
    #expect(provider.washes[fixtures.itemID] != fixtures.warmWash)
  }

  @Test("a preload that straddles a service clear publishes nothing")
  func preloadStraddlingACoordinatorClearPublishesNothing() async {
    let fixtures = EditorialWashTestFixtures()
    let service = fixtures.service()
    await fixtures.records.seed(fixtures.warmRecord(for: fixtures.itemID))
    await fixtures.records.holdNextBatchFetch()
    let mutationObserver = EditorialWashMutationObserver()
    let provider = HomeWashProvider(
      service: service, displaySize: HomeView.cardCoverSize, displayScale: EditorialWashTestFixtures.cardScale,
      onWashesMutated: mutationObserver.record)

    let preload = Task { await provider.preloadCachedWashes(for: [fixtures.itemID]) }
    await fixtures.records.waitUntilBatchFetchStarted()
    service.clear()
    await fixtures.records.removeAll()
    await fixtures.records.releaseBatchFetch()
    await preload.value

    #expect(provider.washes.isEmpty)
    #expect(mutationObserver.count == 0)
    #expect(await service.cachedWashes(itemIDs: [fixtures.itemID], revisionsByID: [:]).isEmpty)
  }

  // MARK: - Retention and cost baseline

  @Test("a released provider is not retained by its service")
  func releasedProviderIsNotRetainedByItsCoordinator() {
    let fixtures = EditorialWashTestFixtures()
    let service = fixtures.service()
    weak var released: HomeWashProvider?
    do {
      let provider = HomeWashProvider(
        service: service, displaySize: HomeView.cardCoverSize, displayScale: EditorialWashTestFixtures.cardScale
      )
      released = provider
    }

    #expect(released == nil)
    service.clear()
  }

  /// Baseline for one screen of cards: half saved, half cold, and two whose covers never arrive
  /// and so are followed. Moving Home onto the palette service must leave every count unchanged.
  @Test("one screen's resolution costs a fixed number of reads, extractions and publications")
  func oneScreensResolutionCost() async {
    let fixtures = EditorialWashTestFixtures()
    let warm = (0..<6).map { "warm-\($0)" }
    let cold = (0..<6).map { "cold-\($0)" }
    let missing = ["missing-0", "missing-1"]
    for itemID in warm {
      await fixtures.records.seed(fixtures.warmRecord(for: itemID))
    }
    for itemID in missing {
      await fixtures.bytes.setMissing(itemID)
    }
    let mutations = EditorialWashMutationObserver()
    let provider = HomeWashProvider(
      service: fixtures.service(), displaySize: HomeView.cardCoverSize,
      displayScale: EditorialWashTestFixtures.cardScale,
      onWashesMutated: mutations.record)

    provider.request(washesFor: warm + cold + missing, intent: .bulk)
    _ = await awaitCondition(
      "screen resolved and following",
      observing: { "washes=\(provider.washes.count)" },
      until: {
        guard provider.washes.count == warm.count + cold.count else { return false }
        return await fixtures.records.observerCount == 1
      })

    let batchReads = await fixtures.records.batchFetchCount
    let singleReads = await fixtures.records.singleFetchCount
    let extractions = await fixtures.extractionCalls.value
    let observations = await fixtures.records.observationsStarted
    let joins = await fixtures.pipeline.joinCalls
    // Exact where the work is deterministic: one row read per card, one extraction per cold card,
    // no artwork joins for a bulk request.
    #expect(batchReads == 0)
    #expect(singleReads == warm.count + cold.count + missing.count)
    #expect(extractions == cold.count)
    #expect(joins == 0)
    // Bounded where it depends on arrival timing: the follow observation can restart once as
    // misses coalesce, and publications batch by arrival, never more than one per card. Measured
    // at 2 observations and 8 publications.
    #expect(observations <= 2)
    #expect((1...(warm.count + cold.count)).contains(mutations.count))
  }
}
