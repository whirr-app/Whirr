import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Shared construction and fixture plumbing for the offline suites (`OfflineSourceResolutionTests`,
/// `OfflineSessionRecordingTests`), as `SyncEngineTestHarness.swift` is for the sync suites. Uses a
/// real `DownloadStore`/`DownloadFileStore` over a temporary on-disk root, never a fake: the
/// integrity sweep that `resolveSource` runs first is schema/directory-driven and only means
/// anything against real files.
final class OfflinePlaybackHarness: @unchecked Sendable {
  let http: FakeHTTPClient
  let database: AppDatabase
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let downloadStore: DownloadStore
  let downloadFileStore: DownloadFileStore
  let clock: FakeSyncClock
  let accountId: Int64
  let clientUUID: String
  let server: ABSServerConfig

  private let itemDAO: ItemDAO
  private let mediaProgressDAO: MediaProgressDAO
  private let downloadsRoot: URL
  private let cleanupRoot: () -> Void
  private let libraryRowId: Int64

  init(httpFailure: FakeHTTPClientError? = nil, transportFailure: (any Error)? = nil) async throws {
    let localServer = try ABSServerConfig(url: try #require(URL(string: "https://offline.example.test")))
    server = localServer
    http =
      if let transportFailure {
        FakeHTTPClient(transportFailure: transportFailure)
      } else {
        FakeHTTPClient(failure: httpFailure)
      }

    let localDatabase = try AppDatabase.inMemory()
    let localClientUUID = UUID().uuidString
    let savedAccount = try await localDatabase.writeAsync { db in
      var record = AccountRecord(
        clientUUID: localClientUUID, serverBaseURL: localServer.baseURL.absoluteString, serverUserId: "user_fixture",
        serverVersion: "2.35.1")
      try record.insert(db)
      return record
    }
    let localAccountId = try #require(savedAccount.id)
    accountId = localAccountId
    clientUUID = localClientUUID

    let libraryId = try await localDatabase.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    itemDAO = ItemDAO(database: localDatabase)
    mediaProgressDAO = MediaProgressDAO(database: localDatabase)
    libraryRowId = libraryId

    database = localDatabase
    outbox = try OutboxStore(database: localDatabase)
    sessionStore = PlaybackSessionStore(database: localDatabase, outbox: outbox)
    downloadStore = try DownloadStore(database: localDatabase)

    let (root, cleanup) = Self.makeTempRoot()
    downloadsRoot = root
    cleanupRoot = cleanup
    downloadFileStore = try DownloadFileStore(
      rootURL: root, fileAttributes: InertFileAttributes(), downloadStore: downloadStore)

    clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000))
  }

  deinit {
    cleanupRoot()
  }

  // MARK: - Coordinator construction

  func makeCoordinator(
    clientSessionIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
    requestLocalSessionUploadDrain: @escaping @Sendable () async -> Void = {}
  ) throws -> PlaybackSessionCoordinator {
    let tokenAccount = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: tokenAccount)
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    let drainer = OutboxDrainer(
      outboxStore: outbox, database: database, absClient: client, account: tokenAccount,
      accountId: accountId)
    return PlaybackSessionCoordinator(
      client: client, database: database, outbox: outbox, clock: clock,
      clientSessionIDGenerator: clientSessionIDGenerator,
      requestDrain: { await drainer.drainOutbox() }, downloadStore: downloadStore,
      downloadFileStore: downloadFileStore,
      requestLocalSessionUploadDrain: requestLocalSessionUploadDrain)
  }

  /// Simulates a relaunch: a new coordinator over the same on-disk state (database + downloads
  /// root). The in-memory `preparedBySessionID` cache of the original coordinator is gone, as it
  /// would be after a real process relaunch.
  func makeFreshCoordinatorForRelaunch() throws -> PlaybackSessionCoordinator {
    try makeCoordinator()
  }

  // MARK: - Items

  @discardableResult
  func makeItem(serverItemId: String, mediaKind: String = "book") async throws -> Int64 {
    try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: accountId, libraryId: libraryRowId, serverItemId: serverItemId, mediaKind: mediaKind,
          title: serverItemId, sortTitle: serverItemId)
      ).id)
  }

  func makePodcastEpisode(
    itemRowId: Int64, episodeID: String
  ) async throws -> Int64 {
    let record = try await PodcastEpisodeDAO(database: database).upsertAsync(
      PodcastEpisodeRecord(
        accountId: accountId,
        itemId: itemRowId,
        serverEpisodeId: episodeID,
        title: episodeID,
        lastSeenGeneration: 1))
    return try #require(record.id)
  }

  func itemRowId(serverItemId: String) throws -> Int64 {
    try #require(try itemDAO.fetchOne(accountId: accountId, serverItemId: serverItemId)?.id)
  }

  // MARK: - Downloads

  /// Enqueues, transitions through `downloading`, and completes one download row with a real
  /// temp file of `bytes` length moved into place. A genuine `.completed` row backed by a real
  /// file is the only state `resolveSource` treats as locally playable.
  @discardableResult
  func completeDownload(
    itemRowId: Int64, orderIndex: Int, fileDurationSeconds: Double, bytes: Int64 = 100,
    mimeType: String = "audio/mpeg", podcastEpisodeId: Int64? = nil
  ) throws -> Int64 {
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemRowId, podcastEpisodeId: podcastEpisodeId, orderIndex: orderIndex,
      serverFileIno: "ino-\(UUID().uuidString)", mimeType: mimeType)
    let record = try downloadStore.enqueue(
      accountId: accountId, itemId: itemRowId, podcastEpisodeId: podcastEpisodeId,
      serverFileIno: UUID().uuidString, orderIndex: orderIndex,
      destinationRelativePath: relativePath, expectedBytes: bytes, expectedMimeType: mimeType,
      fileDurationSeconds: fileDurationSeconds)
    let downloadId = try #require(record.id)
    _ = try downloadStore.transition(downloadId: downloadId, to: .downloading)
    let temp = try Self.makeTempFile(bytes: Int(bytes))
    _ = try downloadFileStore.completeTransfer(
      downloadId: downloadId, temporaryFileURL: temp,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: mimeType, contentLength: bytes))
    return downloadId
  }

  /// A row that never finished (never transitioned past `downloading`): a "partial" download.
  @discardableResult
  func pendingDownload(itemRowId: Int64, orderIndex: Int = 0, fileDurationSeconds: Double = 60) throws -> Int64 {
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemRowId, podcastEpisodeId: nil, orderIndex: orderIndex,
      serverFileIno: "ino-\(UUID().uuidString)", mimeType: "audio/mpeg")
    let record = try downloadStore.enqueue(
      accountId: accountId, itemId: itemRowId, serverFileIno: UUID().uuidString, orderIndex: orderIndex,
      destinationRelativePath: relativePath, expectedBytes: 10, expectedMimeType: "audio/mpeg",
      fileDurationSeconds: fileDurationSeconds)
    return try #require(record.id)
  }

  @discardableResult
  func pendingDownload(
    itemRowId: Int64, podcastEpisodeId: Int64, orderIndex: Int = 0,
    fileDurationSeconds: Double = 60
  ) throws -> Int64 {
    let relativePath = DownloadFileStore.destinationRelativePath(
      accountId: accountId, itemId: itemRowId, podcastEpisodeId: podcastEpisodeId,
      orderIndex: orderIndex, serverFileIno: "ino-\(UUID().uuidString)", mimeType: "audio/mpeg")
    let record = try downloadStore.enqueue(
      accountId: accountId, itemId: itemRowId, podcastEpisodeId: podcastEpisodeId,
      serverFileIno: UUID().uuidString, orderIndex: orderIndex,
      destinationRelativePath: relativePath, expectedBytes: 10, expectedMimeType: "audio/mpeg",
      fileDurationSeconds: fileDurationSeconds)
    return try #require(record.id)
  }

  /// Simulates a purge that is past its "mark deleting" transaction but has not yet removed the
  /// file/row. Bypasses `DownloadFileStore.delete`, so the row is caught mid-removal as a
  /// concurrent caller would see it.
  func markDeleting(downloadId: Int64) throws {
    _ = try downloadStore.transition(downloadId: downloadId, to: .deleting)
  }

  /// Simulates external file loss (not through `DownloadFileStore`'s deletion protocol), which
  /// is the precondition `DownloadIntegritySweep` demotes a `completed` row for.
  func deleteFileOnDisk(downloadId: Int64) throws {
    let record = try #require(try downloadStore.fetch(downloadId: downloadId))
    let url = downloadFileStore.absoluteURL(forRelativePath: record.destinationRelativePath)
    try FileManager.default.removeItem(at: url)
  }

  // MARK: - HTTP fixtures

  func enqueuePlayResponse(
    itemID: String, id: String = "server-session", currentTime: Double = 0, duration: Double? = 3600
  ) {
    let object: [String: Any] = [
      "id": id,
      "libraryItemId": itemID,
      "mediaType": "book",
      "displayTitle": "Fixture Book",
      "duration": duration as Any,
      "currentTime": currentTime,
      "playMethod": 0,
      "deviceInfo": ["deviceId": "server-echoed-id"],
      "audioTracks": [
        [
          "index": 1, "startOffset": 0, "duration": duration ?? 3600, "title": "Track 1",
          "contentUrl": "/api/items/\(itemID)/file/101", "mimeType": "audio/mpeg",
        ]
      ],
      "chapters": [] as [Any],
    ]
    http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: object)))
  }

  /// One full `SyncEngine.refresh()` cycle's responses for one item (as in
  /// `ForegroundPullDuringPlaybackTests`): an empty library list, one page containing this
  /// fixture's item, then an `/api/me` progress snapshot so `applyProgress` runs against it.
  func enqueuePullCycle(itemID: String, serverCurrentTime: Double, serverLastUpdateEpochMillis: Double? = nil) {
    http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: [
          "libraries": [["id": "lib-1", "name": "Library", "mediaType": "book"]]
        ])))
    var progressObject: [String: Any] = [
      "libraryItemId": itemID, "currentTime": serverCurrentTime, "isFinished": false,
    ]
    if let serverLastUpdateEpochMillis {
      progressObject["lastUpdate"] = serverLastUpdateEpochMillis
    }
    http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: ["mediaProgresses": [progressObject]])))
    http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(
          withJSONObject: [
            "results": [
              [
                "id": itemID, "libraryId": "lib-1", "mediaType": "book",
                "media": ["metadata": ["title": itemID, "authorName": NSNull()]],
              ]
            ],
            "total": 1,
            "limit": 100,
            "page": 0,
          ])))
  }

  /// A fresh, independently-seeded token store for a second `ABSClient`/`SyncEngine` composed
  /// against this same harness's fake HTTP transport (needed by the foreground-pull test, which
  /// exercises `SyncEngine.refresh()` alongside the coordinator under test).
  func makeTokenStore() throws -> InMemoryTokenStore {
    let tokenAccount = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: tokenAccount)
    return tokenStore
  }

  // MARK: - Progress / assertions

  func fetchProgress(itemRowId: Int64) throws -> MediaProgressRecord? {
    try mediaProgressDAO.fetchCurrent(
      accountId: accountId, identity: .item(itemId: itemRowId))
  }

  func seedLocalProgress(itemRowId: Int64, currentTime: Double, localSequence: Int64 = 1) async throws {
    try await database.writeAsync { db in
      var record = MediaProgressRecord(
        accountId: self.accountId, itemId: itemRowId, currentTime: currentTime, isFinished: false,
        localSequence: localSequence, origin: .local, originKey: self.clientUUID)
      try record.insert(db)
    }
  }

  func localSessionUploadRows(sessionId: Int64) throws -> [OutboxOperationRecord] {
    try database.read { db in
      try OutboxOperationRecord
        .filter(Column("playbackSessionId") == sessionId)
        .filter(Column("operationKind") == OutboxOperationKind.localSessionUpload.rawValue)
        .fetchAll(db)
    }
  }

  func sessionSyncOrCloseRows(sessionId: Int64) throws -> [OutboxOperationRecord] {
    try database.read { db in
      try OutboxOperationRecord
        .filter(Column("playbackSessionId") == sessionId)
        .fetchAll(db)
        .filter {
          $0.operationKind == OutboxOperationKind.sessionSync.rawValue
            || $0.operationKind == OutboxOperationKind.sessionClose.rawValue
        }
    }
  }

  // MARK: - Temp file helpers

  private static func makeTempRoot() -> (url: URL, cleanup: () -> Void) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "OfflinePlaybackHarness-\(UUID().uuidString)", isDirectory: true)
    return (directory, { try? FileManager.default.removeItem(at: directory) })
  }

  private static func makeTempFile(bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x41, count: bytes).write(to: url)
    return url
  }
}
