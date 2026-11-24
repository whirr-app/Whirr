import ABSApi
import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// The progress pull applies `/api/me` bookmarks, deleting by absence only from a complete
/// list and never over an unacknowledged intent, including one acknowledged mid-fetch.
@Suite("Audio bookmark pull")
struct AudioBookmarkPullTests {
  private static let item = "book-item"

  @Test("a complete list removes a bookmark the server no longer has and adds new ones")
  func completeListDeletesByAbsence() async throws {
    let harness = try await BookmarkPullHarness()
    try await harness.seedServerBookmark(time: 10, title: "Removed elsewhere")
    harness.enqueuePull(bookmarksJSON: #"[{"libraryItemId": "book-item", "time": 20, "title": "New"}]"#)

    await harness.engine.refresh()

    #expect(try harness.bookmarks().map(\.time) == [20])
  }

  /// One usable element and one with a string `time`, which makes the decoded list incomplete.
  static let partlyUnusableList = #"""
    [{"libraryItemId": "book-item", "time": 20, "title": "New"},
     {"libraryItemId": "book-item", "time": "30", "title": "String time"}]
    """#

  @Test(
    "an incomplete or missing list adds but removes nothing",
    arguments: [AudioBookmarkPullTests.partlyUnusableList, nil])
  func incompleteListDoesNotDelete(bookmarksJSON: String?) async throws {
    let harness = try await BookmarkPullHarness()
    try await harness.seedServerBookmark(time: 10, title: "Kept")
    harness.enqueuePull(bookmarksJSON: bookmarksJSON)

    await harness.engine.refresh()

    let expected: [Double] = bookmarksJSON == nil ? [10] : [10, 20]
    #expect(try harness.bookmarks().map(\.time) == expected)
  }

  @Test("a fractional server time is stored exactly")
  func fractionalTimeIsExact() async throws {
    let harness = try await BookmarkPullHarness()
    harness.enqueuePull(
      bookmarksJSON: #"[{"libraryItemId": "book-item", "time": 1234.5670000000001, "title": "Odd"}]"#)

    await harness.engine.refresh()

    #expect(try harness.bookmarks().first?.time == 1234.5670000000001)
  }

  @Test("a pending create survives a snapshot taken before it reached the server")
  func pendingCreateSurvives() async throws {
    let harness = try await BookmarkPullHarness()
    _ = try await harness.store.create(
      accountId: harness.accountId, serverItemId: Self.item, time: 40, title: "Mine",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    harness.enqueuePull(bookmarksJSON: "[]")

    await harness.engine.refresh()

    #expect(try harness.bookmarks().map(\.time) == [40])
  }

  @Test("a pending delete is not brought back")
  func pendingDeleteStaysDeleted() async throws {
    let harness = try await BookmarkPullHarness()
    try await harness.seedServerBookmark(time: 40, title: "Server")
    try await harness.store.delete(accountId: harness.accountId, serverItemId: Self.item, time: 40)
    harness.enqueuePull(bookmarksJSON: #"[{"libraryItemId": "book-item", "time": 40, "title": "Server"}]"#)

    await harness.engine.refresh()

    #expect(try harness.bookmarks().isEmpty)
  }

  @Test("a create acknowledged while the fetch is in flight is not deleted by the older snapshot")
  func createAcknowledgedDuringFetchSurvives() async throws {
    let harness = try await BookmarkPullHarness()
    _ = try await harness.store.create(
      accountId: harness.accountId, serverItemId: Self.item, time: 40, title: "Mine",
      createdAt: Date(timeIntervalSince1970: 1_700_000_000))
    let outbox = try OutboxStore(database: harness.database)
    let operationId = try #require(
      try outbox.fetchQueued(accountId: harness.accountId, entityKey: Self.item).first?.id)
    harness.http.setRequestHook { request in
      guard request.url.path == "/api/me" else { return }
      // The drain lands the create between the snapshot being taken and the pull applying it.
      _ = try? await outbox.transitionAsync(operationId: operationId, to: .sending)
      try? await outbox.acknowledgeAsync(operationId: operationId) { _ in }
    }
    harness.enqueuePull(bookmarksJSON: "[]")

    await harness.engine.refresh()

    #expect(try outbox.fetchQueued(accountId: harness.accountId, entityKey: Self.item).isEmpty)
    #expect(try harness.bookmarks().map(\.time) == [40])
  }
}

private final class BookmarkPullHarness: @unchecked Sendable {
  let database: AppDatabase
  let engine: SyncEngine
  let http: FakeHTTPClient
  let accountId: Int64
  let store: AudioBookmarkStore

  init() async throws {
    let database = try AppDatabase.inMemory()
    let http = FakeHTTPClient()
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let clientUUID = "fixture-client"
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID),
      userID: "fixture-user")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(
      TokenPair(accessToken: "fixture-access", refreshToken: "fixture-refresh"), for: account)
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    accountId = try await database.writeAsync { db in
      var accountRecord = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "fixture-user", serverVersion: "2.35.1")
      try accountRecord.insert(db)
      return accountRecord.id!
    }
    engine = SyncEngine.make(
      client: client,
      database: database,
      diagnostics: FakeDiagnosticsRecording(),
      appLifecycle: FakeAppLifecycle(),
      clock: FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000)),
      pageLimit: 100)
    self.database = database
    self.http = http
    store = AudioBookmarkStore(database: database)
  }

  func seedServerBookmark(time: Double, title: String) async throws {
    try await store.applyServerBookmarks(
      accountId: accountId,
      try bookmarks() + [
        AudioBookmark(serverItemID: "book-item", time: time, title: title, createdAt: nil)
      ],
      isComplete: false)
  }

  func bookmarks() throws -> [AudioBookmark] {
    try store.bookmarks(accountId: accountId, serverItemId: "book-item")
  }

  /// One refresh: the library list, `/api/me` (with `bookmarks` set to the raw JSON, or the key
  /// left out when `nil`), and one items page.
  func enqueuePull(bookmarksJSON: String?) {
    http.enqueue(
      Self.json(#"{"libraries": [{"id": "library-fixture", "name": "Books", "mediaType": "book"}]}"#))
    let bookmarks = bookmarksJSON.map { #", "bookmarks": \#($0)"# } ?? ""
    http.enqueue(Self.json(#"{"mediaProgress": []\#(bookmarks)}"#))
    http.enqueue(
      Self.json(
        #"""
        {"results": [{"id": "book-item", "libraryId": "library-fixture", "mediaType": "book",
          "media": {"metadata": {"title": "Fixture"}}}],
         "total": 1, "limit": 100, "page": 0}
        """#))
  }

  private static func json(_ text: String) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
  }
}
