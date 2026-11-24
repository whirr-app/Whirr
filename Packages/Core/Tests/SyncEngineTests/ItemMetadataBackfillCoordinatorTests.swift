import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

@Suite("Item metadata backfill coordinator")
struct ItemMetadataBackfillCoordinatorTests {

  @Test("missing expanded metadata is fetched and persisted through the shared mapping")
  func missingExpandedMetadataIsFetchedAndPersisted() async throws {
    let harness = try await MetadataBackfillHarness(
      itemIDs: ["item-book"],
      responses: [try Self.batchResponse(ids: ["item-book"], includeChapters: true)])

    await harness.coordinator.backfillOnePage()

    let item = try #require(try harness.fetchItem("item-book"))
    #expect(item.seriesName == "Series item-book")
    #expect(item.narratorName == "Narrator item-book")
    #expect(item.itemDescription == "Description item-book")
    #expect(item.expandedMetadataFetchedAt != nil)
    #expect(
      try harness.fetchChapters("item-book")
        == [
          StoredItemChapter(
            serverChapterId: 1, position: 0, start: 0, end: 10, title: "Opening"),
          StoredItemChapter(
            serverChapterId: 2, position: 1, start: 10, end: 25, title: "Closing"),
        ])
  }

  /// Schema v77 sends already-fetched audiobooks back through this pass, so the pass itself must
  /// store the companion-PDF set.
  @Test("the batch path stores an audiobook's companion PDFs")
  func theBatchPathStoresCompanionPDFs() async throws {
    var object = try Self.bookObject(id: "item-book", includeChapters: false)
    object["libraryFiles"] = [
      ["ino": "900", "metadata": ["filename": "Maps.pdf", "ext": ".pdf", "size": 40]]
    ]
    let response = HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try JSONSerialization.data(withJSONObject: ["libraryItems": [object]]))
    let harness = try await MetadataBackfillHarness(itemIDs: ["item-book"], responses: [response])

    await harness.coordinator.backfillOnePage()

    let supplements = try await ItemSupplementStore(
      database: harness.database, downloadRootURL: FileManager.default.temporaryDirectory
    ).supplements(itemId: "item-book")
    #expect(supplements.map(\.serverFileIno) == ["900"])
    #expect(supplements.first?.filename == "Maps.pdf")
  }

  @Test("uses sequential batches of fifty")
  func requestsAreChunkedAndSequential() async throws {
    let itemIDs = (0..<120).map { String(format: "item-%03d", $0) }
    let batches = itemIDs.chunked(into: 50)
    let harness = try await MetadataBackfillHarness(
      itemIDs: itemIDs,
      responses: try batches.map { try Self.batchResponse(ids: $0) })

    await harness.coordinator.backfillOnePage()

    let requests = await harness.http.requestsSnapshot()
    var requestedBatches: [[String]] = []
    for request in requests {
      requestedBatches.append(try Self.ids(in: request))
    }
    #expect(requestedBatches == batches)
    #expect(await harness.http.highWaterMark() == 1)
  }

  @Test("a two-hundred-id page makes one persistence call per server batch")
  func persistenceCallsMatchServerBatches() async throws {
    let itemIDs = (0..<200).map { String(format: "item-%03d", $0) }
    let persistor = RecordingBatchPersistor()
    let harness = try await MetadataBackfillHarness(
      itemIDs: itemIDs,
      persistor: persistor,
      responses: try itemIDs.chunked(into: 50).map { try Self.batchResponse(ids: $0) })

    await harness.coordinator.backfillOnePage()

    let calls = await persistor.callsSnapshot()
    #expect(calls.count == 4)
    #expect(calls.map(\.count) == [50, 50, 50, 50])
    #expect(calls.flatMap { $0.map(\.serverItemId) } == itemIDs)
  }

  @Test("the batch path persists every item's fields and chapters")
  func batchPersistsAllFieldsAndChapters() async throws {
    let itemIDs = (0..<50).map { String(format: "item-%03d", $0) }
    let harness = try await MetadataBackfillHarness(
      itemIDs: itemIDs,
      responses: [
        try Self.batchResponse(ids: itemIDs, includeChapters: true, includeEbookFile: true)
      ])

    await harness.coordinator.backfillOnePage()

    let expectedChapters = [
      StoredItemChapter(serverChapterId: 1, position: 0, start: 0, end: 10, title: "Opening"),
      StoredItemChapter(serverChapterId: 2, position: 1, start: 10, end: 25, title: "Closing"),
    ]
    for itemID in itemIDs {
      let item = try #require(try harness.fetchItem(itemID))
      #expect(item.seriesName == "Series \(itemID)")
      #expect(item.narratorName == "Narrator \(itemID)")
      #expect(item.itemDescription == "Description \(itemID)")
      #expect(item.ebookFileIno == "ino-\(itemID)")
      #expect(item.ebookFileExt == "epub")
      #expect(item.expandedMetadataFetchedAt != nil)
      #expect(try harness.fetchChapters(itemID) == expectedChapters)
    }
  }

  @Test("podcasts and already-backfilled items are never requested")
  func skipsPodcastsAndCoveredItems() async throws {
    let harness = try await MetadataBackfillHarness(
      itemIDs: ["item-missing", "item-covered"],
      backfilledIDs: ["item-covered"],
      podcastIDs: ["show-podcast"],
      responses: [try Self.batchResponse(ids: ["item-missing"])])

    await harness.coordinator.backfillAll()

    let requests = await harness.http.requestsSnapshot()
    #expect(requests.count == 1)
    #expect(try Self.ids(in: try #require(requests.first)) == ["item-missing"])
  }

  /// An item the server changed after its last expand is fetched again, which is the only way a
  /// replaced file's identity ever reaches the local row.
  @Test("an item the server changed since its last expand is refetched")
  func serverChangedItemIsRefetched() async throws {
    let harness = try await MetadataBackfillHarness(
      itemIDs: ["item-rescanned", "item-unchanged"],
      backfilledIDs: ["item-rescanned", "item-unchanged"],
      serverUpdatedAtByID: [
        "item-rescanned": Date(timeIntervalSince1970: 1_699_999_500),
        "item-unchanged": Date(timeIntervalSince1970: 1_699_998_500),
      ],
      responses: [try Self.batchResponse(ids: ["item-rescanned"])])

    await harness.coordinator.backfillAll()

    let requests = await harness.http.requestsSnapshot()
    #expect(requests.count == 1)
    #expect(try Self.ids(in: try #require(requests.first)) == ["item-rescanned"])
    #expect(try harness.fetchItem("item-rescanned")?.seriesName == "Series item-rescanned")
  }

  /// A server dated ahead of this device stays stale however often it is fetched: its
  /// `updatedAt` is still in the future when the refreshed `fetchedAt` is written. `backfillAll`
  /// loops until SQL reports nothing owed, so without a per-pass ledger that item would be
  /// requested forever.
  @Test("an item dated ahead of the device clock is fetched once per pass, not forever")
  func futureDatedItemDoesNotLoopWithinOnePass() async throws {
    let harness = try await MetadataBackfillHarness(
      itemIDs: ["item-future"],
      backfilledIDs: ["item-future"],
      serverUpdatedAtByID: ["item-future": Date(timeIntervalSince1970: 1_800_000_000)],
      responses: [
        try Self.batchResponse(ids: ["item-future"]),
        try Self.batchResponse(ids: ["item-future"]),
        try Self.batchResponse(ids: ["item-future"]),
      ])

    await harness.coordinator.backfillAll()

    #expect((await harness.http.requestsSnapshot()).count == 1)
  }

  @Test("one page is limited to two hundred ids while backfillAll continues")
  func onePageStopsAtBudgetAndAllContinues() async throws {
    let itemIDs = (0..<250).map { String(format: "item-%03d", $0) }
    let firstPage = itemIDs.chunked(into: 50).prefix(4)
    let remaining = Array(itemIDs.dropFirst(200)).chunked(into: 50)
    let harness = try await MetadataBackfillHarness(
      itemIDs: itemIDs,
      responses: try (firstPage + remaining).map { try Self.batchResponse(ids: $0) })

    await harness.coordinator.backfillOnePage()
    #expect((await harness.http.requestsSnapshot()).count == 4)
    #expect((await harness.coordinator.census()) == ItemDAO.MetadataCensus(covered: 200, total: 250))

    await harness.coordinator.backfillAll()
    #expect((await harness.http.requestsSnapshot()).count == 5)
    #expect((await harness.coordinator.census()) == ItemDAO.MetadataCensus(covered: 250, total: 250))
  }

  @Test("a completed backfill is idempotent")
  func secondCompletePassIssuesNoRequests() async throws {
    let harness = try await MetadataBackfillHarness(
      itemIDs: ["item-book"],
      responses: [try Self.batchResponse(ids: ["item-book"])])

    await harness.coordinator.backfillAll()
    await harness.coordinator.backfillAll()

    #expect((await harness.http.requestsSnapshot()).count == 1)
  }

  @Test("a failed batch schedules backoff and resumes after the window")
  func failureSchedulesBackoffAndLaterCallResumes() async throws {
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000))
    let harness = try await MetadataBackfillHarness(
      itemIDs: ["item-book"],
      clock: clock,
      responses: [HTTPResponse(statusCode: 500, headers: [:], body: Data())])

    await harness.coordinator.backfillAll()
    await harness.coordinator.backfillAll()
    #expect((await harness.http.requestsSnapshot()).count == 1)

    clock.advance(by: BackoffPolicy.baseDelay)
    await harness.http.enqueue(try Self.batchResponse(ids: ["item-book"]))
    await harness.coordinator.backfillAll()

    #expect((await harness.http.requestsSnapshot()).count == 2)
    let item = try #require(try harness.fetchItem("item-book"))
    #expect(item.expandedMetadataFetchedAt != nil)
  }

  @Test("a database failure does not schedule API backoff")
  func databaseFailureDoesNotScheduleBackoff() async throws {
    let persistor = RecordingBatchPersistor(failOnCall: 1)
    let harness = try await MetadataBackfillHarness(
      itemIDs: ["item-book"],
      persistor: persistor,
      responses: [
        try Self.batchResponse(ids: ["item-book"]),
        try Self.batchResponse(ids: ["item-book"]),
      ])

    await harness.coordinator.backfillOnePage()
    await harness.coordinator.backfillOnePage()

    #expect((await harness.http.requestsSnapshot()).count == 2)
  }

  @Test("an API failure after a database failure still schedules backoff")
  func apiFailureStillSchedulesBackoffAfterDatabaseFailure() async throws {
    let persistor = RecordingBatchPersistor(failOnCall: 1)
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000))
    let harness = try await MetadataBackfillHarness(
      itemIDs: ["item-book"],
      clock: clock,
      randomSource: { 1 },
      persistor: persistor,
      responses: [
        try Self.batchResponse(ids: ["item-book"]),
        HTTPResponse(statusCode: 500, headers: [:], body: Data()),
      ])

    await harness.coordinator.backfillOnePage()
    await harness.coordinator.backfillOnePage()
    await harness.coordinator.backfillOnePage()

    #expect((await harness.http.requestsSnapshot()).count == 2)
  }

  @Test("a failed commit remains eligible on the next pass")
  func failedCommitIsNotSkippedOnNextPass() async throws {
    let itemIDs = (0..<100).map { String(format: "item-%03d", $0) }
    let batches = itemIDs.chunked(into: 50)
    let persistor = RecordingBatchPersistor(failOnCall: 2)
    let harness = try await MetadataBackfillHarness(
      itemIDs: itemIDs,
      persistor: persistor,
      responses: try batches.map { try Self.batchResponse(ids: $0) }
        + [try Self.batchResponse(ids: batches[1])])

    await harness.coordinator.backfillOnePage()
    await harness.coordinator.backfillOnePage()

    let requests = await harness.http.requestsSnapshot()
    #expect(requests.count == 3)
    #expect(try Self.ids(in: requests[1]) == Array(itemIDs[50..<100]))
    #expect(try Self.ids(in: requests[2]) == Array(itemIDs[50..<100]))
    #expect((await harness.coordinator.census()) == ItemDAO.MetadataCensus(covered: 100, total: 100))
  }

  @Test("backfillAll uses the same one-call-per-server-batch path")
  func backfillAllUsesBatchPersistence() async throws {
    let itemIDs = (0..<200).map { String(format: "item-%03d", $0) }
    let persistor = RecordingBatchPersistor()
    let harness = try await MetadataBackfillHarness(
      itemIDs: itemIDs,
      persistor: persistor,
      responses: try itemIDs.chunked(into: 50).map { try Self.batchResponse(ids: $0) })

    await harness.coordinator.backfillAll()

    let calls = await persistor.callsSnapshot()
    #expect(calls.count == 4)
    #expect(calls.allSatisfy { $0.count == 50 })
  }

  @Test("cancellation stops between batches and keeps the completed batch")
  func cancellationStopsBetweenBatches() async throws {
    let itemIDs = (0..<100).map { String(format: "item-%03d", $0) }
    let harness = try await MetadataBackfillHarness(
      itemIDs: itemIDs,
      blockFromRequestNumber: 2,
      responses: try itemIDs.chunked(into: 50).map { try Self.batchResponse(ids: $0) })

    let run = Task { await harness.coordinator.backfillAll() }
    #expect(
      await TestSupport.waitUntil { await harness.http.requestCount() == 2 },
      "the second batch should be the cancellation boundary")
    run.cancel()
    await harness.http.releaseBlockedRequests()
    await run.value

    #expect((await harness.coordinator.census()) == ItemDAO.MetadataCensus(covered: 50, total: 100))
  }

  @Test("cancellation between committed batches prevents the next request")
  func cancellationBetweenBatchesPreventsNextRequest() async throws {
    let itemIDs = (0..<100).map { String(format: "item-%03d", $0) }
    let persistor = RecordingBatchPersistor(blockFromCall: 1, blockBeforePersist: false)
    let harness = try await MetadataBackfillHarness(
      itemIDs: itemIDs,
      persistor: persistor,
      responses: try itemIDs.chunked(into: 50).map { try Self.batchResponse(ids: $0) })

    let run = Task { await harness.coordinator.backfillAll() }
    #expect(
      await TestSupport.waitUntil { await persistor.blockedCallCount() == 1 },
      "the first committed batch should be the cancellation boundary")
    run.cancel()
    await persistor.releaseBlockedCalls()
    await run.value

    #expect((await harness.http.requestsSnapshot()).count == 1)
    #expect((await harness.coordinator.census()) == ItemDAO.MetadataCensus(covered: 50, total: 100))
  }

  @Test("cancellation after a returned batch still commits the whole batch")
  func cancellationAfterReturnedBatchDoesNotHalfPersist() async throws {
    let itemIDs = (0..<50).map { String(format: "item-%03d", $0) }
    let persistor = RecordingBatchPersistor(blockFromCall: 1, blockBeforePersist: true)
    let harness = try await MetadataBackfillHarness(
      itemIDs: itemIDs,
      persistor: persistor,
      responses: [try Self.batchResponse(ids: itemIDs)])

    let run = Task { await harness.coordinator.backfillOnePage() }
    #expect(
      await TestSupport.waitUntil { await persistor.blockedCallCount() == 1 },
      "the returned batch should be held as one persistence unit")
    run.cancel()
    await persistor.releaseBlockedCalls()
    await run.value

    #expect((await harness.coordinator.census()) == ItemDAO.MetadataCensus(covered: 50, total: 50))
  }

  @Test("concurrent backfill calls share one pass")
  func concurrentCallsAreNonReentrant() async throws {
    let harness = try await MetadataBackfillHarness(
      itemIDs: (0..<50).map { String(format: "item-%03d", $0) },
      blockFromRequestNumber: 1,
      responses: [try Self.batchResponse(ids: (0..<50).map { String(format: "item-%03d", $0) })])

    let first = Task { await harness.coordinator.backfillAll() }
    #expect(
      await TestSupport.waitUntil { await harness.http.blockedRequestCount() == 1 },
      "the first pass should be held before the second call arrives")
    let second = Task { await harness.coordinator.backfillAll() }
    await TestSupport.awaitQuiescence(
      "the shared metadata pass to remain single",
      of: {
        let requests = await harness.http.requestCount()
        let blocked = await harness.http.blockedRequestCount()
        let highWaterMark = await harness.http.highWaterMark()
        return "requests \(requests), blocked \(blocked), high-water \(highWaterMark)"
      })
    await harness.http.releaseBlockedRequests()
    await first.value
    await second.value

    #expect((await harness.http.requestsSnapshot()).count == 1)
    #expect(await harness.http.highWaterMark() == 1)
  }

  @Test("census reports covered and total movement")
  func censusReportsMovement() async throws {
    let harness = try await MetadataBackfillHarness(
      itemIDs: ["item-one", "item-two"],
      responses: [try Self.batchResponse(ids: ["item-one", "item-two"])])

    #expect(await harness.coordinator.census() == ItemDAO.MetadataCensus(covered: 0, total: 2))
    await harness.coordinator.backfillAll()
    #expect(await harness.coordinator.census() == ItemDAO.MetadataCensus(covered: 2, total: 2))
  }

  @Test("an omitted server item does not make backfillAll loop")
  func omittedServerItemIsNotRetriedForever() async throws {
    let harness = try await MetadataBackfillHarness(
      itemIDs: ["deleted-item"],
      responses: [try Self.batchResponse(ids: [])])

    await harness.coordinator.backfillAll()

    #expect((await harness.http.requestsSnapshot()).count == 1)
  }

  private static func batchResponse(
    ids: [String], includeChapters: Bool = false, includeEbookFile: Bool = false
  ) throws -> HTTPResponse {
    let libraryItems = try ids.map {
      try bookObject(
        id: $0, includeChapters: includeChapters, includeEbookFile: includeEbookFile)
    }
    return HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: try JSONSerialization.data(withJSONObject: ["libraryItems": libraryItems]))
  }

  private static func bookObject(
    id: String, includeChapters: Bool, includeEbookFile: Bool = false
  ) throws -> [String: Any] {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded"))
        as? [String: Any])
    object["id"] = id
    var media = try #require(object["media"] as? [String: Any])
    var metadata = try #require(media["metadata"] as? [String: Any])
    metadata["seriesName"] = "Series " + id
    metadata["narratorName"] = "Narrator " + id
    metadata["description"] = "Description " + id
    media["metadata"] = metadata
    media["duration"] = 25
    media["chapters"] =
      includeChapters
      ? [
        ["id": 1, "start": 0, "end": 10, "title": "Opening"],
        ["id": 2, "start": 10, "end": 25, "title": "Closing"],
      ]
      : []
    if includeEbookFile {
      media["ebookFile"] = [
        "ino": "ino-\(id)",
        "metadata": ["ext": ".EPUB", "filename": "\(id).epub", "size": 100],
      ]
    }
    object["media"] = media
    return object
  }

  private static func ids(in request: HTTPRequest) throws -> [String] {
    let body = try #require(request.body)
    let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    return try #require(object["libraryItemIds"] as? [String])
  }
}

private final class MetadataBackfillHarness: @unchecked Sendable {
  let database: AppDatabase
  let accountID: Int64
  let http: RecordingBatchHTTPClient
  let coordinator: ItemMetadataBackfillCoordinator

  init(
    itemIDs: [String],
    backfilledIDs: Set<String> = [],
    serverUpdatedAtByID: [String: Date] = [:],
    podcastIDs: [String] = [],
    clock: FakeSyncClock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000)),
    blockFromRequestNumber: Int? = nil,
    randomSource: @escaping @Sendable () -> Double = { 1 },
    persistor: RecordingBatchPersistor? = nil,
    responses: [HTTPResponse]
  ) async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://metadata.example.test")))
    let clientUUID = "metadata-client"
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    let database = try AppDatabase.inMemory()
    let accountID = try await database.writeAsync { db -> Int64 in
      var accountRecord = AccountRecord(
        clientUUID: clientUUID,
        serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture",
        serverVersion: "2.35.1")
      try accountRecord.insert(db)

      var bookLibrary = LibraryRecord(
        accountId: try #require(accountRecord.id),
        serverLibraryId: "books",
        mediaType: "book",
        name: "Books")
      try bookLibrary.insert(db)
      let bookLibraryID = try #require(bookLibrary.id)
      let fetchedAt = Date(timeIntervalSince1970: 1_699_999_000)
      for (index, itemID) in itemIDs.enumerated() {
        let title = String(format: "Title %03d", index)
        var item = ItemRecord(
          accountId: try #require(accountRecord.id),
          libraryId: bookLibraryID,
          serverItemId: itemID,
          mediaKind: "book",
          title: title,
          sortTitle: title,
          expandedMetadataFetchedAt: backfilledIDs.contains(itemID) ? fetchedAt : nil,
          serverUpdatedAt: serverUpdatedAtByID[itemID])
        try item.insert(db)
      }

      if podcastIDs.isEmpty == false {
        var podcastLibrary = LibraryRecord(
          accountId: try #require(accountRecord.id),
          serverLibraryId: "podcasts",
          mediaType: "podcast",
          name: "Podcasts")
        try podcastLibrary.insert(db)
        let podcastLibraryID = try #require(podcastLibrary.id)
        for itemID in podcastIDs {
          var item = ItemRecord(
            accountId: try #require(accountRecord.id),
            libraryId: podcastLibraryID,
            serverItemId: itemID,
            mediaKind: ItemMediaCategory.podcast.rawValue,
            title: "Podcast (index)",
            sortTitle: "Podcast (index)")
          try item.insert(db)
        }
      }
      return try #require(accountRecord.id)
    }

    let http = RecordingBatchHTTPClient(
      responses: responses, blockFromRequestNumber: blockFromRequestNumber)
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    self.database = database
    self.accountID = accountID
    self.http = http
    if let persistor {
      await persistor.setDownstream(ExpandedItemPersistor(database: database))
      self.coordinator = ItemMetadataBackfillCoordinator(
        database: database,
        client: client,
        clock: clock,
        randomSource: randomSource,
        persistor: persistor)
    } else {
      self.coordinator = ItemMetadataBackfillCoordinator(
        database: database, client: client, clock: clock, randomSource: randomSource)
    }
  }

  func fetchItem(_ serverItemID: String) throws -> ItemRecord? {
    try ItemDAO(database: database).fetchOne(accountId: accountID, serverItemId: serverItemID)
  }

  func fetchChapters(_ serverItemID: String) throws -> [StoredItemChapter] {
    let item = try #require(try fetchItem(serverItemID))
    return try ItemChapterStore(database: database).fetch(
      accountId: accountID, itemId: try #require(item.id))
  }
}

private enum MetadataPersistorTestError: Error, Sendable {
  case forcedFailure
}

private actor RecordingBatchPersistor: ExpandedItemBatchPersisting {
  private var calls: [[ExpandedItemBatchEntry]] = []
  private var downstream: (any ExpandedItemBatchPersisting)?
  private let failOnCall: Int?
  private let blockFromCall: Int?
  private let blockBeforePersist: Bool
  // Always held: `blockFromCall` decides which calls park. A parked call stays parked through
  // task cancellation until `releaseBlockedCalls()`.
  private let gate = TestGate<Void>(
    label: "RecordingBatchPersistor persist", ignoresCancellation: true)

  init(
    failOnCall: Int? = nil,
    blockFromCall: Int? = nil,
    blockBeforePersist: Bool = true
  ) {
    self.failOnCall = failOnCall
    self.blockFromCall = blockFromCall
    self.blockBeforePersist = blockBeforePersist
    gate.hold()
  }

  func setDownstream(_ downstream: any ExpandedItemBatchPersisting) {
    self.downstream = downstream
  }

  func persist(
    _ entries: [ExpandedItemBatchEntry], accountId: Int64, fetchedAt: Date
  ) async throws {
    calls.append(entries)
    let callNumber = calls.count
    if blockFromCall.map({ callNumber >= $0 && blockBeforePersist }) == true {
      await gate.pass()
    }
    if failOnCall == callNumber {
      throw MetadataPersistorTestError.forcedFailure
    }
    try await downstream?.persist(entries, accountId: accountId, fetchedAt: fetchedAt)
    if blockFromCall.map({ callNumber >= $0 && blockBeforePersist == false }) == true {
      await gate.pass()
    }
  }

  func callsSnapshot() -> [[ExpandedItemBatchEntry]] { calls }

  func blockedCallCount() -> Int { gate.parkedCount }

  func releaseBlockedCalls() {
    gate.releaseParked()
  }
}

// Stays: tests assert its in-flight high-water mark, which FakeHTTPClient does not track.
private actor RecordingBatchHTTPClient: HTTPClienting {
  private var responses: [HTTPResponse]
  private var requests: [HTTPRequest] = []
  private var inFlight = 0
  private var maximumInFlight = 0
  private var blockFromRequestNumber: Int?
  private var blockedEntered = 0
  private var blockedFreed = 0
  // Always held: `blockFromRequestNumber` decides which requests park. A parked request stays
  // parked through task cancellation until `releaseBlockedRequests()`.
  private let gate = TestGate<Void>(
    label: "RecordingBatchHTTPClient send", ignoresCancellation: true)

  init(responses: [HTTPResponse], blockFromRequestNumber: Int? = nil) {
    self.responses = responses
    self.blockFromRequestNumber = blockFromRequestNumber
    gate.hold()
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requests.append(request)
    inFlight += 1
    maximumInFlight = max(maximumInFlight, inFlight)
    defer { inFlight -= 1 }

    if let blockFromRequestNumber,
      requests.count >= blockFromRequestNumber
    {
      blockedEntered += 1
      await gate.pass()
      try Task.checkCancellation()
    }

    guard responses.isEmpty == false else { throw APIError.transport }
    return responses.removeFirst()
  }

  func enqueue(_ response: HTTPResponse) {
    responses.append(response)
  }

  func releaseBlockedRequests() async {
    blockFromRequestNumber = nil
    // A blocked request is counted just before it parks; wait for every one to park.
    let owed = blockedEntered - blockedFreed
    blockedFreed = blockedEntered
    if owed > 0 { await gate.waitUntilParked(count: owed) }
    gate.releaseParked()
  }

  func requestsSnapshot() -> [HTTPRequest] { requests }
  func requestCount() -> Int { requests.count }
  func highWaterMark() -> Int { maximumInFlight }
  func blockedRequestCount() -> Int { gate.parkedCount }
}

extension Array {
  fileprivate func chunked(into size: Int) -> [[Element]] {
    stride(from: 0, to: count, by: size).map { start in
      Array(self[start..<Swift.min(start + size, count)])
    }
  }
}
