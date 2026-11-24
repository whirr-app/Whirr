import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

extension Harness {
  /// Enqueues a `GET /api/libraries/{id}/search` response with book/podcast-keyed hits carrying
  /// `libraryItem`/`matchKey`/`matchText`, the shape `SearchEndpointTests` uses on `ABSClient`.
  func enqueueSearchResponse(
    book: [(id: String, title: String, author: String?, matchKey: String?, matchText: String?)],
    podcast: [(id: String, title: String, author: String?, matchKey: String?, matchText: String?)]
  ) {
    http.enqueue(
      Harness.jsonResponse(
        object: [
          "book": book.map { bookOrPodcastHitObject(mediaType: "book", hit: $0) },
          "podcast": podcast.map { bookOrPodcastHitObject(mediaType: "podcast", hit: $0) },
        ]))
  }

  /// Like `enqueueSearchResponse`, but also carries the `authors`/`series` buckets (bare
  /// `{id, name}` shape, per `SearchAuthorHit`/`SearchSeriesHit`).
  func enqueueSearchResponseWithBuckets(
    book: [(id: String, title: String, author: String?, matchKey: String?, matchText: String?)] = [],
    podcast: [(id: String, title: String, author: String?, matchKey: String?, matchText: String?)] = [],
    authors: [(id: String, name: String?)] = [],
    series: [(id: String, name: String?)] = []
  ) {
    http.enqueue(
      Harness.jsonResponse(
        object: [
          "book": book.map { bookOrPodcastHitObject(mediaType: "book", hit: $0) },
          "podcast": podcast.map { bookOrPodcastHitObject(mediaType: "podcast", hit: $0) },
          "authors": authors.map { ["id": $0.id, "name": $0.name as Any] },
          "series": series.map {
            ["books": [[String: Any]](), "series": ["id": $0.id, "name": $0.name as Any]]
          },
        ]))
  }
}

private func bookOrPodcastHitObject(
  mediaType: String, hit: (id: String, title: String, author: String?, matchKey: String?, matchText: String?)
) -> [String: Any] {
  [
    "libraryItem": [
      "id": hit.id,
      "libraryId": "irrelevant",
      "mediaType": mediaType,
      "media": ["metadata": ["title": hit.title, "authorName": hit.author as Any]],
    ],
    "matchKey": hit.matchKey as Any,
    "matchText": hit.matchText as Any,
  ]
}

/// `SyncCoordinating.search(libraryIDs:query:limit:)` fans out across every library on an
/// account, admitted through the `ABSClient`-owned `ServerRequestGate` that every foreground
/// request shares (API-CONVENTIONS.md rule 13). A per-library failure is reported rather than
/// failing the whole search.
@Suite("Library search fan-out: bounded concurrency, partial failure, kind-tagged matches", .timeLimit(.minutes(1)))
struct LibrarySearchFanOutTests {

  @Test("reserved RSS item ids are neither upserted nor emitted as ABS matches")
  func reservedRSSSearchHitsAreDroppedAtTheBoundary() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowId = try #require(library.id)
    h.enqueueSearchResponse(
      book: [
        (id: "rss:42", title: "Device RSS", author: nil, matchKey: "title", matchText: "Device RSS"),
        (id: "xrss:42", title: "Ordinary Book", author: nil, matchKey: "title", matchText: "Ordinary Book"),
      ],
      podcast: [
        (id: "RSS:7", title: "Uppercase RSS", author: nil, matchKey: "title", matchText: "Uppercase RSS"),
        (id: "rss:007", title: "Malformed RSS", author: nil, matchKey: "title", matchText: "Malformed RSS"),
        (id: "podcast-1", title: "Ordinary Podcast", author: nil, matchKey: "title", matchText: "Ordinary Podcast"),
      ])

    let result = try await h.engine.search(libraryIDs: ["lib1"], query: "rss", limit: 25)

    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "rss:42") == nil)
    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "RSS:7") == nil)
    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "rss:007") == nil)
    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "xrss:42") != nil)
    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "podcast-1") != nil)
    #expect(result.matches.map(\.itemId) == ["xrss:42", "podcast-1"])
  }

  @Test("issues one request per library, never exceeds the concurrency cap, and groups results by library")
  func fansOutBoundedByGateGroupedByLibrary() async throws {
    let h = try await FanOutHarness(gateCap: 2)
    _ = try await h.seedLibrary(serverLibraryId: "lib1")
    _ = try await h.seedLibrary(serverLibraryId: "lib2")
    _ = try await h.seedLibrary(serverLibraryId: "lib3")

    await h.http.stub(
      libraryId: "lib1",
      response: Harness.jsonResponse(
        object: [
          "book": [
            bookOrPodcastHitObject(
              mediaType: "book", hit: ("b1a", "One A", nil, "title", "One A")),
            bookOrPodcastHitObject(
              mediaType: "book", hit: ("b1b", "One B", nil, "title", "One B")),
          ],
          "podcast": [],
        ]))
    await h.http.stub(
      libraryId: "lib2",
      response: Harness.jsonResponse(
        object: [
          "book": [bookOrPodcastHitObject(mediaType: "book", hit: ("b2a", "Two A", nil, "title", "Two A"))],
          "podcast": [],
        ]))
    await h.http.stub(
      libraryId: "lib3",
      response: Harness.jsonResponse(
        object: [
          "book": [bookOrPodcastHitObject(mediaType: "book", hit: ("b3a", "Three A", nil, "title", "Three A"))],
          "podcast": [],
        ]))
    await h.http.enableHold()

    let task = Task { try await h.engine.search(libraryIDs: nil, query: "q", limit: 25) }

    // With a cap of 2 and 3 libraries, the third request must not reach the transport until
    // one of the first two is released (rule 13).
    await TestSupport.waitUntil { await h.http.currentInFlightCount == 2 }
    #expect(await h.http.requestCount == 2)
    await h.http.releaseAll()

    await TestSupport.waitUntil { await h.http.requestCount == 3 }
    await h.http.releaseAll()

    let result = try await task.value

    #expect(await h.http.requestCount == 3)
    #expect(await h.http.maxObservedConcurrencyValue <= 2)
    #expect(result.failures.isEmpty)
    #expect(result.matches.map(\.libraryId) == ["lib1", "lib1", "lib2", "lib3"])
    #expect(result.matches.map(\.itemId) == ["b1a", "b1b", "b2a", "b3a"])
  }

  @Test("one library failing does not fail the whole search: the others' results return and the failure is reported")
  func oneLibraryFailingIsReportedNotThrown() async throws {
    let h = try await FanOutHarness()
    _ = try await h.seedLibrary(serverLibraryId: "lib1")
    _ = try await h.seedLibrary(serverLibraryId: "lib2")

    await h.http.stub(
      libraryId: "lib1",
      response: Harness.jsonResponse(
        object: [
          "book": [bookOrPodcastHitObject(mediaType: "book", hit: ("ok", "OK", nil, "title", "OK"))],
          "podcast": [],
        ]))
    await h.http.stub(libraryId: "lib2", response: HTTPResponse(statusCode: 500, headers: [:], body: Data()))

    let result = try await h.engine.search(libraryIDs: nil, query: "q", limit: 25)

    #expect(result.matches.map(\.itemId) == ["ok"])
    #expect(result.failures.map(\.libraryId) == ["lib2"])
  }

  @Test("matchKey/matchText survive into SearchMatch, including a narrator match")
  func matchKeyAndMatchTextSurviveIntoSearchMatch() async throws {
    let h = try await Harness()
    _ = try await h.seedLibrary(serverLibraryId: "lib1")

    h.enqueueSearchResponse(
      book: [(id: "audiobook-1", title: "A Book", author: nil, matchKey: "narrator", matchText: "Rob Inglis")],
      podcast: [])

    let result = try await h.engine.search(libraryIDs: ["lib1"], query: "rob", limit: 25)

    let hit = try #require(result.matches.first { $0.matchKey == "narrator" })
    #expect(hit.matchText == "Rob Inglis")
    #expect(hit.matchReason == SearchMatchReason(field: "narrator", text: "Rob Inglis"))
  }

  @Test("author and series hits become kind-tagged SearchMatch entries and are never upserted into item")
  func authorAndSeriesHitsAreKindTaggedAndNotUpserted() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "lib1")
    let libraryRowId = try #require(library.id)

    h.enqueueSearchResponseWithBuckets(
      authors: [(id: "author-1", name: "Neil Gaiman")],
      series: [(id: "series-1", name: "Sandman")])

    let result = try await h.engine.search(libraryIDs: ["lib1"], query: "gaiman", limit: 25)

    let authorMatch = try #require(result.matches.first { $0.kind == .author })
    #expect(authorMatch.itemId == "author-1")
    #expect(authorMatch.matchText == "Neil Gaiman")

    let seriesMatch = try #require(result.matches.first { $0.kind == .series })
    #expect(seriesMatch.itemId == "series-1")
    #expect(seriesMatch.matchText == "Sandman")

    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "author-1") == nil)
    #expect(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "series-1") == nil)
  }

  @Test("limit is forwarded per library and the ordered id list preserves per-library server order")
  func limitForwardedAndServerOrderPreserved() async throws {
    let h = try await Harness()
    _ = try await h.seedLibrary(serverLibraryId: "lib1")

    h.enqueueSearchResponse(
      book: [
        (id: "b2", title: "Second", author: nil, matchKey: "title", matchText: "Second"),
        (id: "b1", title: "First", author: nil, matchKey: "title", matchText: "First"),
      ],
      podcast: [(id: "p1", title: "Pod", author: nil, matchKey: "title", matchText: "Pod")])

    let result = try await h.engine.search(libraryIDs: ["lib1"], query: "x", limit: 7)

    // Server order is preserved (book bucket order, then podcast), never re-sorted.
    #expect(result.matches.map(\.itemId) == ["b2", "b1", "p1"])

    let sentRequest = try #require(h.http.requests.last)
    let components = try #require(URLComponents(url: sentRequest.url, resolvingAgainstBaseURL: false))
    #expect(components.queryItems?.first { $0.name == "limit" }?.value == "7")
  }

  @Test("a search-discovered podcast with no media type is not persisted as a book")
  func aSearchDiscoveredPodcastWithNoMediaTypeIsNotPersistedAsABook() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "podcast-library", mediaType: "podcast")
    let libraryRowId = try #require(library.id)
    h.enqueuePodcastSearchResponseWithoutMediaType(
      id: "podcast-1", title: "A Podcast", author: "A Publisher")

    let result = try await h.engine.search(libraryIDs: ["podcast-library"], query: "podcast", limit: 25)

    #expect(result.matches.map(\.kind) == [.podcast])
    let item = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "podcast-1"))
    #expect(item.mediaKind == "podcast")
    #expect(
      ItemMediaCategory.derive(
        mediaKind: item.mediaKind, numAudioFiles: item.numAudioFiles, ebookFormat: item.ebookFormat)
        == .podcast)
  }

  @Test("a search upsert keeps a podcast's traversed language")
  func aSearchUpsertKeepsAPodcastsTraversedLanguage() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "podcast-library", mediaType: "podcast")
    let libraryRowId = try #require(library.id)
    var seeded = try await h.seedItem(libraryRowId: libraryRowId, serverItemId: "podcast-1", generation: 1)
    seeded.mediaKind = "podcast"
    seeded.podcastLanguage = "en-GB"
    _ = try await ItemDAO(database: h.database).upsertAsync(seeded)

    h.enqueueSearchResponse(
      book: [],
      podcast: [(id: "podcast-1", title: "Pod", author: nil, matchKey: "title", matchText: "Pod")])
    _ = try await h.engine.search(libraryIDs: ["podcast-library"], query: "pod", limit: 25)

    let item = try #require(try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "podcast-1"))
    #expect(item.title == "Pod")
    #expect(item.podcastLanguage == "en-GB")
  }

  @Test("a search upsert does not clobber fields only traversal populates")
  func aSearchUpsertDoesNotClobberFieldsOnlyTraversalPopulates() async throws {
    let h = try await Harness()
    let library = try await h.seedLibrary(serverLibraryId: "book-library", mediaType: "book")
    let libraryRowId = try #require(library.id)
    let fetchedAt = Date(timeIntervalSince1970: 1_750_000_000)
    _ = try await h.seedItem(
      libraryRowId: libraryRowId,
      serverItemId: "item-1",
      generation: 1,
      seriesName: "Old Series",
      narratorName: "Old Narrator",
      expandedMetadataFetchedAt: fetchedAt,
      itemDescription: "A durable description")

    h.enqueueLibraries([(id: "book-library", name: "Books", mediaType: "book")])
    h.enqueueEmptyProgress()
    h.http.enqueue(
      Harness.jsonResponse(
        object: [
          "results": [
            [
              "id": "item-1",
              "libraryId": "irrelevant",
              "mediaType": "book",
              "addedAt": 1_750_000_100_000,
              "updatedAt": 1_750_000_200_000,
              "media": [
                "metadata": [
                  "title": "Traversed Title",
                  "authorName": "Traversed Author",
                  "seriesName": "Traversed Series",
                ],
                "duration": 3_600,
                "numAudioFiles": 4,
                "ebookFormat": "epub",
                "numEpisodes": 7,
              ],
            ]
          ],
          "total": 1,
          "limit": 100,
          "page": 0,
        ]))

    await h.engine.refresh()
    let beforeSearch = try #require(
      try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "item-1"))
    #expect(beforeSearch.itemDescription == "A durable description")
    #expect(beforeSearch.addedAt == Date(timeIntervalSince1970: 1_750_000_100))
    #expect(beforeSearch.numAudioFiles == 4)
    #expect(beforeSearch.ebookFormat == "epub")
    #expect(beforeSearch.seriesName == "Traversed Series")
    #expect(beforeSearch.narratorName == "Old Narrator")
    #expect(beforeSearch.expandedMetadataFetchedAt == fetchedAt)
    #expect(beforeSearch.serverUpdatedAt == Date(timeIntervalSince1970: 1_750_000_200))
    #expect(beforeSearch.podcastServerEpisodeCount == 7)
    let seenGenerationBeforeSearch = try h.fetchSeenGeneration(
      itemRowId: try #require(beforeSearch.id))

    h.enqueueSearchResponse(
      book: [
        (id: "item-1", title: "Search Title", author: "Search Author", matchKey: "title", matchText: "Search Title")
      ],
      podcast: [])
    _ = try await h.engine.search(libraryIDs: ["book-library"], query: "search", limit: 25)

    let afterSearch = try #require(
      try h.fetchItem(libraryRowId: libraryRowId, serverItemId: "item-1"))
    #expect(afterSearch.title == "Search Title")
    #expect(afterSearch.author == "Search Author")
    #expect(afterSearch.itemDescription == "A durable description")
    #expect(afterSearch.addedAt == Date(timeIntervalSince1970: 1_750_000_100))
    #expect(afterSearch.numAudioFiles == 4)
    #expect(afterSearch.ebookFormat == "epub")
    #expect(afterSearch.seriesName == "Traversed Series")
    #expect(afterSearch.narratorName == "Old Narrator")
    #expect(afterSearch.expandedMetadataFetchedAt == fetchedAt)
    #expect(afterSearch.serverUpdatedAt == Date(timeIntervalSince1970: 1_750_000_200))
    #expect(afterSearch.podcastServerEpisodeCount == 7)
    // Search writes no seen row, so it cannot disturb deletion inference.
    let itemRowId = try #require(beforeSearch.id)
    #expect(
      try h.fetchSeenGeneration(itemRowId: itemRowId) == seenGenerationBeforeSearch)
    #expect(afterSearch.softDeleted == beforeSearch.softDeleted)
  }
}

extension Harness {
  func enqueuePodcastSearchResponseWithoutMediaType(id: String, title: String, author: String) {
    http.enqueue(
      Harness.jsonResponse(
        object: [
          "book": [],
          "podcast": [
            [
              "libraryItem": [
                "id": id,
                "libraryId": "irrelevant",
                "media": ["metadata": ["title": title, "author": author]],
              ]
            ]
          ],
        ]))
  }
}

/// A minimal harness independent of the shared `Harness`. Its `FakeHTTPClient` is a single FIFO
/// response queue, blind to which concurrently dispatched request it is answering, which the
/// fan-out tests cannot assume. `RoutedConcurrencyTrackingHTTPClient` routes by the request's
/// library id and can hold every `send` open until released, so a test can observe real in-flight
/// overlap.
final class FanOutHarness: @unchecked Sendable {
  let http: RoutedConcurrencyTrackingHTTPClient
  let engine: SyncEngine
  let accountId: Int64
  private let libraryDAO: LibraryDAO
  private let itemDAO: ItemDAO

  init(gateCap: Int = 4) async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://sync.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    http = RoutedConcurrencyTrackingHTTPClient()
    let client = ABSClient(
      server: server, httpClient: http, tokenStore: tokenStore,
      requestGate: ServerRequestGate(maximumConcurrent: gateCap))

    let database = try AppDatabase.inMemory()
    let saved = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID,
        serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture",
        serverVersion: "2.35.1"
      )
      try record.insert(db)
      return record
    }
    accountId = try #require(saved.id)

    libraryDAO = LibraryDAO(database: database)
    itemDAO = ItemDAO(database: database)

    engine = SyncEngine.make(
      client: client,
      database: database,
      diagnostics: FakeDiagnosticsRecording(),
      appLifecycle: FakeAppLifecycle(),
      clock: FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000)),
      randomSource: { 1.0 }
    )
  }

  @discardableResult
  func seedLibrary(serverLibraryId: String) async throws -> LibraryRecord {
    try await libraryDAO.upsertAsync(
      LibraryRecord(accountId: accountId, serverLibraryId: serverLibraryId, mediaType: "book", name: serverLibraryId))
  }

  func fetchItem(libraryRowId: Int64, serverItemId: String) throws -> ItemRecord? {
    try itemDAO.fetchOne(libraryId: libraryRowId, serverItemId: serverItemId)
  }
}

// Stays: tests assert its in-flight count and max concurrency, which FakeHTTPClient does not track.
/// Routes each `send` by the request URL's library id (`/api/libraries/<id>/search`) rather than
/// FIFO order. After `enableHold()`, suspends every call until `releaseAll()` fires, so a test can
/// pin how many requests are in flight at once. Tracks `maxObservedConcurrency` like the shared
/// fakes, reimplemented locally because `Locked` is internal to `TestSupport`.
actor RoutedConcurrencyTrackingHTTPClient: HTTPClienting {
  private var responsesByLibraryId: [String: HTTPResponse] = [:]
  private var recordedRequests: [HTTPRequest] = []
  private var currentInFlight = 0
  private var observedMaxConcurrency = 0
  // Once held, every call parks until `releaseAll()`, which keeps the gate held for later ones.
  // A held call runs to completion regardless of cancellation, as the real transport does.
  private nonisolated let gate = TestGate<Void>(
    label: "RoutedConcurrencyTrackingHTTPClient send", ignoresCancellation: true)
  private var heldCallCount = 0
  private var releasedCallCount = 0

  var requests: [HTTPRequest] { recordedRequests }
  var requestCount: Int { recordedRequests.count }
  var currentInFlightCount: Int { currentInFlight }
  var maxObservedConcurrencyValue: Int { observedMaxConcurrency }

  func stub(libraryId: String, response: HTTPResponse) {
    responsesByLibraryId[libraryId] = response
  }

  func enableHold() {
    gate.hold()
  }

  /// Frees every held call, once each has parked.
  func releaseAll() async {
    let target = heldCallCount - releasedCallCount
    await gate.waitUntilParked(count: target)
    releasedCallCount += target
    gate.releaseParked()
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    recordedRequests.append(request)
    currentInFlight += 1
    observedMaxConcurrency = max(observedMaxConcurrency, currentInFlight)

    if gate.isHeld { heldCallCount += 1 }
    await gate.pass()
    currentInFlight -= 1

    guard let libraryId = Self.libraryId(from: request.url) else {
      throw FakeHTTPClientError(message: "no library id in \(request.url.absoluteString)")
    }
    guard let response = responsesByLibraryId[libraryId] else {
      throw FakeHTTPClientError(message: "no stubbed response for library \(libraryId)")
    }
    return response
  }

  private static func libraryId(from url: URL) -> String? {
    let components = url.pathComponents
    guard let index = components.firstIndex(of: "libraries"), index + 1 < components.count else { return nil }
    return components[index + 1]
  }
}
