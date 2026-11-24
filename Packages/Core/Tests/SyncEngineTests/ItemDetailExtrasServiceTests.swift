import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// `ItemDetailExtrasService`: the item-detail screen's on-demand series/narrator/chapter fetch.
/// Like `ResolutionCenter`, it is its own SyncEngine-owned actor with its own
/// `AccountDAO`/`ABSClient`, not an extension on the `SyncEngine` actor.
@Suite struct ItemDetailExtrasServiceTests {

  @Test("a book item maps series/narrator plus its resolved chapter list")
  func bookItemMapsSeriesNarratorAndChapters() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "id": "item1",
          "libraryId": "lib1",
          "mediaType": "book",
          "media": [
            "metadata": [
              "title": "A Book", "narratorName": "Nina Narrator", "seriesName": "The Series",
            ],
            "duration": 300,
            "audioFiles": [],
            "tracks": [],
            "chapters": [
              ["id": 1, "start": 0, "end": 100, "title": "Chapter One"],
              ["id": 2, "start": 100, "title": "Chapter Two"],
            ],
          ] as [String: Any],
        ]))

    let extras = await harness.service.itemDetailExtras(itemId: "item1")

    #expect(
      extras
        == ItemDetailExtras(
          seriesName: "The Series",
          narrator: "Nina Narrator",
          chapters: [
            ItemChapterInfo(title: "Chapter One", start: 0, end: 100),
            ItemChapterInfo(title: "Chapter Two", start: 100, end: 300),
          ]
        ))

    let item = try #require(
      try ItemDAO(database: harness.database).fetchOne(
        accountId: harness.accountID, serverItemId: "item1"))
    let stored = try ItemChapterStore(database: harness.database).fetch(
      accountId: harness.accountID, itemId: try #require(item.id))
    #expect(
      stored
        == [
          StoredItemChapter(
            serverChapterId: 1, position: 0, start: 0, end: 100, title: "Chapter One"),
          StoredItemChapter(
            serverChapterId: 2, position: 1, start: 100, end: 300, title: "Chapter Two"),
        ],
      "opening item detail should backfill the durable chapter snapshot for an existing download")
  }

  @Test("async chapter fetch matches the synchronous store")
  func chapterFetchAsyncMatchesSyncStore() async throws {
    let harness = try await Harness()
    let item = try #require(
      try ItemDAO(database: harness.database).fetchOne(
        accountId: harness.accountID, serverItemId: "item1"))
    let itemID = try #require(item.id)
    let store = ItemChapterStore(database: harness.database)
    let chapters = [
      StoredItemChapter(
        serverChapterId: 10, position: 0, start: 0, end: 100, title: "First"),
      StoredItemChapter(
        serverChapterId: 20, position: 1, start: 100, end: 250, title: nil),
    ]
    try await store.replaceAsync(
      accountId: harness.accountID, itemId: itemID, chapters: chapters)

    let syncResult = try store.fetch(accountId: harness.accountID, itemId: itemID)
    let asyncResult = try await store.fetchAsync(accountId: harness.accountID, itemId: itemID)

    #expect(asyncResult == syncResult)
    #expect(asyncResult == chapters)
  }

  @Test("async chapter replace removes the old snapshot before inserting the new one")
  func chapterReplaceAsyncMatchesSyncStore() async throws {
    let harness = try await Harness()
    let item = try #require(
      try ItemDAO(database: harness.database).fetchOne(
        accountId: harness.accountID, serverItemId: "item1"))
    let itemID = try #require(item.id)
    let store = ItemChapterStore(database: harness.database)
    let oldChapters = [
      StoredItemChapter(
        serverChapterId: 10, position: 0, start: 0, end: 100, title: "Old")
    ]
    let newChapters = [
      StoredItemChapter(
        serverChapterId: 30, position: 0, start: 0, end: 50, title: "New first"),
      StoredItemChapter(
        serverChapterId: 40, position: 1, start: 50, end: 200, title: "New second"),
    ]
    try await store.replaceAsync(
      accountId: harness.accountID, itemId: itemID, chapters: oldChapters)

    try await store.replaceAsync(
      accountId: harness.accountID, itemId: itemID, chapters: newChapters)

    let syncResult = try store.fetch(accountId: harness.accountID, itemId: itemID)
    let asyncResult = try await store.fetchAsync(accountId: harness.accountID, itemId: itemID)

    #expect(asyncResult == syncResult)
    #expect(asyncResult == newChapters)
  }

  /// An ebook-only item has no chapters and no listening history, so its detail screen shows the
  /// blurb instead. `BookMedia.description` is decoded but must be carried across the SyncEngine
  /// boundary to reach a screen.
  @Test("a book item carries its description through to the detail extras")
  func bookItemCarriesItsDescription() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "id": "item-ebook",
          "libraryId": "lib1",
          "mediaType": "book",
          "media": [
            "metadata": [
              "title": "An Ebook",
              "description": "The crew of the Rocinante heads for the Ring.",
            ],
            "duration": 0,
            "audioFiles": [],
            "tracks": [],
            "chapters": [],
          ] as [String: Any],
        ]))

    let extras = await harness.service.itemDetailExtras(itemId: "item-ebook")

    #expect(extras?.description == "The crew of the Rocinante heads for the Ring.")
    #expect(extras?.chapters.isEmpty == true)
  }

  @Test("a podcast item maps to nil series/narrator and an empty chapter list")
  func podcastItemMapsToEmptyExtras() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "id": "item2",
          "libraryId": "lib1",
          "mediaType": "podcast",
          "media": [
            "metadata": ["title": "A Podcast", "author": "Some Author"],
            "episodes": [],
          ] as [String: Any],
        ]))

    let extras = await harness.service.itemDetailExtras(itemId: "item2")

    #expect(extras == ItemDetailExtras(seriesName: nil, narrator: nil, chapters: []))
  }

  @Test("a network/transport failure returns nil rather than throwing or crashing")
  func fetchFailureReturnsNil() async throws {
    let harness = try await Harness()
    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))

    let extras = await harness.service.itemDetailExtras(itemId: "item1")

    #expect(extras == nil)
  }

  @Test("concurrent callers share one expanded request")
  func concurrentCallersShareOneExpandedRequest() async throws {
    let harness = try await Harness()
    harness.http.enqueue(Harness.bookResponse())

    async let first = harness.service.itemDetailExtras(itemId: "item1")
    async let second = harness.service.itemDetailExtras(itemId: "item1")
    let values = await (first, second)

    #expect(values.0 == values.1)
    #expect(harness.http.requests.count == 1)
  }

  @Test("a cached call does not refetch")
  func cachedCallDoesNotRefetch() async throws {
    let harness = try await Harness()
    harness.http.enqueue(Harness.bookResponse())

    _ = await harness.service.itemDetailExtras(itemId: "item1")
    _ = await harness.service.itemDetailExtras(itemId: "item1")

    #expect(harness.http.requests.count == 1)
  }

  @Test("a fresh service instance reads stored extras without refetching")
  func freshServiceInstanceReadsStoredExtrasWithoutRefetching() async throws {
    let harness = try await Harness()
    harness.http.enqueue(Harness.bookResponse())

    let first = try #require(await harness.service.itemDetailExtras(itemId: "item1"))
    let freshService = harness.makeService(http: harness.http)
    let second = await freshService.itemDetailExtras(itemId: "item1")

    #expect(second == first)
    #expect(harness.http.requests.count == 1)
  }

  @Test("a stored description round-trips through the database-first read")
  func storedDescriptionRoundTripsThroughDatabaseFirstRead() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.bookResponse(description: "A description that survives relaunch."))

    _ = await harness.service.itemDetailExtras(itemId: "item1")
    let freshService = harness.makeService(http: harness.http)
    let second = await freshService.itemDetailExtras(itemId: "item1")

    #expect(second?.description == "A description that survives relaunch.")
    #expect(harness.http.requests.count == 1)
  }

  @Test("stored chapters round-trip in their persisted order")
  func storedChaptersRoundTripInPersistedOrder() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.bookResponse(
        chapters: [
          ["id": 20, "start": 100, "end": 200, "title": "Second"],
          ["id": 10, "start": 0, "end": 100, "title": "First"],
        ]))

    _ = await harness.service.itemDetailExtras(itemId: "item1")
    let freshService = harness.makeService(http: harness.http)
    let second = await freshService.itemDetailExtras(itemId: "item1")

    #expect(
      second?.chapters
        == [
          ItemChapterInfo(title: "Second", start: 100, end: 200),
          ItemChapterInfo(title: "First", start: 0, end: 100),
        ])
    #expect(harness.http.requests.count == 1)
  }

  @Test("stored zero chapters do not trigger a refetch")
  func storedZeroChaptersDoNotTriggerARefetch() async throws {
    let harness = try await Harness()
    harness.http.enqueue(Harness.bookResponse())

    _ = await harness.service.itemDetailExtras(itemId: "item1")
    let freshService = harness.makeService(http: harness.http)
    let second = await freshService.itemDetailExtras(itemId: "item1")

    #expect(second?.chapters == [])
    #expect(harness.http.requests.count == 1)
  }

  /// The stored row is authoritative only until the server's own record moves. A library scan that
  /// picks up a replaced file bumps `updatedAt`, which is the only signal the app has that its
  /// expanded copy (including the ebook file identity a download is planned from) is stale.
  @Test("a server-side change after the last expand refetches instead of trusting the row")
  func serverSideChangeAfterTheLastExpandRefetches() async throws {
    let harness = try await Harness()
    harness.http.enqueue(Harness.bookResponse())
    _ = await harness.service.itemDetailExtras(itemId: "item1")
    try await harness.setServerUpdatedAt(Date().addingTimeInterval(60))

    harness.http.enqueue(Harness.bookResponse(description: "Rewritten by a rescan."))
    let freshService = harness.makeService(http: harness.http)
    let second = await freshService.itemDetailExtras(itemId: "item1")

    #expect(second?.description == "Rewritten by a rescan.")
    #expect(harness.http.requests.count == 2)
  }

  @Test("a server record older than the last expand still reads from the row")
  func serverRecordOlderThanTheLastExpandStillReadsFromTheRow() async throws {
    let harness = try await Harness()
    harness.http.enqueue(Harness.bookResponse())
    _ = await harness.service.itemDetailExtras(itemId: "item1")
    try await harness.setServerUpdatedAt(Date().addingTimeInterval(-3_600))

    let freshService = harness.makeService(http: harness.http)
    let second = await freshService.itemDetailExtras(itemId: "item1")

    #expect(second?.narrator == "Nina Narrator")
    #expect(harness.http.requests.count == 1)
  }

  @Test("an item without expanded metadata fetched at still uses the network")
  func itemWithoutExpandedMetadataFetchedAtStillUsesTheNetwork() async throws {
    let harness = try await Harness()
    harness.http.enqueue(Harness.bookResponse())

    let extras = await harness.service.itemDetailExtras(itemId: "item1")

    #expect(extras != nil)
    #expect(harness.http.requests.count == 1)
  }

  @Test("a stored hit succeeds when every network request fails")
  func storedHitSucceedsWhenEveryNetworkRequestFails() async throws {
    let harness = try await Harness()
    harness.http.enqueue(Harness.bookResponse())

    let expected = try #require(await harness.service.itemDetailExtras(itemId: "item1"))
    let offlineHTTP = FakeHTTPClient(failure: FakeHTTPClientError(message: "offline"))
    let freshService = harness.makeService(http: offlineHTTP)
    let actual = await freshService.itemDetailExtras(itemId: "item1")

    #expect(actual == expected)
    #expect(offlineHTTP.requests.isEmpty)
  }

  /// The player's chapter row reads this on a cold launch, when the fetch can fail before the
  /// session's credentials are fresh; the model behind it never retries.
  @Test("a stale stored copy answers when the refetch fails, and is not cached")
  func staleStoredCopyAnswersWhenTheRefetchFails() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.bookResponse(chapters: [["id": 1, "start": 0, "end": 300, "title": "Only"]]))
    _ = await harness.service.itemDetailExtras(itemId: "item1")
    try await harness.setServerUpdatedAt(Date().addingTimeInterval(60))

    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))
    harness.http.enqueue(Harness.bookResponse(description: "Rewritten by a rescan."))
    let freshService = harness.makeService(http: harness.http)
    let fallback = await freshService.itemDetailExtras(itemId: "item1")

    #expect(fallback?.chapters == [ItemChapterInfo(title: "Only", start: 0, end: 300)])
    let retried = await freshService.itemDetailExtras(itemId: "item1")
    #expect(retried?.description == "Rewritten by a rescan.")
    #expect(harness.http.requests.count == 3)
  }

  /// A download persists the book's chapters from its own expanded request without stamping the
  /// item row, so the row alone does not say the chapters are there.
  @Test("a download's stored chapters answer when the fetch fails")
  func downloadStoredChaptersAnswerWhenTheFetchFails() async throws {
    let harness = try await Harness()
    let item = try #require(
      try await ItemDAO(database: harness.database).fetchOneAsync(
        accountId: harness.accountID, serverItemId: "item1"))
    try await ItemChapterStore(database: harness.database).replaceAsync(
      accountId: harness.accountID, itemId: try #require(item.id),
      chapters: [
        StoredItemChapter(serverChapterId: 0, position: 0, start: 0, end: 120, title: "Opening")
      ])

    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))
    let extras = await harness.service.itemDetailExtras(itemId: "item1")

    #expect(extras?.chapters == [ItemChapterInfo(title: "Opening", start: 0, end: 120)])
    #expect(harness.http.requests.count == 1)
  }

  @Test("the bounded cache evicts its least recently used entry")
  func cacheEvictsLeastRecentlyUsedEntryAtBound() async throws {
    let harness = try await Harness(cacheLimit: 2)
    for _ in 0..<4 {
      harness.http.enqueue(Harness.bookResponse())
    }

    _ = await harness.service.itemDetailExtras(itemId: "item-A")
    _ = await harness.service.itemDetailExtras(itemId: "item-B")
    _ = await harness.service.itemDetailExtras(itemId: "item-A")
    _ = await harness.service.itemDetailExtras(itemId: "item-C")
    _ = await harness.service.itemDetailExtras(itemId: "item-B")

    #expect(harness.http.requests.count == 4)
  }

  @Test("success writes display metadata")
  func successWritesDisplayMetadata() async throws {
    let harness = try await Harness()
    harness.http.enqueue(Harness.bookResponse())

    _ = await harness.service.itemDetailExtras(itemId: "item1")

    let item = try #require(
      try ItemDAO(database: harness.database).fetchOne(
        accountId: harness.accountID, serverItemId: "item1"))
    #expect(item.seriesName == "The Series")
    #expect(item.narratorName == "Nina Narrator")
    #expect(item.expandedMetadataFetchedAt != nil)
  }

  @Test("a failure is retryable and does not write absence")
  func failureIsRetryableAndDoesNotWriteAbsence() async throws {
    let harness = try await Harness()
    harness.http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))
    harness.http.enqueue(Harness.bookResponse())

    #expect(await harness.service.itemDetailExtras(itemId: "item1") == nil)
    let afterFailure = try ItemDAO(database: harness.database).fetchOne(
      accountId: harness.accountID, serverItemId: "item1")
    #expect(afterFailure?.expandedMetadataFetchedAt == nil)

    #expect(await harness.service.itemDetailExtras(itemId: "item1") != nil)
    #expect(harness.http.requests.count == 2)
  }

  @Test("an account row without a resolvable id still returns chapters, and writes no metadata")
  func unresolvableAccountIDStillReturnsChaptersWithoutWriting() async throws {
    let harness = try await Harness()
    harness.http.enqueue(
      Harness.jsonResponse(
        object: [
          "id": "item1",
          "libraryId": "lib1",
          "mediaType": "book",
          "media": [
            "metadata": [
              "title": "A Book", "narratorName": "Nina Narrator", "seriesName": "The Series",
            ],
            "duration": 300,
            "audioFiles": [],
            "tracks": [],
            "chapters": [
              ["id": 1, "start": 0, "end": 100, "title": "Chapter One"]
            ],
          ] as [String: Any],
        ]))
    var idless = try #require(try AccountDAO(database: harness.database).fetch())
    idless.id = nil

    let extras = await harness.service.itemDetailExtras(itemId: "item1", accountRecord: idless)

    #expect(
      extras
        == ItemDetailExtras(
          seriesName: "The Series",
          narrator: "Nina Narrator",
          chapters: [ItemChapterInfo(title: "Chapter One", start: 0, end: 100)]
        ))
    let item = try ItemDAO(database: harness.database).fetchOne(
      accountId: harness.accountID, serverItemId: "item1")
    #expect(item?.expandedMetadataFetchedAt == nil)
    #expect(item?.seriesName == nil)
    #expect(item?.narratorName == nil)
  }

  @Test("an RSS item returns nil without making an ABS request")
  func rssIdentityReturnsNilWithoutRequestingABS() async throws {
    let harness = try await Harness()

    let extras = await harness.service.itemDetailExtras(itemId: "rss:7")

    #expect(extras == nil)
    #expect(harness.http.requests.count == 0)
  }

  @Test("no signed-in account returns nil rather than throwing or crashing")
  func noAccountReturnsNil() async throws {
    let database = try AppDatabase.inMemory()
    let server = try ABSServerConfig(url: try #require(URL(string: "https://sync.example.test")))
    let http = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: InMemoryTokenStore())
    let service = ItemDetailExtrasService(database: database, client: client)

    let extras = await service.itemDetailExtras(itemId: "item1")

    #expect(extras == nil)
  }

  /// Minimal single-account harness. Mirrors `SyncEngineTestHarness.Harness`'s composition, but
  /// scoped to what `ItemDetailExtrasService` needs (no library/sync-run/progress DAOs).
  private final class Harness: @unchecked Sendable {
    let http: FakeHTTPClient
    let service: ItemDetailExtrasService
    let database: AppDatabase
    let accountID: Int64
    let server: ABSServerConfig
    let tokenStore: InMemoryTokenStore

    init(cacheLimit: Int = 24) async throws {
      let server = try ABSServerConfig(url: try #require(URL(string: "https://sync.example.test")))
      let clientUUID = UUID().uuidString
      let account = try TokenAccount(
        credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
      let tokenStore = InMemoryTokenStore()
      try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

      let http = FakeHTTPClient()
      let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

      let database = try AppDatabase.inMemory()
      let accountRecord = try await database.writeAsync { db in
        var record = AccountRecord(
          clientUUID: clientUUID,
          serverBaseURL: server.baseURL.absoluteString,
          serverUserId: "user_fixture",
          serverVersion: "2.35.1"
        )
        try record.save(db)
        return record
      }
      let accountID = try #require(accountRecord.id)
      let library = try await LibraryDAO(database: database).upsertAsync(
        LibraryRecord(
          accountId: accountID, serverLibraryId: "lib1", mediaType: "book", name: "Library"))
      _ = try await ItemDAO(database: database).upsertAsync(
        ItemRecord(
          accountId: accountID,
          libraryId: try #require(library.id),
          serverItemId: "item1",
          mediaKind: "book",
          title: "A Book",
          sortTitle: "a book"))

      self.server = server
      self.tokenStore = tokenStore
      self.http = http
      self.database = database
      self.accountID = accountID
      self.service = ItemDetailExtrasService(
        database: database, client: client, cacheLimit: cacheLimit)
    }

    /// Stands in for the minified traversal's `serverUpdatedAt` write without running a whole
    /// library pull, which this suite has no harness for.
    func setServerUpdatedAt(_ date: Date) async throws {
      try await database.writeAsync { db in
        try db.execute(
          sql: "UPDATE item SET serverUpdatedAt = ? WHERE serverItemId = ?",
          arguments: [date, "item1"])
      }
    }

    func makeService(http: FakeHTTPClient) -> ItemDetailExtrasService {
      ItemDetailExtrasService(
        database: database,
        client: ABSClient(server: server, httpClient: http, tokenStore: tokenStore))
    }

    static func bookResponse(
      description: String? = nil,
      chapters: [[String: Any]] = []
    ) -> HTTPResponse {
      var metadata: [String: Any] = [
        "title": "A Book", "narratorName": "Nina Narrator", "seriesName": "The Series",
      ]
      if let description {
        metadata["description"] = description
      }
      return jsonResponse(
        object: [
          "id": "item1",
          "libraryId": "lib1",
          "mediaType": "book",
          "media": [
            "metadata": metadata,
            "duration": 300,
            "audioFiles": [],
            "tracks": [],
            "chapters": chapters,
          ] as [String: Any],
        ])
    }

    static func jsonResponse(object: Any) -> HTTPResponse {
      HTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: object)
      )
    }
  }
}
