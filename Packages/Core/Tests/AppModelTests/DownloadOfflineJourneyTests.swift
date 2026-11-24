import Foundation
import GRDB
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import ABSApi
@testable import AppModel

/// Product journey 5 (request a download on Wi-Fi, survive interruption/relaunch, play it fully
/// offline, see it in storage, delete it, re-download it, never a dangling row) as one
/// deterministic, composed-model test. Drives the real `ItemDownloadModel`/`StorageModel` over a
/// real `DownloadCoordinator`/`PlaybackSessionCoordinator`, a real on-disk `AppDatabase` and
/// downloads root (real file I/O), reopened as in `SessionRecoveryJourneyTests.openIncarnation()`
/// to simulate relaunch reattach. Fakes only at the true boundaries: HTTP transport, background
/// transfer adapter, network conditions.
@MainActor
@Suite("Download/offline journey (PRODUCT journey 5)", .timeLimit(.minutes(1)))
struct DownloadOfflineJourneyTests {

  @Test(
    "request on Wi-Fi, progress, interruption/resume across a relaunch, fully offline playback, storage, delete, and re-download - no dangling row at any checkpoint"
  )
  func fullJourney() async throws {
    let env = try await DownloadJourneyEnvironment()
    var inc = try env.openIncarnation()

    // MARK: - Request on Wi-Fi
    env.enqueueBookItemDetail(on: inc.http)
    await inc.itemDownloadModel.requestDownload()
    await env.waitUntil(inc.itemDownloadModel) {
      if case .downloading = $0 { return true }
      return false
    }

    var rows = try env.fetchDownloads(inc)
    #expect(rows.count == 2, "one row per audio file")
    #expect(rows.allSatisfy { $0.state == .downloading }, "both fit within the two-slot cap")
    try env.assertNoDanglingRows(inc)

    // MARK: - Progress
    let firstDownloadId = try #require(rows[0].id)
    inc.backgroundTransferring.pushEvent(
      .progress(identity: .abs(rowID: firstDownloadId), receivedBytes: 20, expectedBytes: 40))
    await env.waitUntil(inc.storageModel) { $0.accountTotalBytes >= 20 }

    // MARK: - Interruption + resume, including a simulated relaunch reattach
    // A fresh incarnation over the same on-disk file/downloads root: `DownloadStore.init`'s bulk
    // reconciliation demotes both live `.downloading` rows to `.interrupted` as soon as the store
    // opens, as a real crash/relaunch does. The fresh `FakeBackgroundTransferring` reports no live
    // tasks, as the adapter loses its in-flight state across a relaunch.
    env.close(inc)
    inc = try env.openIncarnation()
    rows = try env.fetchDownloads(inc)
    #expect(rows.allSatisfy { $0.state == .interrupted }, "the relaunch's own reconciliation demotes both rows")

    await inc.coordinator.reconcileAfterLaunch()
    await env.waitUntil(inc.itemDownloadModel) {
      if case .downloading = $0 { return true }
      return false
    }
    rows = try env.fetchDownloads(inc)
    #expect(rows.allSatisfy { $0.state == .downloading }, "requeued, then immediately restarted - a slot is free")
    try env.assertNoDanglingRows(inc)

    // MARK: - Validation: both transfers finish and complete
    for row in rows {
      let downloadId = try #require(row.id)
      let tempFile = try env.makeTempFile(bytes: Int(row.expectedBytes))
      inc.backgroundTransferring.pushEvent(
        .finished(
          identity: .abs(rowID: downloadId), temporaryFileURL: tempFile,
          response: BackgroundTransferResponse(
            httpStatusCode: 200, mimeType: row.expectedMimeType, contentLength: row.expectedBytes)))
    }
    await env.waitUntil(inc.itemDownloadModel) { $0 == .completed }
    rows = try env.fetchDownloads(inc)
    #expect(rows.allSatisfy { $0.state == .completed })
    try env.assertNoDanglingRows(inc)
    #expect(inc.itemDownloadModel.isAvailableOffline)

    // MARK: - Play fully offline with the API fake unreachable
    let playback = try env.makeOfflinePlaybackCoordinator(inc)
    let prepared = try await playback.startSession(itemID: DownloadJourneyEnvironment.itemID, episodeID: nil)
    #expect(prepared.source == .local, "resolves to the completed local copy, never touching the network")
    #expect(prepared.duration == 250)
    #expect(
      prepared.chapters
        == [
          PreparedPlaybackChapter(id: 0, start: 0, end: 100, title: "Opening"),
          PreparedPlaybackChapter(id: 1, start: 100, end: 250, title: "The Long Road"),
        ],
      "the chapter snapshot fetched while planning the download must survive fully offline playback"
    )

    let resumedPlayback = try env.makeOfflinePlaybackCoordinator(inc)
    let resumed = try await resumedPlayback.startSession(
      itemID: DownloadJourneyEnvironment.itemID, episodeID: nil)
    #expect(
      resumed.chapters == prepared.chapters,
      "resuming an active local session after relaunch must retain the same chapter map")

    // MARK: - Storage visible
    await env.waitUntil(inc.storageModel) { $0.accountTotalBytes == 100 && $0.rows.count == 1 }
    #expect(inc.storageModel.rows.first?.totalBytes == 100)
    #expect(inc.storageModel.rows.first?.itemId == DownloadJourneyEnvironment.itemID)
    #expect(inc.storageModel.rows.first?.title == "Journey Book", "titled from the item row, not the caller")

    // MARK: - Delete
    await inc.itemDownloadModel.remove()
    await env.waitUntil(inc.itemDownloadModel) { $0 == .notDownloaded }
    #expect(try env.fetchDownloads(inc).isEmpty, "no dangling rows survive the delete")
    for row in rows {
      let url = inc.downloadFileStore.absoluteURL(forRelativePath: row.destinationRelativePath)
      #expect(FileManager.default.fileExists(atPath: url.path) == false, "no dangling file survives the delete")
    }
    await env.waitUntil(inc.storageModel) { $0.accountTotalBytes == 0 && $0.rows.isEmpty }
    #expect(inc.storageModel.rows.isEmpty, "a purged item leaves the storage list entirely")

    // MARK: - Re-download
    env.enqueueBookItemDetail(on: inc.http)
    await inc.itemDownloadModel.requestDownload()
    await env.waitUntil(inc.itemDownloadModel) {
      if case .downloading = $0 { return true }
      return false
    }
    let redownloadedRows = try env.fetchDownloads(inc)
    #expect(redownloadedRows.count == 2, "re-planned cleanly, never colliding with the deleted rows")
    for row in redownloadedRows {
      let downloadId = try #require(row.id)
      let tempFile = try env.makeTempFile(bytes: Int(row.expectedBytes))
      inc.backgroundTransferring.pushEvent(
        .finished(
          identity: .abs(rowID: downloadId), temporaryFileURL: tempFile,
          response: BackgroundTransferResponse(
            httpStatusCode: 200, mimeType: row.expectedMimeType, contentLength: row.expectedBytes)))
    }
    await env.waitUntil(inc.itemDownloadModel) { $0 == .completed }
    try env.assertNoDanglingRows(inc)
    #expect(inc.itemDownloadModel.isAvailableOffline)
  }
}

// MARK: - Environment

private final class DownloadJourneyEnvironment: @unchecked Sendable {
  static let itemID = "item_journey_download"
  static let libraryID = "lib-journey-download"

  let downloadsRootURL: URL
  let server: ABSServerConfig
  let account: TokenAccount
  let tokenStore: InMemoryTokenStore
  let accountId: Int64
  let itemRowId: Int64

  private let fixture: SuiteOnDiskDatabases

  init() async throws {
    let fixture = try await SuiteOnDiskDatabases.acquire(named: "DownloadOfflineJourneyTests")
    self.fixture = fixture
    downloadsRootURL = fixture.scope.directoryURL.appendingPathComponent("Downloads", isDirectory: true)

    server = try ABSServerConfig(url: try #require(URL(string: "https://download-journey.example.test")))
    let clientUUID = UUID().uuidString
    account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user-1")
    tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: account)

    let seedDatabase = try fixture.scope.open(fileAttributes: POSIXFileAttributeApplier())
    let accountDAO = AccountDAO(database: seedDatabase)
    let saved = try accountDAO.save(
      AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString, serverUserId: "user-1",
        serverVersion: "2.35.1"))
    let localAccountId = try #require(saved.id)
    let libraryRowId = try await seedDatabase.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: Self.libraryID, mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: seedDatabase)
    let localItemRowId = try #require(
      try itemDAO.upsert(
        ItemRecord(
          accountId: localAccountId, libraryId: libraryRowId, serverItemId: Self.itemID, mediaKind: "book",
          title: "Journey Book", sortTitle: "journey book")
      ).id)
    accountId = localAccountId
    itemRowId = localItemRowId
    fixture.scope.close(seedDatabase)
  }

  var databaseURL: URL { fixture.scope.url() }

  struct Incarnation {
    let database: AppDatabase
    let http: FakeHTTPClient
    let client: ABSClient
    let downloadStore: DownloadStore
    let downloadFileStore: DownloadFileStore
    let backgroundTransferring: FakeBackgroundTransferring
    let coordinator: DownloadCoordinator
    let itemDownloadModel: ItemDownloadModel
    let storageModel: StorageModel

  }

  /// One "process lifetime" (the crash/relaunch boundary): a fresh `AppDatabase` connection over
  /// the same file, a fresh `DownloadStore` (which alone does the `.downloading` to `.interrupted`
  /// reconciliation at construction), `DownloadFileStore`, and a `FakeBackgroundTransferring` with
  /// no live tasks. `tokenStore`/`server`/`account` persist, as Keychain survives relaunch.
  @MainActor
  func openIncarnation() throws -> Incarnation {
    let database = try fixture.scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    let http = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)
    let downloadStore = try DownloadStore(database: database)
    let downloadFileStore = try DownloadFileStore(
      rootURL: downloadsRootURL, fileAttributes: InertFileAttributes(), downloadStore: downloadStore)
    let backgroundTransferring = FakeBackgroundTransferring()
    let coordinator = DownloadCoordinator.make(
      client: client, database: database, downloadStore: downloadStore, downloadFileStore: downloadFileStore,
      backgroundTransferring: backgroundTransferring, downloadPreferences: FakeDownloadPreferences(),
      networkConditions: FakeNetworkConditions(), diagnostics: FakeDiagnosticsRecording(),
      freeSpaceReporting: FakeFreeSpaceReporting())

    let itemDownloadModel = ItemDownloadModel(
      itemID: Self.itemID, downloadReading: DefaultDownloadReading(database: database), downloadIntents: coordinator)
    let storageModel = StorageModel(
      storageReading: DefaultStorageReading(database: database), downloadIntents: coordinator)

    return Incarnation(
      database: database, http: http, client: client, downloadStore: downloadStore,
      downloadFileStore: downloadFileStore, backgroundTransferring: backgroundTransferring, coordinator: coordinator,
      itemDownloadModel: itemDownloadModel, storageModel: storageModel)
  }

  func close(_ incarnation: Incarnation) {
    fixture.scope.close(incarnation.database)
  }

  /// A standalone `PlaybackSessionCoordinator` wired against this incarnation's own real
  /// `downloadStore`/`downloadFileStore`, but over an always-failing HTTP transport. Proves that a
  /// fully-downloaded item resolves and plays from the local copy alone, without needing the
  /// network.
  func makeOfflinePlaybackCoordinator(_ inc: Incarnation) throws -> PlaybackSessionCoordinator {
    let offlineHTTP = FakeHTTPClient(failure: FakeHTTPClientError(message: "unreachable"))
    let offlineClient = ABSClient(server: server, httpClient: offlineHTTP, tokenStore: tokenStore)
    let outbox = try OutboxStore(database: inc.database)
    return PlaybackSessionCoordinator(
      client: offlineClient, database: inc.database, outbox: outbox, downloadStore: inc.downloadStore,
      downloadFileStore: inc.downloadFileStore)
  }

  // MARK: - Fixtures

  func enqueueBookItemDetail(on http: FakeHTTPClient) {
    let object: [String: Any] = [
      "id": Self.itemID,
      "libraryId": Self.libraryID,
      "mediaType": "book",
      "media": [
        "metadata": ["title": "Journey Book"],
        "duration": 250.0,
        "audioFiles": [
          ["index": 0, "ino": "100", "duration": 100.0, "mimeType": "audio/mp4", "metadata": ["size": 40]],
          ["index": 1, "ino": "101", "duration": 150.0, "mimeType": "audio/mp4", "metadata": ["size": 60]],
        ],
        "tracks": [[String: Any]](),
        "chapters": [
          ["id": 0, "start": 0.0, "end": 100.0, "title": "Opening"],
          ["id": 1, "start": 100.0, "end": 250.0, "title": "The Long Road"],
        ],
      ] as [String: Any],
    ]
    http.enqueue(
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: object)))
  }

  func fetchDownloads(_ inc: Incarnation) throws -> [DownloadRecord] {
    try inc.downloadStore.fetchDownloads(itemId: itemRowId)
  }

  func makeTempFile(bytes: Int) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data(repeating: 0x42, count: bytes).write(to: url)
    return url
  }

  /// The no-dangling-row invariant: every `completed` row must have a real backing file, checked
  /// at every journey checkpoint.
  func assertNoDanglingRows(_ inc: Incarnation) throws {
    let rows = try fetchDownloads(inc)
    for row in rows where row.state == .completed {
      let url = inc.downloadFileStore.absoluteURL(forRelativePath: row.destinationRelativePath)
      #expect(FileManager.default.fileExists(atPath: url.path), "a completed row must have a real backing file")
    }
  }

  // MARK: - Waits

  /// No mutation hook to register a waiter against (a real on-disk GRDB row observed through a
  /// `ValueObservation`-backed `AsyncStream` that this suite does not fake), so polls via the
  /// shared `TestSupport.waitUntil`.
  @MainActor
  func waitUntil(_ model: ItemDownloadModel, _ predicate: @escaping (ItemDownloadStatus) -> Bool) async {
    await TestSupport.waitUntil { predicate(model.status) }
  }

  @MainActor
  func waitUntil(_ model: StorageModel, _ predicate: @escaping (StorageModel) -> Bool) async {
    await TestSupport.waitUntil { predicate(model) }
  }
}
