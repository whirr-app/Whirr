import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Shared construction/assertion plumbing for the `SyncEngine` tests: a real `ABSClient`
/// composed over `FakeHTTPClient`, an in-memory
/// `AppDatabase` with one seeded account, and the fakes for every other boundary
/// (`DiagnosticsRecording`, `AppLifecycle`, `SyncClock`).
final class Harness: @unchecked Sendable {
  let http: FakeHTTPClient
  let diagnostics: FakeDiagnosticsRecording
  let appLifecycle: FakeAppLifecycle
  let clock: FakeSyncClock
  let engine: SyncEngine
  let accountId: Int64

  let database: AppDatabase
  private let libraryDAOForAssertions: LibraryDAO
  private let itemDAO: ItemDAO
  private let syncRunDAO: SyncRunDAO
  private let mediaProgressDAO: MediaProgressDAO

  init(
    pageLimit: Int = 100,
    randomUnit: Double = 1.0,
    clockStart: Date = Date(timeIntervalSince1970: 1_700_000_000),
    syncClock: (any SyncClock)? = nil,
    localSessionUploadDrain: (@Sendable () async -> Void)? = nil,
    authorSeriesFilterDataRefresh: (@Sendable () async -> Void)? = nil,
    playback: (any PlaybackSyncing)? = nil,
    bindsClientToAccount: Bool = false
  )
    async throws
  {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://sync.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    http = FakeHTTPClient()
    let client = ABSClient(
      server: server, httpClient: http, tokenStore: tokenStore,
      boundAccount: bindsClientToAccount ? account : nil)

    let database = try AppDatabase.inMemory()
    self.database = database
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

    libraryDAOForAssertions = LibraryDAO(database: database)
    itemDAO = ItemDAO(database: database)
    syncRunDAO = SyncRunDAO(database: database)
    mediaProgressDAO = MediaProgressDAO(database: database)

    diagnostics = FakeDiagnosticsRecording()
    appLifecycle = FakeAppLifecycle()
    clock = FakeSyncClock(now: clockStart)

    engine = SyncEngine.make(
      client: client,
      database: database,
      diagnostics: diagnostics,
      appLifecycle: appLifecycle,
      playback: playback,
      clock: syncClock ?? clock,
      randomSource: { randomUnit },
      pageLimit: pageLimit,
      localSessionUploadDrain: localSessionUploadDrain,
      authorSeriesFilterDataRefresh: authorSeriesFilterDataRefresh
    )
  }

  // MARK: - Response fixtures

  func enqueueLibraries(_ libraries: [(id: String, name: String, mediaType: String)]) {
    let object: [String: Any] = [
      "libraries": libraries.map { ["id": $0.id, "name": $0.name, "mediaType": $0.mediaType] }
    ]
    http.enqueue(Self.jsonResponse(object: object))
  }

  func enqueueEmptyProgress() {
    http.enqueue(Self.jsonResponse(object: ["mediaProgresses": []]))
  }

  func enqueueProgress(_ rows: [(libraryItemId: String, currentTime: Double, isFinished: Bool)]) {
    let object: [String: Any] = [
      "mediaProgresses": rows.map {
        ["libraryItemId": $0.libraryItemId, "currentTime": $0.currentTime, "isFinished": $0.isFinished]
      }
    ]
    http.enqueue(Self.jsonResponse(object: object))
  }

  /// One item-list page. `items` is `(id, title, author)`; pass `malformed` extra raw elements
  /// to exercise decode-diagnostics recording.
  func enqueuePage(
    items: [(id: String, title: String, author: String?)],
    total: Int,
    limit: Int,
    page: Int
  ) {
    let object: [String: Any] = [
      "results": items.map { item -> [String: Any] in
        [
          "id": item.id,
          "libraryId": "irrelevant",
          "mediaType": "book",
          "media": ["metadata": ["title": item.title, "authorName": item.author as Any]],
        ]
      },
      "total": total,
      "limit": limit,
      "page": page,
    ]
    http.enqueue(Self.jsonResponse(object: object))
  }

  func enqueuePageWithSeries(
    id: String,
    title: String,
    author: String?,
    seriesName: String?,
    total: Int = 1,
    limit: Int = 100,
    page: Int = 0
  ) {
    let object: [String: Any] = [
      "results": [
        [
          "id": id,
          "libraryId": "irrelevant",
          "mediaType": "book",
          "media": [
            "metadata": [
              "title": title,
              "authorName": author as Any,
              "seriesName": seriesName as Any,
            ]
          ],
        ]
      ],
      "total": total,
      "limit": limit,
      "page": page,
    ]
    http.enqueue(Self.jsonResponse(object: object))
  }

  func enqueuePageWithoutMediaMetadata(
    id: String,
    total: Int = 1,
    limit: Int = 100,
    page: Int = 0
  ) {
    let object: [String: Any] = [
      "results": [
        [
          "id": id,
          "libraryId": "irrelevant",
          "mediaType": "book",
          "media": [:],
        ]
      ],
      "total": total,
      "limit": limit,
      "page": page,
    ]
    http.enqueue(Self.jsonResponse(object: object))
  }

  /// Like `enqueuePage`, but also carries the media signals the pull maps onto `ItemRecord`
  /// (item-level `addedAt` in epoch milliseconds, `media.duration`, `media.numAudioFiles`,
  /// `media.ebookFormat`). Separate from `enqueuePage` because tuple literals have no defaulted
  /// members, so extending its tuple would break every call site.
  func enqueuePageWithMediaSignals(
    items: [(
      id: String, title: String, author: String?, addedAtMs: Int64?, durationSeconds: Double?,
      numAudioFiles: Int?, ebookFormat: String?
    )],
    total: Int,
    limit: Int,
    page: Int
  ) {
    let object: [String: Any] = [
      "results": items.map { item -> [String: Any] in
        [
          "id": item.id,
          "libraryId": "irrelevant",
          "mediaType": "book",
          "addedAt": item.addedAtMs as Any,
          "media": [
            "metadata": ["title": item.title, "authorName": item.author as Any],
            "duration": item.durationSeconds as Any,
            "numAudioFiles": item.numAudioFiles as Any,
            "ebookFormat": item.ebookFormat as Any,
          ],
        ]
      },
      "total": total,
      "limit": limit,
      "page": page,
    ]
    http.enqueue(Self.jsonResponse(object: object))
  }

  func enqueueTransportFailure() {
    http.enqueue(HTTPResponse(statusCode: 500, headers: [:], body: Data()))
  }

  static func jsonResponse(object: Any) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object)
    )
  }

  // MARK: - Assertions

  func fetchSyncRuns() throws -> [SyncRunRecord] {
    try syncRunDAO.fetchAll(accountId: accountId)
  }

  func fetchPages(runId: Int64) throws -> [SyncPageRecord] {
    try syncRunDAO.fetchPages(runId: runId)
  }

  func fetchLibrary(
    serverLibraryId: String, includingRemoved: Bool = false
  ) throws -> LibraryRecord? {
    try libraryDAOForAssertions.fetchOneAccessible(
      accountId: accountId, serverLibraryId: serverLibraryId, includingRemoved: includingRemoved)
  }

  func fetchItem(libraryRowId: Int64, serverItemId: String) throws -> ItemRecord? {
    try itemDAO.fetchOne(libraryId: libraryRowId, serverItemId: serverItemId)
  }

  /// The generation of the traversal that last saw this item, or nil if no traversal ever has.
  /// Absence is a distinct state (see `ItemSeenRecord`).
  func fetchSeenGeneration(itemRowId: Int64) throws -> Int? {
    try database.read { db in
      try ItemSeenRecord.fetchOne(db, key: itemRowId)?.generation
    }
  }

  func seedLibrary(
    serverLibraryId: String, name: String = "Seeded", mediaType: String = "book", isIncluded: Bool = true
  ) async throws
    -> LibraryRecord
  {
    try await libraryDAOForAssertions.upsertAsync(
      LibraryRecord(
        accountId: accountId, serverLibraryId: serverLibraryId, mediaType: mediaType, name: name,
        isIncluded: isIncluded))
  }

  func setLibraryIncluded(_ included: Bool, serverLibraryId: String) async throws {
    var library = try #require(try fetchLibrary(serverLibraryId: serverLibraryId))
    library.isIncluded = included
    _ = try await libraryDAOForAssertions.upsertAsync(library)
  }

  /// Seeds an item directly (bypassing a pull) at a given generation, for deletion-inference
  /// setup.
  @discardableResult
  func seedItem(
    libraryRowId: Int64,
    serverItemId: String,
    title: String = "Seeded Title",
    generation: Int,
    seriesName: String? = nil,
    narratorName: String? = nil,
    expandedMetadataFetchedAt: Date? = nil,
    itemDescription: String? = nil
  ) async throws -> ItemRecord {
    try await syncRunDAO.applyPageAsync(
      runId: try await seedRunId(libraryRowId: libraryRowId, generation: generation),
      accountId: accountId,
      libraryId: libraryRowId,
      generation: generation,
      items: [
        ItemRecord(
          accountId: accountId, libraryId: libraryRowId, serverItemId: serverItemId,
          mediaKind: "book", title: title, sortTitle: title, itemDescription: itemDescription,
          seriesName: seriesName, narratorName: narratorName,
          expandedMetadataFetchedAt: expandedMetadataFetchedAt)
      ],
      pageNumber: 0,
      fetchedAt: Date(timeIntervalSince1970: 0),
      resultCategory: nil
    ).first!
  }

  private func seedRunId(libraryRowId: Int64, generation: Int) async throws -> Int64 {
    let run = try await syncRunDAO.startRunAsync(
      accountId: accountId, libraryId: libraryRowId, reason: "seed", generation: generation,
      sortRequested: nil, startedAt: Date(timeIntervalSince1970: 0))
    try await syncRunDAO.finishAsync(
      runId: run.id!, state: .completed, completedAt: Date(timeIntervalSince1970: 0), errorCategory: nil)
    return run.id!
  }

  func fetchProgress(itemRowId: Int64) throws -> MediaProgressRecord? {
    try mediaProgressDAO.fetchCurrent(
      accountId: accountId, identity: .item(itemId: itemRowId))
  }

  /// Soft-deletes an already-seeded row, the state pass one of deletion inference leaves behind.
  ///
  /// `seedItem` cannot express this: it goes through `applyPage`, which revives every row it
  /// writes (`SyncRunDAO`, "a row seen again is revived").
  @discardableResult
  func softDeleteItem(_ item: ItemRecord) async throws -> ItemRecord {
    var updated = item
    updated.softDeleted = true
    return try await itemDAO.upsertAsync(updated)
  }

  /// Seeds an unacknowledged local audio write, the state `progressOutcome` must refuse to
  /// overwrite from a server pull.
  @discardableResult
  func seedUnacknowledgedLocalPosition(
    itemRowId: Int64, currentTime: Double
  ) async throws -> MediaProgressRecord {
    try await mediaProgressDAO.writeLocalAsync(
      accountId: accountId, identity: .item(itemId: itemRowId),
      field: .audio(currentTime: currentTime, isFinished: false), originKey: "test-device")
  }

  /// Seeds a row as a pull would have left it: every field applied from a server row this device
  /// observed, including that row's id.
  @discardableResult
  func seedObservedProgress(
    itemRowId: Int64, currentTime: Double, ebookProgress: Double? = nil,
    serverUpdatedAt: Date?, serverProgressId: String?
  ) async throws -> MediaProgressRecord {
    try await mediaProgressDAO.applyPulledCompositeProgressAsync(
      accountId: accountId,
      resolutions: [
        MediaProgressDAO.PulledCompositeResolution(
          identity: .item(itemId: itemRowId), currentTime: currentTime, isFinished: false,
          ebookProgress: ebookProgress, ebookLocation: nil, hideFromContinueListening: false,
          serverUpdatedAt: serverUpdatedAt, serverProgressId: serverProgressId,
          resolution: MediaProgressCompositeResolution(
            audioPosition: .applyServer, ebookPosition: .applyServer, sharedFinish: .applyServer,
            continueListeningVisibility: .applyServer))
      ],
      conflicts: [])
    return try #require(try fetchProgress(itemRowId: itemRowId))
  }

  func fetchConflict(itemRowId: Int64) throws -> ProgressConflictRecord? {
    try database.read { db in
      try ProgressConflictRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("itemId") == itemRowId)
        .filter(Column("podcastEpisodeId") == nil)
        .fetchOne(db)
    }
  }

  /// `/api/me` with arbitrary row objects, for rows that need an `id`, dates, or ebook fields, or
  /// an element that fails to decode.
  func enqueueRawProgress(_ rows: [Any]) {
    http.enqueue(Self.jsonResponse(object: ["mediaProgresses": rows]))
  }

  /// Seeds a progress row referencing an item directly (bypassing a pull), so deletion-inference
  /// tests can prove a referenced row survives hard-delete as a minimal tombstone.
  @discardableResult
  func seedProgress(itemRowId: Int64, currentTime: Double = 10) async throws -> MediaProgressRecord {
    try await mediaProgressDAO.applyServerResolutionAsync(
      accountId: accountId, identity: .item(itemId: itemRowId), currentTime: currentTime,
      isFinished: false, serverUpdatedAt: nil)
  }
}

/// Counts calls to an injected `SyncEngine` side-effect closure from whichever task makes them.
/// Shared by the refresh-scope and failure-backoff suites, which both assert on how often an
/// ancillary pass runs.
final class DrainCallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

/// Holds the first request that reaches it until `release()`, so a test can act while a traversal
/// is suspended on a response. Requests after the first pass straight through.
actor HeldRequestGate {
  private nonisolated let blocked = WaitableState(false, label: "HeldRequestGate first request")
  // Stays parked on task cancellation, as the request it stands in for runs to completion.
  private nonisolated let gate = TestGate<Void>(
    label: "HeldRequestGate first request", ignoresCancellation: true)
  private(set) var isReleased = false

  func blockFirstRequest() async {
    guard blocked.value == false else { return }
    blocked.mutate { $0 = true }
    if isReleased == false {
      gate.hold()
      await gate.pass()
    }
  }

  func waitUntilBlocked() async {
    await blocked.waitUntil("blocking") { $0 }
  }

  func release() {
    isReleased = true
    gate.release()
  }
}
