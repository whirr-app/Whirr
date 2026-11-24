import ABSApi
import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

@Suite("Cover cache all coordinator", .timeLimit(.minutes(1)))
struct CoverCacheAllCoordinatorTests {

  private static let accountScope = ArtworkAccountScope("https://covers.example.test")
  private static let libraryThumbnailPixelWidth = 132
  private static let highFidelityPixelWidth = 768
  private static let podcastEpisodeThumbnailPixelWidth = 168
  private static let homeCardPixelWidth = 420

  @Test("fetches both the canonical thumbnail and high-fidelity key per item")
  func fetchesEveryCanonicalKeyPerItem() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1", "item-2"])
    let covers = FakeCoverCacheFilling()
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    let outcome = await coordinator.runAll()

    #expect(Set(await covers.fetchRequests) == Self.allArtworkKeys(for: ["item-1", "item-2"]))
    #expect(outcome == CoverCacheRunOutcome(fetched: 2, alreadyPresent: 0, failed: 0, finished: true))
  }

  @Test("keys carry each item's server updatedAt as the cover revision")
  func keysCarryServerRevision() async throws {
    let updatedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let fixture = try await Self.makeFixture(
      itemIDs: ["item-1"], serverUpdatedAt: ["item-1": updatedAt])
    let covers = FakeCoverCacheFilling()
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    _ = await coordinator.runAll()

    let revisions = Set(await covers.fetchRequests.map(\.revision))
    #expect(revisions == [ArtworkRevision(serverUpdatedAt: updatedAt)])
  }

  @Test("fetches the episode-thumbnail key for podcasts only, and the card key for both")
  func fetchesPodcastOnlyKeys() async throws {
    let fixture = try await Self.makeFixture(
      itemIDs: ["book-1", "podcast-1"], podcastItemIDs: ["podcast-1"])
    let covers = FakeCoverCacheFilling()
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    let outcome = await coordinator.runAll()

    #expect(
      Set(await covers.fetchRequests) == [
        Self.thumbnailKey(itemID: "book-1"),
        Self.highFidelityKey(itemID: "book-1"),
        Self.homeCardKey(itemID: "book-1"),
        Self.thumbnailKey(itemID: "podcast-1"),
        Self.highFidelityKey(itemID: "podcast-1"),
        Self.homeCardKey(itemID: "podcast-1"),
        Self.podcastEpisodeThumbnailKey(itemID: "podcast-1"),
      ])
    #expect(outcome == CoverCacheRunOutcome(fetched: 2, alreadyPresent: 0, failed: 0, finished: true))
  }

  @Test("a high-fidelity-only item fetches its missing thumbnail on the next run")
  func highFidelityOnlyItemFetchesMissingThumbnail() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1"])
    let covers = FakeCoverCacheFilling(presentKeys: [Self.highFidelityKey(itemID: "item-1")])
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    let outcome = await coordinator.runAll()

    #expect(
      Set(await covers.fetchRequests) == [
        Self.thumbnailKey(itemID: "item-1"), Self.homeCardKey(itemID: "item-1"),
      ])
    #expect(outcome == CoverCacheRunOutcome(fetched: 1, alreadyPresent: 0, failed: 0, finished: true))
  }

  @Test("census counts an item only when every artwork variant is present")
  func censusRequiresBothArtworkVariants() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1", "item-2", "item-3"])
    let covers = FakeCoverCacheFilling(
      presentKeys: Self.allArtworkKeys(for: ["item-1"]).union([
        Self.highFidelityKey(itemID: "item-2"),
        Self.thumbnailKey(itemID: "item-3"),
      ]))
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    #expect(await coordinator.census() == ItemDAO.MetadataCensus(covered: 1, total: 3))
  }

  @Test("census requires the episode-thumbnail variant only for podcasts")
  func censusRequiresPodcastOnlyVariants() async throws {
    let fixture = try await Self.makeFixture(
      itemIDs: [
        "book-1", "podcast-complete", "podcast-missing-card", "podcast-missing-episode-thumbnail",
      ],
      podcastItemIDs: [
        "podcast-complete", "podcast-missing-card", "podcast-missing-episode-thumbnail",
      ])
    let covers = FakeCoverCacheFilling(presentKeys: [
      Self.thumbnailKey(itemID: "book-1"),
      Self.highFidelityKey(itemID: "book-1"),
      Self.homeCardKey(itemID: "book-1"),
      Self.thumbnailKey(itemID: "podcast-complete"),
      Self.highFidelityKey(itemID: "podcast-complete"),
      Self.podcastEpisodeThumbnailKey(itemID: "podcast-complete"),
      Self.homeCardKey(itemID: "podcast-complete"),
      Self.thumbnailKey(itemID: "podcast-missing-card"),
      Self.highFidelityKey(itemID: "podcast-missing-card"),
      Self.podcastEpisodeThumbnailKey(itemID: "podcast-missing-card"),
      Self.thumbnailKey(itemID: "podcast-missing-episode-thumbnail"),
      Self.highFidelityKey(itemID: "podcast-missing-episode-thumbnail"),
      Self.homeCardKey(itemID: "podcast-missing-episode-thumbnail"),
    ])
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    #expect(await coordinator.census() == ItemDAO.MetadataCensus(covered: 2, total: 4))
    #expect(await covers.fetchRequests.isEmpty)
  }

  @Test("skips a present item and counts it as already present")
  func skipsPresentItem() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1", "item-2", "item-3"])
    let covers = FakeCoverCacheFilling(presentKeys: Self.allArtworkKeys(for: ["item-2"]))
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    let outcome = await coordinator.runAll()

    #expect(
      Set(await covers.fetchRequests) == Self.allArtworkKeys(for: ["item-1", "item-3"]))
    #expect(outcome == CoverCacheRunOutcome(fetched: 2, alreadyPresent: 1, failed: 0, finished: true))
  }

  @Test("never has more than two fetches in flight")
  func neverHasMoreThanTwoFetchesInFlight() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1", "item-2", "item-3", "item-4"])
    let covers = FakeCoverCacheFilling(holdFetches: true)
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)
    let run = Task { await coordinator.runAll() }

    await waitUntil { await covers.fetchRequests.count == 2 }
    #expect(await covers.highWaterMark == 2)

    await covers.releaseFetches()
    let outcome = await run.value
    #expect(outcome.fetched == 4)
    #expect(await covers.highWaterMark == 2)
  }

  @Test("counts a failed fetch and completes the remaining items")
  func countsFailedFetchAndCompletesRemainingItems() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1", "item-2", "item-3"])
    let covers = FakeCoverCacheFilling(failingKeys: [Self.key(itemID: "item-2")])
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    let outcome = await coordinator.runAll()

    #expect(await covers.fetchRequests.count == 9)
    #expect(outcome == CoverCacheRunOutcome(fetched: 2, alreadyPresent: 0, failed: 1, finished: true))
  }

  @Test("a cover 404 excludes generated artwork from later runs and censuses")
  func coverNotFoundBecomesIneligibleArtwork() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["has-cover", "generated-cover"])
    let missingKey = Self.homeCardKey(itemID: "generated-cover")
    let covers = FakeCoverCacheFilling(notFoundKeys: [missingKey])
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    let first = await coordinator.runAll()

    #expect(
      first
        == CoverCacheRunOutcome(
          fetched: 1, alreadyPresent: 0, failed: 0, unavailable: 1, finished: true))
    #expect(await covers.fetchRequests.filter { $0.itemID == "generated-cover" } == [missingKey])
    #expect(await coordinator.census() == ItemDAO.MetadataCensus(covered: 1, total: 1))

    let requestsAfterFirstRun = await covers.fetchRequests.count
    let second = await coordinator.runAll()

    #expect(
      second
        == CoverCacheRunOutcome(
          fetched: 0, alreadyPresent: 1, failed: 0, unavailable: 0, finished: true))
    #expect(await covers.fetchRequests.count == requestsAfterFirstRun)
  }

  @Test("cancel stops the pass and reports an unfinished outcome")
  func cancelStopsPass() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1", "item-2", "item-3", "item-4"])
    let covers = FakeCoverCacheFilling(holdFetches: true)
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)
    let run = Task { await coordinator.runAll() }

    await waitUntil { await covers.fetchRequests.count == 2 }
    await coordinator.cancel()

    let outcome = await run.value
    #expect(outcome.finished == false)
    #expect(await covers.fetchRequests.count == 2)
  }

  @Test("suspension pauses the pass until resumed")
  func suspensionPausesUntilResumed() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1", "item-2", "item-3", "item-4"])
    let covers = FakeCoverCacheFilling(holdFetches: true)
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)
    var progress = (await coordinator.progress).makeAsyncIterator()
    _ = await progress.next()
    let run = Task { await coordinator.runAll() }

    await waitUntil { await covers.fetchRequests.count == 2 }
    let started = await progress.next()
    await coordinator.setSuspended(true)
    await covers.releaseFetches()
    await waitUntil { await covers.inFlightCount == 0 }

    #expect(await covers.fetchRequests.count == 2)
    var pausedProgress = (await coordinator.progress).makeAsyncIterator()
    #expect(await pausedProgress.next() == started)
    await coordinator.setSuspended(false)
    #expect((await run.value).finished)
    #expect(await covers.fetchRequests.count == 12)
  }

  @Test("a second run joins the in-flight pass")
  func secondRunJoinsInFlightPass() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1", "item-2", "item-3", "item-4"])
    let covers = FakeCoverCacheFilling(holdFetches: true)
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)
    let first = Task { await coordinator.runAll() }

    await waitUntil { await covers.fetchRequests.count == 2 }
    let second = Task { await coordinator.runAll() }
    await covers.releaseFetches()

    let outcomes = await [first.value, second.value]
    #expect(outcomes[0] == outcomes[1])
    #expect(await covers.fetchRequests.count == 12)
  }

  @Test("a completed run is idempotent")
  func completedRunIsIdempotent() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1", "item-2", "item-3"])
    let covers = FakeCoverCacheFilling()
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    let first = await coordinator.runAll()
    let second = await coordinator.runAll()

    #expect(first.fetched == 3)
    #expect(second == CoverCacheRunOutcome(fetched: 0, alreadyPresent: 3, failed: 0, finished: true))
    #expect(await covers.fetchRequests.count == 9)
  }

  @Test("top up runs the pass on an unconstrained path with nothing configured")
  func topUpRunsOnAnUnconstrainedPath() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1"])
    let covers = FakeCoverCacheFilling()
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    let outcome = await coordinator.topUp()

    #expect(outcome.fetched == 1)
    #expect(await covers.fetchRequests.count == 3)
  }

  @Test("top up is constrained to Wi-Fi while a manual run is allowed")
  func topUpIsConstrainedToWiFiButManualRunIsAllowed() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1"])
    let covers = FakeCoverCacheFilling()
    let coordinator = Self.makeCoordinator(
      database: fixture.database, covers: covers, constrainedOrCellular: true)

    let topUpOutcome = await coordinator.topUp()
    let manualOutcome = await coordinator.runAll()

    #expect(topUpOutcome == CoverCacheRunOutcome(fetched: 0, alreadyPresent: 0, failed: 0, finished: false))
    #expect(manualOutcome.fetched == 1)
    #expect(await covers.fetchRequests.count == 3)
  }

  @Test("progress replays to late subscribers and multicasts updates")
  func progressReplaysAndMulticasts() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1", "item-2", "item-3", "item-4"])
    let covers = FakeCoverCacheFilling(holdFetches: true)
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)
    var first = (await coordinator.progress).makeAsyncIterator()
    var second = (await coordinator.progress).makeAsyncIterator()

    let initialFirst = await first.next()
    let initialSecond = await second.next()
    let run = Task { await coordinator.runAll() }
    await waitUntil { await covers.fetchRequests.count == 2 }
    let startedFirst = await first.next()
    let startedSecond = await second.next()
    var late = (await coordinator.progress).makeAsyncIterator()
    let lateReplay = await late.next()

    await covers.releaseFetches()
    _ = await run.value

    var firstUpdates: [CoverCacheProgress] = []
    while let update = await first.next() {
      firstUpdates.append(update)
      if update.isRunning == false { break }
    }
    var secondUpdates: [CoverCacheProgress] = []
    while let update = await second.next() {
      secondUpdates.append(update)
      if update.isRunning == false { break }
    }
    var lateUpdates: [CoverCacheProgress] = []
    while let update = await late.next() {
      lateUpdates.append(update)
      if update.isRunning == false { break }
    }

    #expect(initialFirst == initialSecond)
    #expect(startedFirst == startedSecond)
    #expect(lateReplay == startedFirst)
    #expect(firstUpdates == secondUpdates)
    #expect(lateUpdates == firstUpdates)
    #expect(firstUpdates.last?.isRunning == false)
  }

  @Test("census counts cache presence without fetching, including an empty library")
  func censusCountsPresenceWithoutFetchingIncludingEmptyLibrary() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1", "item-2", "item-3"])
    let covers = FakeCoverCacheFilling(
      presentKeys: Self.allArtworkKeys(for: ["item-1", "item-3"]))
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    let census = await coordinator.census()

    #expect(census == ItemDAO.MetadataCensus(covered: 2, total: 3))
    #expect(await covers.fetchRequests.isEmpty)
    #expect(await covers.presenceRequests.count == 9)
    #expect(await covers.dataRequests.isEmpty)

    let emptyFixture = try await Self.makeFixture(itemIDs: [])
    let emptyCovers = FakeCoverCacheFilling()
    let emptyCoordinator = Self.makeCoordinator(
      database: emptyFixture.database, covers: emptyCovers)

    #expect(await emptyCoordinator.census() == ItemDAO.MetadataCensus(covered: 0, total: 0))
    #expect(await emptyCovers.fetchRequests.isEmpty)
  }

  // MARK: Cover shape

  @Test("a portrait cover is measured from its card and fetched at the width its shape needs")
  func portraitCoverIsFetchedAtItsFittedWidth() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["portrait", "square"])
    let covers = FakeCoverCacheFilling(aspectRatios: ["portrait": 2.0 / 3.0])
    let shapes = Self.makeShapes()
    let coordinator = Self.makeCoordinator(
      database: fixture.database, covers: covers, shapes: shapes)

    let outcome = await coordinator.runAll()

    #expect(outcome == CoverCacheRunOutcome(fetched: 2, alreadyPresent: 0, failed: 0, finished: true))
    let detailWidths = await covers.fetchRequests.filter { $0.variant.pixelWidth > 420 }
      .map { "\($0.itemID):\($0.variant.pixelWidth)" }
    #expect(Set(detailWidths) == ["portrait:660", "square:900"])
    #expect(
      shapes.index.shape(itemID: "portrait", revision: .unversioned)
        == CoverShape(aspectRatio: 660.0 / 990.0, fitPixelWidth: 660))
    let stored = try await CoverShapeRecordStore(database: fixture.database).fetchAll()
    #expect(Set(stored.map(\.itemId)) == ["portrait", "square"])
    #expect(await coordinator.census() == ItemDAO.MetadataCensus(covered: 2, total: 2))

    let requests = await covers.fetchRequests.count
    let second = await coordinator.runAll()
    #expect(second == CoverCacheRunOutcome(fetched: 0, alreadyPresent: 2, failed: 0, finished: true))
    #expect(await covers.fetchRequests.count == requests)
  }

  @Test("a recorded shape survives into a new coordinator and is not measured again")
  func recordedShapeIsLoadedFromTheTable() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["portrait"])
    let covers = FakeCoverCacheFilling(aspectRatios: ["portrait": 2.0 / 3.0])
    _ = await Self.makeCoordinator(
      database: fixture.database, covers: covers, shapes: Self.makeShapes()
    ).runAll()

    let shapes = Self.makeShapes()
    let relaunched = Self.makeCoordinator(
      database: fixture.database, covers: covers, shapes: shapes)
    let requests = await covers.fetchRequests.count
    let outcome = await relaunched.runAll()

    #expect(outcome == CoverCacheRunOutcome(fetched: 0, alreadyPresent: 1, failed: 0, finished: true))
    #expect(await covers.fetchRequests.count == requests)
    #expect(shapes.index.shape(itemID: "portrait", revision: .unversioned)?.fitPixelWidth == 660)
  }

  @Test("a card with a replaced cover's shape is corrected from the fitted image")
  func staleCardShapeIsCorrectedFromTheFittedImage() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1"])
    let covers = FakeCoverCacheFilling(
      aspectRatios: ["item-1": 2.0 / 3.0], staleCardAspectRatios: ["item-1": 1])
    let shapes = Self.makeShapes()
    let coordinator = Self.makeCoordinator(
      database: fixture.database, covers: covers, shapes: shapes)

    _ = await coordinator.runAll()

    let detailWidths = await covers.fetchRequests.map(\.variant.pixelWidth).filter { $0 > 420 }
    #expect(detailWidths == [900, 660])
    #expect(shapes.index.shape(itemID: "item-1", revision: .unversioned)?.fitPixelWidth == 660)
  }

  @Test("no shape is recorded when the fitted cover could not be fetched")
  func failedFittedFetchRecordsNoShape() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1"])
    let fitted = ArtworkKey(
      accountScope: Self.accountScope, itemID: "item-1", variant: .detailFit(pixelWidth: 660),
      revision: .unversioned)
    let covers = FakeCoverCacheFilling(failingKeys: [fitted], aspectRatios: ["item-1": 2.0 / 3.0])
    let shapes = Self.makeShapes()
    let coordinator = Self.makeCoordinator(
      database: fixture.database, covers: covers, shapes: shapes)

    let outcome = await coordinator.runAll()

    #expect(outcome.failed == 1)
    #expect(shapes.index.shape(itemID: "item-1", revision: .unversioned) == nil)
    #expect(try await CoverShapeRecordStore(database: fixture.database).fetchAll().isEmpty)
    #expect(await covers.legacyRetirements == 0)
  }

  // MARK: Sweep

  @Test("a finished pass sweeps with every item as live and its own keys kept, then retires legacy")
  func finishedPassSweepsAndRetiresLegacy() async throws {
    let updatedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let fixture = try await Self.makeFixture(
      itemIDs: ["item-1", "item-2"], serverUpdatedAt: ["item-1": updatedAt])
    let covers = FakeCoverCacheFilling()
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    _ = await coordinator.runAll()

    let calls = await covers.pruneCalls
    #expect(calls.count == 1)
    #expect(
      calls.first?.live == [
        "item-1": ArtworkRevision(serverUpdatedAt: updatedAt), "item-2": .unversioned,
      ])
    #expect(calls.first?.keep == Set(await covers.fetchRequests))
    #expect(calls.first?.unlistedOlderThan == TimeInterval(2_592_000))
    #expect(calls.first?.byteCeiling == Int64(314_572_800))
    #expect(await covers.legacyRetirements == 1)
  }

  @Test("a pass with a failure still sweeps but leaves the legacy cache")
  func failedPassKeepsLegacyCache() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1", "item-2"])
    let covers = FakeCoverCacheFilling(failingKeys: [Self.key(itemID: "item-2")])
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    _ = await coordinator.runAll()

    #expect(await covers.pruneCalls.count == 1)
    #expect(await covers.legacyRetirements == 0)
  }

  @Test("the standalone sweep prunes without fetching")
  func standaloneSweepNeverFetches() async throws {
    let fixture = try await Self.makeFixture(itemIDs: ["item-1"])
    let covers = FakeCoverCacheFilling()
    let coordinator = Self.makeCoordinator(database: fixture.database, covers: covers)

    await coordinator.sweep()

    #expect(await covers.pruneCalls.count == 1)
    #expect(await covers.pruneCalls.first?.keep == Self.allArtworkKeys(for: ["item-1"]))
    #expect(await covers.fetchRequests.isEmpty)
    #expect(await covers.legacyRetirements == 0)
  }

  private static func makeShapes() -> CoverShapeMeasurement {
    CoverShapeMeasurement(
      index: CoverShapeIndex(),
      sizing: DetailArtworkSizing(
        fallbackDisplaySize: 272, heroSide: 300, previewEdge: 220, displayScale: 3),
      pixelSize: fakePixelSize)
  }

  private static func key(itemID: String) -> ArtworkKey {
    highFidelityKey(itemID: itemID)
  }

  private static func thumbnailKey(itemID: String) -> ArtworkKey {
    ArtworkKey(
      accountScope: accountScope,
      itemID: itemID,
      variant: .libraryThumbnail(pixelWidth: libraryThumbnailPixelWidth),
      revision: .unversioned)
  }

  private static func highFidelityKey(itemID: String) -> ArtworkKey {
    ArtworkKey(
      accountScope: accountScope,
      itemID: itemID,
      variant: .highFidelity(pixelWidth: highFidelityPixelWidth),
      revision: .unversioned)
  }

  private static func podcastEpisodeThumbnailKey(itemID: String) -> ArtworkKey {
    ArtworkKey(
      accountScope: accountScope,
      itemID: itemID,
      variant: .libraryThumbnail(pixelWidth: podcastEpisodeThumbnailPixelWidth),
      revision: .unversioned)
  }

  private static func homeCardKey(itemID: String) -> ArtworkKey {
    ArtworkKey(
      accountScope: accountScope,
      itemID: itemID,
      variant: .homeCard(pixelWidth: homeCardPixelWidth),
      revision: .unversioned)
  }

  private static func allArtworkKeys(for itemIDs: [String]) -> Set<ArtworkKey> {
    Set(
      itemIDs.flatMap { itemID in
        [thumbnailKey(itemID: itemID), highFidelityKey(itemID: itemID), homeCardKey(itemID: itemID)]
      })
  }

  private static func makeCoordinator(
    database: AppDatabase,
    covers: FakeCoverCacheFilling,
    constrainedOrCellular: Bool = false,
    shapes: CoverShapeMeasurement? = nil
  ) -> CoverCacheAllCoordinator {
    CoverCacheAllCoordinator(
      database: database,
      covers: covers,
      libraryThumbnailPixelWidth: libraryThumbnailPixelWidth,
      highFidelityPixelWidth: highFidelityPixelWidth,
      podcastEpisodeThumbnailPixelWidth: podcastEpisodeThumbnailPixelWidth,
      homeCardPixelWidth: homeCardPixelWidth,
      artworkScope: accountScope,
      shapes: shapes,
      isConstrainedOrCellular: { constrainedOrCellular },
      randomUnit: { 0 })
  }

  private static func runWithProgress(
    _ coordinator: CoverCacheAllCoordinator
  ) async -> (CoverCacheRunOutcome, [CoverCacheProgress]) {
    var progress = (await coordinator.progress).makeAsyncIterator()
    let run = Task { await coordinator.runAll() }
    var updates: [CoverCacheProgress] = []
    var hasStarted = false
    while let update = await progress.next() {
      if update.isRunning { hasStarted = true }
      guard hasStarted else { continue }
      updates.append(update)
      if update.isRunning == false { break }
    }
    return (await run.value, updates)
  }

  private static func makeFixture(
    itemIDs: [String], podcastItemIDs: Set<String> = [], serverUpdatedAt: [String: Date] = [:]
  ) async throws -> DatabaseFixture {
    let database = try AppDatabase.inMemory()
    let accountID = try await database.writeAsync { db -> Int64 in
      var account = AccountRecord(
        clientUUID: "client-fixture", serverBaseURL: "https://covers.example.test",
        serverUserId: "user-fixture", serverVersion: "2.35.1")
      try account.insert(db)
      return account.id!
    }
    let libraryID = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: accountID, serverLibraryId: "library-fixture", mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: database)
    for itemID in itemIDs {
      _ = try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: accountID, libraryId: libraryID, serverItemId: itemID,
          mediaKind: podcastItemIDs.contains(itemID) ? "podcast" : "book",
          title: itemID, sortTitle: itemID, serverUpdatedAt: serverUpdatedAt[itemID]))
    }
    return DatabaseFixture(database: database, accountID: accountID)
  }
}

private struct DatabaseFixture: Sendable {
  let database: AppDatabase
  let accountID: Int64
}

private enum FakeCoverCacheError: Error {
  case fetchFailed
}

private actor FetchReleaseGate {
  // A waiter whose task is cancelled while the gate is held throws; one that arrives after the
  // release passes, cancelled or not.
  private nonisolated let gate = TestGate<Result<Void, Error>>(label: "FetchReleaseGate wait")

  init() {
    gate.hold()
  }

  func wait() async throws {
    let gate = gate
    try await gate.pass(otherwise: {
      gate.isHeld ? .failure(CancellationError()) : .success(())
    }).get()
  }

  func release() {
    gate.release(.success(()))
  }
}

/// A stand-in image: its bytes are its pixel size as text, which `fakePixelSize` reads back.
private func fakeImage(width: Int, height: Int) -> Data { Data("\(width)x\(height)".utf8) }

private let fakePixelSize: @Sendable (Data) -> (width: Int, height: Int)? = { data in
  let parts = String(decoding: data, as: UTF8.self).split(separator: "x").compactMap { Int($0) }
  return parts.count == 2 ? (parts[0], parts[1]) : nil
}

private struct PruneCall: Sendable, Equatable {
  let live: [String: ArtworkRevision]
  let keep: Set<ArtworkKey>
  let unlistedOlderThan: TimeInterval
  let byteCeiling: Int64
}

private actor FakeCoverCacheFilling: CoverCacheFilling {
  private var presentKeys: Set<ArtworkKey>
  private let failingKeys: Set<ArtworkKey>
  private let notFoundKeys: Set<ArtworkKey>
  private let fetchGate: FetchReleaseGate?
  /// Width over height of each item's true cover; a square when absent.
  private let aspectRatios: [String: Double]
  /// Item IDs whose card image still has this stale shape, as the server's resized cache can.
  private let staleCardAspectRatios: [String: Double]
  private(set) var presenceRequests: [ArtworkKey] = []
  private(set) var dataRequests: [ArtworkKey] = []
  private(set) var fetchRequests: [ArtworkKey] = []
  private(set) var pruneCalls: [PruneCall] = []
  private(set) var legacyRetirements = 0
  private(set) var inFlightCount = 0
  private(set) var highWaterMark = 0

  init(
    presentKeys: Set<ArtworkKey> = [],
    failingKeys: Set<ArtworkKey> = [],
    notFoundKeys: Set<ArtworkKey> = [],
    holdFetches: Bool = false,
    aspectRatios: [String: Double] = [:],
    staleCardAspectRatios: [String: Double] = [:]
  ) {
    self.presentKeys = presentKeys
    self.failingKeys = failingKeys
    self.notFoundKeys = notFoundKeys
    self.aspectRatios = aspectRatios
    self.staleCardAspectRatios = staleCardAspectRatios
    fetchGate = holdFetches ? FetchReleaseGate() : nil
  }

  func contains(_ key: ArtworkKey) async -> Bool {
    presenceRequests.append(key)
    return presentKeys.contains(key)
  }

  func data(for key: ArtworkKey) async -> Data? {
    dataRequests.append(key)
    return presentKeys.contains(key) ? image(for: key) : nil
  }

  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    fetchRequests.append(key)
    inFlightCount += 1
    highWaterMark = max(highWaterMark, inFlightCount)
    defer { inFlightCount -= 1 }

    try await fetchGate?.wait()
    try Task.checkCancellation()
    if failingKeys.contains(key) {
      throw FakeCoverCacheError.fetchFailed
    }
    if notFoundKeys.contains(key) {
      throw APIError.notFound
    }
    presentKeys.insert(key)
    return CoverImageResult(data: image(for: key), contentType: "image/webp")
  }

  func pruneCachedArtwork(
    live: [String: ArtworkRevision], keep: [ArtworkKey], unlistedOlderThan: TimeInterval,
    byteCeiling: Int64, now: Date
  ) async -> CoverCachePruneSummary {
    pruneCalls.append(
      PruneCall(
        live: live, keep: Set(keep), unlistedOlderThan: unlistedOlderThan, byteCeiling: byteCeiling))
    return CoverCachePruneSummary()
  }

  func retireLegacyCache() async {
    legacyRetirements += 1
  }

  func releaseFetches() async {
    await fetchGate?.release()
  }

  private func image(for key: ArtworkKey) -> Data {
    var aspectRatio = aspectRatios[key.itemID] ?? 1
    if case .homeCard = key.variant, let stale = staleCardAspectRatios[key.itemID] {
      aspectRatio = stale
    }
    let width = key.variant.pixelWidth
    return fakeImage(width: width, height: Int((Double(width) / aspectRatio).rounded()))
  }
}
