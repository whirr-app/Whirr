import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `SyncEngine`'s library pull: durable run/page bookkeeping and generation stamping. Refresh
/// coalescing, two-pass deletion, failure backoff, and the persisted item projection are covered
/// by the sibling `LibraryRefresh*`/`LibraryPull*` suites.
@Suite("Library pull: run/page bookkeeping")
struct LibraryRefreshTests {

  @Test("reserved RSS item ids are dropped while the rest of a page completes normally")
  func reservedRSSItemIdsAreDroppedFromPulledPages() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowId = try #require(library.id)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(
      items: [
        (id: "rss:42", title: "Device RSS", author: nil),
        (id: "normal-item", title: "Normal", author: nil),
      ], total: 2, limit: 100, page: 0)

    await h.engine.refresh()

    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "rss:42") == nil)
    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "normal-item") != nil)
    let run = try #require(try h.fetchSyncRuns().last)
    #expect(run.state == .completed)
  }

  @Test("reserved RSS item ids are rejected case-insensitively")
  func reservedRSSItemIdsAreRejectedCaseInsensitively() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowId = try #require(library.id)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "RSS:42", title: "Device RSS", author: nil)], total: 1, limit: 100, page: 0)

    await h.engine.refresh()

    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "RSS:42") == nil)
    let run = try #require(try h.fetchSyncRuns().last)
    #expect(run.state == .completed)
  }

  @Test("an item id containing rss is persisted when it does not start with the reservation")
  func nonPrefixRSSItemIdIsPersisted() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowId = try #require(library.id)
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "xrss:42", title: "Normal", author: nil)], total: 1, limit: 100, page: 0)

    await h.engine.refresh()

    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "xrss:42") != nil)
  }

  @Test("a completed library pull fires one metadata backfill page")
  func completedLibraryPullFiresMetadataBackfillOnce() async throws {
    let harness = try await MetadataBackfillRefreshHarness(metadataBackfill: true)
    harness.enqueueBookRefresh(itemID: "item-book")

    await harness.engine.refresh()

    #expect(harness.http.requests.filter { $0.routeTemplate == "/api/items/batch/get" }.count == 1)
  }

  @Test("metadata backfill still fires when every podcast shelf is in backoff")
  func metadataBackfillSurvivesPodcastShelfBackoffReturn() async throws {
    let harness = try await MetadataBackfillRefreshHarness(
      metadataBackfill: true, recentEpisodes: true)
    harness.enqueueMixedRefreshWithFailedPodcastShelf(includeBatchResponse: false)
    await harness.engine.refresh()

    harness.enqueueMixedRefreshWithFailedPodcastShelf(includeBatchResponse: true)
    await harness.engine.refresh()

    #expect(harness.http.requests.filter { $0.routeTemplate == "/api/items/batch/get" }.count == 2)
    #expect(
      harness.http.requests.filter { $0.routeTemplate == "/api/libraries/:id/recent-episodes" }
        .count == 1)
  }

  @Test("a SyncEngine without metadata backfill keeps the existing refresh request sequence")
  func missingMetadataBackfillKeepsExistingRefreshSequence() async throws {
    let harness = try await MetadataBackfillRefreshHarness(metadataBackfill: false)
    harness.enqueueBookRefresh(itemID: "item-book")

    await harness.engine.refresh()

    #expect(harness.http.requests.count == 3)
    #expect(harness.http.requests.contains { $0.routeTemplate == "/api/items/batch/get" } == false)
  }

  @Test("a refresh creates a durable sync-run row: id, reason, timestamps, completion state, error category")
  func refreshCreatesADurableSyncRunRow() async throws {
    let h = try await Harness()
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "item1", title: "Title One", author: "Author One")], total: 1, limit: 100, page: 0)

    await h.engine.refresh()

    let run = try #require(try h.fetchSyncRuns().first)
    #expect(run.id != nil)
    #expect(run.reason == "explicit")
    #expect(run.completedAt != nil)
    #expect(run.state == .completed)
    #expect(run.errorCategory == nil)
    #expect(run.generation == 1)
    // Recorded so actual server capability can be verified later. Not itself proof the server
    // honours it.
    #expect(run.sortRequested == "id")
  }

  @Test("returned rows are marked with the run's generation")
  func returnedRowsAreMarkedWithTheRunGeneration() async throws {
    let h = try await Harness()
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(items: [(id: "item1", title: "Title", author: nil)], total: 1, limit: 100, page: 0)

    await h.engine.refresh()

    let library = try #require(try h.fetchLibrary(serverLibraryId: "lib1"))
    let libraryRowId = try #require(library.id)
    let item = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "item1"))
    let itemRowId = try #require(item.id)
    let run = try #require(try h.fetchSyncRuns().first)
    #expect(try h.fetchSeenGeneration(itemRowId: itemRowId) == run.generation)
  }

  @Test("sync runs and decode-diagnostic categories are recorded through DiagnosticsRecording")
  func syncRunAndDecodeDiagnosticsAreRecorded() async throws {
    let h = try await Harness()
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    let malformedObject: [String: Any] = [
      "results": [
        ["id": "valid-item", "media": ["metadata": ["title": "Valid"]]],
        ["media": ["metadata": ["title": "Missing Id"]]],
      ],
      "total": 2,
      "limit": 100,
      "page": 0,
    ]
    h.http.enqueue(Harness.jsonResponse(object: malformedObject))

    await h.engine.refresh()

    #expect(h.diagnostics.recorded.contains { $0.category == .syncRun })
    #expect(h.diagnostics.recorded.contains { $0.category == .decodeDiagnostic })
  }

  @Test("a backwards clock clamps sync-run diagnostic duration to zero")
  func backwardsClockClampsDiagnosticDurationToZero() async throws {
    let h = try await Harness(
      syncClock: FakeSyncClock(reading: [
        Date(timeIntervalSince1970: 100),
        Date(timeIntervalSince1970: 100),
        Date(timeIntervalSince1970: 100),
        Date(timeIntervalSince1970: 99),
      ]))
    h.enqueueLibraries([(id: "lib1", name: "Library One", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.enqueuePage(
      items: [(id: "item1", title: "Title One", author: nil)], total: 1, limit: 100, page: 0)

    await h.engine.refresh()

    let event = try #require(h.diagnostics.recorded.first { $0.category == .syncRun })
    #expect(event.durationMilliseconds == 0)
  }
}

private final class MetadataBackfillRefreshHarness: @unchecked Sendable {
  let http: FakeHTTPClient
  let engine: SyncEngine
  private let metadataBackfillEnabled: Bool

  init(metadataBackfill: Bool, recentEpisodes: Bool = false) async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://refresh.example.test")))
    let clientUUID = "refresh-client"
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      var accountRecord = AccountRecord(
        clientUUID: clientUUID,
        serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture",
        serverVersion: "2.35.1")
      try accountRecord.insert(db)
    }

    let http = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000))
    let metadataBackfillCoordinator =
      metadataBackfill
      ? ItemMetadataBackfillCoordinator(database: database, client: client, clock: clock)
      : nil
    let recentEpisodeCoordinator =
      recentEpisodes
      ? RecentEpisodeRefreshCoordinator(database: database, client: client)
      : nil

    self.http = http
    self.metadataBackfillEnabled = metadataBackfill
    self.engine = SyncEngine.make(
      client: client,
      database: database,
      diagnostics: FakeDiagnosticsRecording(),
      appLifecycle: FakeAppLifecycle(),
      clock: clock,
      recentEpisodes: recentEpisodeCoordinator,
      metadataBackfill: metadataBackfillCoordinator)
  }

  func enqueueBookRefresh(itemID: String) {
    http.enqueue(
      Harness.jsonResponse(
        object: [
          "libraries": [["id": "books", "name": "Books", "mediaType": "book"]]
        ]))
    http.enqueue(Harness.jsonResponse(object: ["mediaProgresses": []]))
    http.enqueue(
      Harness.jsonResponse(
        object: [
          "results": [
            [
              "id": itemID,
              "libraryId": "books",
              "mediaType": "book",
              "media": ["metadata": ["title": "Book"]],
            ]
          ],
          "total": 1,
          "limit": 100,
          "page": 0,
        ]))
    if metadataBackfillEnabled {
      http.enqueue(Self.batchResponse(itemID: itemID))
    }
  }

  func enqueueMixedRefreshWithFailedPodcastShelf(includeBatchResponse: Bool) {
    http.enqueue(
      Harness.jsonResponse(
        object: [
          "libraries": [
            ["id": "books", "name": "Books", "mediaType": "book"],
            ["id": "podcasts", "name": "Podcasts", "mediaType": "podcast"],
          ]
        ]))
    http.enqueue(Harness.jsonResponse(object: ["mediaProgresses": []]))
    http.enqueue(Self.bookPage(itemID: "item-book"))
    http.enqueue(Self.podcastPage(itemID: "show-podcast"))
    if includeBatchResponse {
      if metadataBackfillEnabled {
        http.enqueue(Self.batchResponse(itemID: "item-book"))
      }
    } else {
      http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))
      if metadataBackfillEnabled {
        http.enqueue(Self.emptyBatchResponse())
      }
    }
  }

  private static func bookPage(itemID: String) -> HTTPResponse {
    Harness.jsonResponse(
      object: [
        "results": [
          [
            "id": itemID,
            "libraryId": "books",
            "mediaType": "book",
            "media": ["metadata": ["title": "Book"]],
          ]
        ],
        "total": 1,
        "limit": 100,
        "page": 0,
      ])
  }

  private static func podcastPage(itemID: String) -> HTTPResponse {
    Harness.jsonResponse(
      object: [
        "results": [
          [
            "id": itemID,
            "libraryId": "podcasts",
            "mediaType": "podcast",
            "media": ["metadata": ["title": "Podcast"]],
          ]
        ],
        "total": 1,
        "limit": 100,
        "page": 0,
      ])
  }

  private static func batchResponse(itemID: String) -> HTTPResponse {
    var object =
      try! JSONSerialization.jsonObject(
        with: try! Fixtures.data(named: "book-item-expanded")) as! [String: Any]
    object["id"] = itemID
    return HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: ["libraryItems": [object]]))
  }

  private static func emptyBatchResponse() -> HTTPResponse {
    Harness.jsonResponse(object: ["libraryItems": []])
  }
}
