import ABSApi
import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// The widened pull path. These tests keep the `/api/me` response separate from the minified
/// item page: an ebook-only progress row must survive the library traversal and reach the
/// composite policy even though it has no audio `currentTime`.
@Suite("EbookProgressPullTests")
struct EbookProgressPullTests {

  @Test("nil currentTime ebook-only server row is ingested")
  func nilCurrentTimeEbookOnlyServerRowIsIngested() async throws {
    let harness = try await makePullHarness()
    harness.enqueuePull(
      progressRows: [Self.ebookRow(progress: 0.6, lastUpdateMilliseconds: 1_700_000_000_000)])

    await harness.engine.refresh()

    let progress = try #require(await harness.fetchProgress())
    #expect(progress.currentTime == 0)
    #expect(progress.ebookProgress == 0.6)
    #expect(progress.ebookLocation == "epubcfi(/6/4!/4/2/1:0)")
  }

  @Test("newer other-device ebook progress moves the resume target")
  func newerOtherDeviceProgressMovesResumeTarget() async throws {
    let harness = try await makePullHarness()
    harness.enqueuePull(
      progressRows: [Self.ebookRow(progress: 0.2, lastUpdateMilliseconds: 1_700_000_000_000)])
    await harness.engine.refresh()
    #expect(try await harness.fetchProgress()?.ebookProgress == 0.2)

    harness.enqueuePull(
      progressRows: [Self.ebookRow(progress: 0.8, lastUpdateMilliseconds: 1_700_000_001_000)])
    await harness.engine.refresh()

    #expect(try await harness.fetchProgress()?.ebookProgress == 0.8)
  }

  @Test("an unacknowledged local ebook operation outranks a newer pull")
  func unacknowledgedLocalOperationOutranksPull() async throws {
    let harness = try await makePullHarness()
    let local = try await harness.dao.writeEbookPositionAndEnqueueAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemRowID),
      entityKey: PullHarness.serverItemID,
      readingPositionJSON: "{\"href\":\"Text/local.xhtml\"}",
      ebookProgress: 0.35,
      ebookLocation: nil,
      originKey: "fixture-client")
    #expect(local.progress.ebookProgress == 0.35)
    harness.enqueuePull(
      progressRows: [Self.ebookRow(progress: 0.9, lastUpdateMilliseconds: 1_800_000_000_000)])

    await harness.engine.refresh()

    let progress = try #require(await harness.fetchProgress())
    #expect(progress.ebookProgress == 0.35)
    #expect(progress.readingPositionJSON == "{\"href\":\"Text/local.xhtml\"}")
  }

  @Test("ebook zero-overwrite guard records a resolution row")
  func ebookZeroOverwriteGuardRecordsNeedsResolution() async throws {
    let harness = try await makePullHarness()
    _ = try await harness.dao.writeLocalAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemRowID),
      field: .ebook(readingPositionJSON: "{\"href\":\"Text/local.xhtml\"}", ebookProgress: 0.8),
      originKey: "fixture-client")
    try await harness.setProgressServerUpdatedAt(Date(timeIntervalSince1970: 1_700_000_000))
    harness.enqueuePull(
      progressRows: [Self.ebookRow(progress: 0, lastUpdateMilliseconds: 1_800_000_000_000)])

    await harness.engine.refresh()

    let conflicts = try harness.conflicts()
    #expect(conflicts.count == 1)
    #expect(try await harness.fetchProgress()?.ebookProgress == 0.8)
  }

  @Test("a losing ebook pull leaves the local reading position JSON untouched")
  func losingPullPreservesLocalReadingPositionJSON() async throws {
    let harness = try await makePullHarness()
    _ = try await harness.dao.writeLocalAsync(
      accountId: harness.accountId,
      identity: .item(itemId: harness.itemRowID),
      field: .ebook(readingPositionJSON: "{\"href\":\"Text/local.xhtml\"}", ebookProgress: 0.7),
      originKey: "fixture-client")
    try await harness.setProgressServerUpdatedAt(Date(timeIntervalSince1970: 1_800_000_000))
    harness.enqueuePull(
      progressRows: [Self.ebookRow(progress: 0.4, lastUpdateMilliseconds: 1_700_000_000_000)])

    await harness.engine.refresh()

    let progress = try #require(await harness.fetchProgress())
    #expect(progress.ebookProgress == 0.7)
    #expect(progress.readingPositionJSON == "{\"href\":\"Text/local.xhtml\"}")
  }

  @Test("duplicate server rows reduce deterministically regardless of response order")
  func duplicateServerRowsReduceDeterministically() async throws {
    let forward = try await makePullHarness()
    forward.enqueuePull(progressRows: [
      Self.ebookRow(progress: 0.2, lastUpdateMilliseconds: 1_700_000_000_000),
      Self.ebookRow(progress: 0.8, lastUpdateMilliseconds: 1_700_000_001_000),
    ])
    await forward.engine.refresh()

    let reverse = try await makePullHarness()
    reverse.enqueuePull(progressRows: [
      Self.ebookRow(progress: 0.8, lastUpdateMilliseconds: 1_700_000_001_000),
      Self.ebookRow(progress: 0.2, lastUpdateMilliseconds: 1_700_000_000_000),
    ])
    await reverse.engine.refresh()

    #expect(try await forward.fetchProgress()?.ebookProgress == 0.8)
    #expect(try await reverse.fetchProgress()?.ebookProgress == 0.8)
  }

  @Test("a progress pull persists the server's hidden Continue Series ids")
  func progressPullPersistsHiddenContinueSeriesIDs() async throws {
    let harness = try await makePullHarness()
    harness.enqueuePull(
      progressRows: [], hiddenSeriesIDs: ["series-one", "series-two"])

    await harness.engine.refresh()

    let hiddenSeriesIDs = try await harness.database.readAsync { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT serverSeriesId FROM hiddenContinueSeries
          WHERE accountId = ? ORDER BY serverSeriesId
          """,
        arguments: [harness.accountId])
    }
    #expect(hiddenSeriesIDs == ["series-one", "series-two"])
  }

  private static func ebookRow(progress: Double, lastUpdateMilliseconds: Double) -> [String: Any] {
    [
      "libraryItemId": PullHarness.serverItemID,
      "ebookProgress": progress,
      "ebookLocation": "epubcfi(/6/4!/4/2/1:0)",
      "isFinished": false,
      "lastUpdate": lastUpdateMilliseconds,
    ]
  }
}

private final class PullHarness: @unchecked Sendable {
  static let serverItemID = "ebook-item"

  let database: AppDatabase
  let engine: SyncEngine
  let http: FakeHTTPClient
  let accountId: Int64
  let dao: MediaProgressDAO
  let itemRowID: Int64

  init() async throws {
    let database = try AppDatabase.inMemory()
    let http = FakeHTTPClient()
    let server = try ABSServerConfig(url: URL(string: "https://books.example.test")!)
    let clientUUID = "fixture-client"
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "fixture-user")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "fixture-access", refreshToken: "fixture-refresh"), for: account)
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    let accountId = try await database.writeAsync { db in
      var accountRecord = AccountRecord(
        clientUUID: clientUUID,
        serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "fixture-user",
        serverVersion: "2.35.1")
      try accountRecord.insert(db)
      return accountRecord.id!
    }
    let itemID = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: "library-fixture", mediaType: "book", name: "Books")
      try library.insert(db)
      var item = ItemRecord(
        accountId: accountId,
        libraryId: library.id!,
        serverItemId: Self.serverItemID,
        mediaKind: "book",
        title: "Fixture",
        sortTitle: "fixture")
      try item.insert(db)
      return item.id!
    }
    let dao = MediaProgressDAO(database: database)
    let engine = SyncEngine.make(
      client: client,
      database: database,
      diagnostics: FakeDiagnosticsRecording(),
      appLifecycle: FakeAppLifecycle(),
      clock: FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000)),
      pageLimit: 100)
    self.database = database
    self.http = http
    self.accountId = accountId
    self.dao = dao
    self.engine = engine
    self.itemRowID = itemID
  }

  func enqueuePull(progressRows: [[String: Any]], hiddenSeriesIDs: [String] = []) {
    http.enqueue(
      Self.jsonResponse(object: [
        "libraries": [["id": "library-fixture", "name": "Books", "mediaType": "book"]]
      ]))
    http.enqueue(
      Self.jsonResponse(object: [
        "mediaProgresses": progressRows,
        "seriesHideFromContinueListening": hiddenSeriesIDs,
      ]))
    http.enqueue(
      Self.jsonResponse(object: [
        "results": [
          [
            "id": Self.serverItemID,
            "libraryId": "library-fixture",
            "mediaType": "book",
            "media": [
              "metadata": ["title": "Fixture"],
              "ebookFormat": "epub",
            ],
          ]
        ],
        "total": 1,
        "limit": 100,
        "page": 0,
      ]))
  }

  func fetchProgress() async throws -> MediaProgressRecord? {
    try await dao.fetchCurrentAsync(accountId: accountId, identity: .item(itemId: itemRowID))
  }

  func conflicts() throws -> [ProgressConflictRecord] {
    try dao.fetchOpenConflicts(accountId: accountId)
  }

  func setProgressServerUpdatedAt(_ date: Date) async throws {
    try await database.writeAsync { db in
      guard var record = try MediaProgressRecord.fetchOne(db, key: itemRowID) else {
        return
      }
      record.serverUpdatedAt = date
      try record.update(db)
    }
  }

  private static func jsonResponse(object: Any) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }
}

private func makePullHarness() async throws -> PullHarness {
  try await PullHarness()
}
