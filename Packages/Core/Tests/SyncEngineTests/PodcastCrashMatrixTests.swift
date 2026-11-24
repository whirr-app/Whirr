import Foundation
import GRDB
import TestSupport
import Testing

@testable import ABSApi
@testable import Persistence
@testable import SyncEngine

/// Podcast-specific crash matrix. Each recovery assertion opens the same on-disk
/// database twice: recovery must converge on the first launch and remain a no-op on the second.
@Suite struct PodcastCrashMatrixTests {
  @Test
  func refreshCommitDeletionInferenceAndShowRemovalRemainAtomicAcrossTwoRelaunches() async throws {
    let env = try await PodcastCrashEnvironment()
    let initial = [
      env.episode("episode-a"),
      env.episode("episode-b"),
    ]
    do {
      let database = try env.openDatabase()
      try PodcastRefreshStore(database: database).apply(
        env.refresh(initial, complete: true), decideProgress: { _ in .applyServer })
    }

    // Pre-commit crash cut at the real transaction boundary. `apply` writes every episode row,
    // the deletion inference and the show's diagnostic fields in one GRDB transaction, so a
    // failure part-way must leave none of it behind. A connection-scoped trigger aborts the last
    // episode insert, so "episode-b"'s update and the generation bump have already happened
    // inside the transaction when it unwinds. No production seam needed.
    do {
      let database = try env.openDatabase()
      try await env.installEpisodeInsertAbortTrigger(database, serverEpisodeId: "episode-cut")
      #expect(throws: DatabaseError.self) {
        try PodcastRefreshStore(database: database).apply(
          env.refresh(
            [env.episode("episode-b", title: "renamed"), env.episode("episode-cut")],
            complete: true, autoDownloadEpisodes: true),
          decideProgress: { _ in .applyServer })
      }
    }
    for _ in 0..<2 {
      let database = try env.openDatabase()
      let rows = try await env.fetchEpisodes(database)
      #expect(rows.map(\.serverEpisodeId) == ["episode-a", "episode-b"])
      #expect(rows.allSatisfy { !$0.softDeleted })
      #expect(rows.map(\.title) == ["episode-a", "episode-b"], "no partially applied episode edit")
      #expect(rows.allSatisfy { $0.lastSeenGeneration == 1 }, "the generation bump rolled back too")
      let show = try #require(try await database.readAsync { db in try ItemRecord.fetchOne(db, key: env.itemRowId) })
      #expect(show.podcastAutoDownloadEpisodes == nil, "the show's diagnostic fields rolled back too")
    }

    // Deletion inference commits as one unit. Re-applying the same complete response models
    // recovery running twice and must neither duplicate nor delete further.
    for _ in 0..<2 {
      let database = try env.openDatabase()
      try PodcastRefreshStore(database: database).apply(
        env.refresh([env.episode("episode-b")], complete: true),
        decideProgress: { _ in .applyServer })
      let rows = try await env.fetchEpisodes(database)
      #expect(rows.count == 2)
      #expect(rows.first { $0.serverEpisodeId == "episode-a" }?.softDeleted == true)
      #expect(rows.first { $0.serverEpisodeId == "episode-b" }?.softDeleted == false)
    }

    // Show removal is a single durable row transition; a second recovery pass is a no-op and
    // cannot manufacture another show or episode.
    do {
      let database = try env.openDatabase()
      try await database.writeAsync { db in
        var show = try #require(try ItemRecord.fetchOne(db, key: env.itemRowId))
        show.softDeleted = true
        try show.update(db)
      }
    }
    for _ in 0..<2 {
      let database = try env.openDatabase()
      let show = try await database.readAsync { db in
        try ItemRecord.fetchOne(db, key: env.itemRowId)
      }
      #expect(show?.softDeleted == true)
      #expect(try await env.fetchEpisodes(database).count == 2)
    }
  }

  @Test
  func queueReorderPopAndPlaybackBoundariesConvergeWithoutDuplicateRowsOrListening() async throws {
    let env = try await PodcastCrashEnvironment()
    try env.seedEpisodes()

    do {
      let database = try env.openDatabase()
      let queue = ListeningQueueStore(database: database, accountId: env.accountId)
      for id in ["episode-a", "episode-b", "episode-c"] {
        let identity = try #require(
          ListeningIdentity.podcastEpisode(
            itemID: PodcastCrashEnvironment.itemID, episodeID: id))
        try await queue.append(
          identity: identity)
      }
      let cuttingQueue = ListeningQueueStore(
        database: database, accountId: env.accountId,
        mutationCheckpoint: { checkpoint in
          if checkpoint == .afterTemporaryRenumber { throw PodcastMatrixCut() }
        })
      let episodeC = try #require(
        ListeningIdentity.podcastEpisode(
          itemID: PodcastCrashEnvironment.itemID, episodeID: "episode-c"))
      let rowC = try #require(
        await cuttingQueue.fetchQueue().first { $0.identity == episodeC }?.id)
      await #expect(throws: PodcastMatrixCut.self) {
        try await cuttingQueue.move(rowID: rowC, to: 0)
      }
    }

    for _ in 0..<2 {
      let queue = ListeningQueueStore(database: try env.openDatabase(), accountId: env.accountId)
      #expect(
        await queue.fetchQueue().map(\.identity.episodeID)
          == ["episode-a", "episode-b", "episode-c"])
    }

    let firstEpisodeId = try await env.episodeRowId("episode-a")
    let secondEpisodeId = try await env.episodeRowId("episode-b")
    let firstSessionId: Int64
    do {
      let database = try env.openDatabase()
      let outbox = try OutboxStore(database: database)
      let sessions = PlaybackSessionStore(database: database, outbox: outbox)

      // `/play` returned: its id is persisted before any later preparation can crash.
      let online = try sessions.startSession(
        accountId: env.accountId, clientSessionId: "online-a", itemId: env.itemRowId,
        podcastEpisodeId: firstEpisodeId, startedAt: env.now)
      firstSessionId = try #require(online.id)
      _ = try sessions.setServerSessionId(sessionId: firstSessionId, serverSessionId: "server-a")
    }
    for _ in 0..<2 {
      let database = try env.openDatabase()
      let sessions = PlaybackSessionStore(database: database, outbox: try OutboxStore(database: database))
      #expect(try sessions.fetchSession(id: firstSessionId)?.serverSessionId == "server-a")
      #expect(try await env.sessionCount(database) == 1)
    }

    // Use the local-session path for the final tick/close/next-start cut: close atomically freezes
    // the exact delta and one upload row, queue pop is idempotent, and the next episode starts
    // once.
    let localSessionId: Int64
    do {
      let database = try env.openDatabase()
      try await database.writeAsync { db in
        var online = try #require(try PlaybackSessionRecord.fetchOne(db, key: firstSessionId))
        online.state = .quarantined
        try online.update(db)
      }
      let outbox = try OutboxStore(database: database)
      let sessions = PlaybackSessionStore(database: database, outbox: outbox)
      let local = try sessions.startSession(
        accountId: env.accountId, clientSessionId: "local-a", itemId: env.itemRowId,
        podcastEpisodeId: firstEpisodeId, startedAt: env.now, isOffline: true)
      localSessionId = try #require(local.id)
      _ = try sessions.recordLocalTick(
        sessionId: localSessionId,
        tick: env.tick(position: 40, delta: 7, sequence: 1, finished: true))
      _ = try sessions.closeLocalSession(
        sessionId: localSessionId,
        tick: PlaybackSessionClose(
          globalPosition: 42, deltaSecondsSinceLastSend: 3, localSequence: 2,
          now: env.now.addingTimeInterval(2)))
      let queue = ListeningQueueStore(database: database, accountId: env.accountId)
      let episodeA = try #require(
        ListeningIdentity.podcastEpisode(
          itemID: PodcastCrashEnvironment.itemID, episodeID: "episode-a"))
      try await queue.acknowledgeStarted(
        identity: episodeA, rowID: nil)
      _ = try sessions.startSession(
        accountId: env.accountId, clientSessionId: "local-b", itemId: env.itemRowId,
        podcastEpisodeId: secondEpisodeId, startedAt: env.now.addingTimeInterval(3),
        isOffline: true)
    }

    for _ in 0..<2 {
      let database = try env.openDatabase()
      let outbox = try OutboxStore(database: database)
      let sessions = PlaybackSessionStore(database: database, outbox: outbox)
      let queue = ListeningQueueStore(database: database, accountId: env.accountId)
      let episodeA = try #require(
        ListeningIdentity.podcastEpisode(
          itemID: PodcastCrashEnvironment.itemID, episodeID: "episode-a"))
      try await queue.acknowledgeStarted(
        identity: episodeA, rowID: nil)
      #expect(
        await queue.fetchQueue().map(\.identity.episodeID) == ["episode-b", "episode-c"])
      #expect(try sessions.fetchSession(id: localSessionId)?.listenedDeltaSeconds == 10)
      #expect(try outbox.fetchQueuedLocalSessionUploads(accountId: env.accountId, limit: 10).count == 1)
      #expect(try await env.sessionCount(database) == 3)
    }
  }

  @Test
  func episodeTempMoveCompletionRetryProducesOneDownloadAcrossTwoRelaunches() async throws {
    let env = try await PodcastCrashEnvironment()
    try env.seedEpisodes()
    let episodeId = try await env.episodeRowId("episode-a")
    let downloadId: Int64
    let relativePath: String
    do {
      let database = try env.openDatabase()
      let store = try DownloadStore(database: database)
      relativePath = DownloadFileStore.destinationRelativePath(
        accountId: env.accountId, itemId: env.itemRowId, podcastEpisodeId: episodeId,
        orderIndex: 0, serverFileIno: "episode-a-ino", mimeType: "audio/mpeg")
      let row = try store.enqueue(
        accountId: env.accountId, itemId: env.itemRowId, podcastEpisodeId: episodeId,
        serverFileIno: "episode-a-ino", orderIndex: 0, destinationRelativePath: relativePath,
        expectedBytes: 4, expectedMimeType: "audio/mpeg", fileDurationSeconds: 42)
      downloadId = try #require(row.id)
      _ = try await store.transitionAsync(downloadId: downloadId, to: .downloading)
      let destination = env.downloadsRoot.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data([9, 9, 9, 9]).write(to: destination)
    }

    do {
      let database = try env.openDatabase()
      let store = try DownloadStore(database: database)
      #expect(try store.fetch(downloadId: downloadId)?.state == .interrupted)
      _ = try await store.transitionAsync(downloadId: downloadId, to: .pending)
      _ = try await store.transitionAsync(downloadId: downloadId, to: .downloading)
      let files = try DownloadFileStore(
        rootURL: env.downloadsRoot, fileAttributes: POSIXFileAttributeApplier(),
        downloadStore: store)
      let temp = env.root.appendingPathComponent("retry.tmp")
      try Data([1, 2, 3, 4]).write(to: temp)
      _ = try files.completeTransfer(
        downloadId: downloadId, temporaryFileURL: temp,
        response: DownloadTransferResponse(
          httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 4))
    }
    for _ in 0..<2 {
      let database = try env.openDatabase()
      let store = try DownloadStore(database: database)
      #expect(try store.fetch(downloadId: downloadId)?.state == .completed)
      #expect(try await env.downloadCount(database) == 1)
      #expect(try Data(contentsOf: env.downloadsRoot.appendingPathComponent(relativePath)) == Data([1, 2, 3, 4]))
    }
  }

  @Test
  func offlineUploadResponseBeforeAckReplaysOnceThenRecoveryIsAStableNoOp() async throws {
    let env = try await PodcastCrashEnvironment()
    try env.seedEpisodes()
    let episodeId = try await env.episodeRowId("episode-a")
    let sessionId: Int64
    let clientSessionId = "offline-response-cut"
    var material: PlaybackSessionStore.LocalSessionUploadMaterial!
    let http = FakeHTTPClient()
    let clientAndAccount = try env.makeClient(http: http)

    do {
      let database = try env.openDatabase()
      let outbox = try OutboxStore(database: database)
      let sessions = PlaybackSessionStore(database: database, outbox: outbox)
      let session = try sessions.startSession(
        accountId: env.accountId, clientSessionId: clientSessionId, itemId: env.itemRowId,
        podcastEpisodeId: episodeId, startedAt: env.now, isOffline: true)
      sessionId = try #require(session.id)
      _ = try sessions.recordLocalTick(
        sessionId: sessionId,
        tick: env.tick(position: 30, delta: 11, sequence: 1, finished: false))
      _ = try sessions.closeLocalSession(
        sessionId: sessionId,
        tick: PlaybackSessionClose(
          globalPosition: 30, deltaSecondsSinceLastSend: 0, localSequence: 2,
          now: env.now.addingTimeInterval(2)))
      let operation = try #require(
        try outbox.fetchQueuedLocalSessionUploads(accountId: env.accountId, limit: 10).first)
      _ = try await outbox.transitionAsync(operationId: try #require(operation.id), to: .sending)
      material = try sessions.fetchLocalSessionUploadMaterial(sessionId: sessionId)

      http.enqueue(makeLocalAllResponse([(id: clientSessionId, success: true)]))
      let response = try await clientAndAccount.client.syncLocalSessions(
        account: clientAndAccount.account,
        sessions: [
          LocalPlaybackSession(
            id: clientSessionId, libraryItemID: material.itemServerId,
            episodeID: material.episodeServerId, currentTime: 30,
            timeListening: 11, startedAt: material.startedAt,
            updatedAt: material.updatedAt)
        ])
      #expect(response.acknowledged.count == 1)
      #expect(response.acknowledged.contains(clientSessionId))
      // Crash: the response arrived, but acknowledgeLocalUpload never committed.
    }

    // Launch one resets the stranded `.sending` row and performs the single safe replay.
    do {
      let database = try env.openDatabase()
      let outbox = try OutboxStore(database: database)
      http.enqueue(makeLocalAllResponse([(id: clientSessionId, success: true)]))
      let drainer = OutboxDrainer(
        outboxStore: outbox, database: database, absClient: clientAndAccount.client,
        account: clientAndAccount.account, accountId: env.accountId)
      await drainer.drainLocalSessionUploads()
      #expect(
        try PlaybackSessionStore(database: database, outbox: outbox).fetchSession(id: sessionId)
          == nil)
    }

    // Launch two sees the acknowledgement and makes no third request.
    do {
      let database = try env.openDatabase()
      let outbox = try OutboxStore(database: database)
      let drainer = OutboxDrainer(
        outboxStore: outbox, database: database, absClient: clientAndAccount.client,
        account: clientAndAccount.account, accountId: env.accountId)
      await drainer.drainLocalSessionUploads()
    }
    #expect(http.requests.count == 2, "one original attempt plus one lost-ack replay")
    #expect(http.requests.allSatisfy { $0.url.path == "/api/session/local-all" })
    // Every replay stays on the configured ABS server; no request reaches a podcast's RSS origin.
    #expect(http.requests.allSatisfy { $0.url.scheme == "https" })
    #expect(http.requests.allSatisfy { $0.url.host == "podcast-matrix.example.test" })
  }

  @Test
  func logoutJournalRecoveryRunsTwiceWithoutAnotherRequestOrResidualPodcastData() async throws {
    let harness = try AccountRemovalTestHarness()
    await harness.stubSuccessfulLogout()
    await harness.stubSuccessfulLogout()
    let accountId: Int64
    do {
      let database = try harness.openDatabase()
      accountId = try await harness.seedSignedInAccount(database: database, withDownloadFile: true)
      try await database.writeAsync { db in
        var library = LibraryRecord(
          accountId: accountId, serverLibraryId: "podcasts", mediaType: "podcast",
          name: "Podcasts")
        try library.insert(db)
        let libraryId = try #require(library.id)
        var show = ItemRecord(
          accountId: accountId, libraryId: libraryId, serverItemId: "show",
          mediaKind: "podcast", title: "Show", sortTitle: "show")
        try show.insert(db)
        let showId = try #require(show.id)
        var episode = PodcastEpisodeRecord(
          accountId: accountId, itemId: showId, serverEpisodeId: "episode",
          title: "Episode", lastSeenGeneration: 1)
        try episode.insert(db)
        var queue = ListeningQueueEntryRecord(
          accountId: accountId, itemId: showId, podcastEpisodeId: episode.id,
          position: 0)
        try queue.insert(db)
      }
      let coordinator = harness.makeCoordinator(database: database)
      await coordinator.setCrashAfterStepForTesting(.journalWritten)
      await #expect(throws: AccountRemovalCoordinator.SimulatedCrashForTesting.self) {
        try await coordinator.confirmRemoval()
      }
    }

    for _ in 0..<2 {
      let database = try harness.openDatabase()
      try await harness.makeCoordinator(database: database).resumeIfNeeded()
      #expect(try harness.fetchAccountRow(database: database) == nil)
      #expect(try await database.readAsync { db in try PodcastEpisodeRecord.fetchCount(db) } == 0)
      #expect(try await database.readAsync { db in try ListeningQueueEntryRecord.fetchCount(db) } == 0)
    }
    let logoutRequests = await harness.transport.requests.filter { $0.url.path == "/logout" }
    #expect(logoutRequests.count == 1)
    #expect(
      FileManager.default.fileExists(
        atPath: harness.downloadsRootURL.appendingPathComponent("\(accountId)").path) == false)
  }
}

private struct PodcastMatrixCut: Error {}

private final class PodcastCrashEnvironment: @unchecked Sendable {
  static let itemID = "podcast-show"
  private let fixture: SuiteOnDiskDatabases
  private let scope: OnDiskDatabaseScope
  let root: URL
  let downloadsRoot: URL
  let databaseURL: URL
  let accountId: Int64
  let itemRowId: Int64
  let now = Date(timeIntervalSince1970: 1_700_000_000)
  private var currentDatabase: AppDatabase?

  init() async throws {
    let fixture = try await SuiteOnDiskDatabases.acquire(named: "PodcastCrashEnvironment")
    self.fixture = fixture
    scope = fixture.scope
    root = scope.directoryURL
    downloadsRoot = root.appendingPathComponent("Downloads", isDirectory: true)
    databaseURL = scope.url()
    let database = try scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    let account = try AccountDAO(database: database).save(
      AccountRecord(
        clientUUID: "device-uuid", serverBaseURL: "https://podcast-matrix.example.test",
        serverUserId: "user-1", serverVersion: "2.35.1"))
    let localAccountId = try #require(account.id)
    accountId = localAccountId
    let libraryId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: localAccountId, serverLibraryId: "podcasts", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      return try #require(library.id)
    }
    itemRowId = try #require(
      try ItemDAO(database: database).upsert(
        ItemRecord(
          accountId: localAccountId, libraryId: libraryId, serverItemId: Self.itemID,
          mediaKind: "podcast", title: "Show", sortTitle: "show")
      ).id)
    scope.close(database)
  }

  deinit {}

  func openDatabase() throws -> AppDatabase {
    if let currentDatabase {
      scope.close(currentDatabase)
      self.currentDatabase = nil
    }
    let database = try scope.open(at: databaseURL, fileAttributes: POSIXFileAttributeApplier())
    currentDatabase = database
    return database
  }

  func episode(_ id: String, title: String? = nil) -> PodcastEpisodeRecord {
    PodcastEpisodeRecord(
      accountId: accountId, itemId: itemRowId, serverEpisodeId: id, title: title ?? id,
      durationSeconds: 100, lastSeenGeneration: 0)
  }

  func refresh(
    _ episodes: [PodcastEpisodeRecord],
    complete: Bool,
    autoDownloadEpisodes: Bool? = nil
  ) -> PodcastRefreshApplication {
    PodcastRefreshApplication(
      accountId: accountId, itemId: itemRowId, episodes: episodes,
      autoDownloadEpisodes: autoDownloadEpisodes,
      responseIsComplete: complete)
  }

  /// Forces one episode insert inside `PodcastRefreshStore.apply`'s transaction to fail, so the
  /// rollback can be observed. `TEMP` scopes the trigger to this connection: it never reaches the
  /// on-disk schema and disappears with the pool, so every reopened database below is pristine.
  func installEpisodeInsertAbortTrigger(
    _ database: AppDatabase, serverEpisodeId: String
  ) async throws {
    // SQLite forbids bound parameters in DDL, so the (test-owned, literal) id is interpolated.
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          CREATE TEMP TRIGGER podcastRefreshPreCommitCut
          AFTER INSERT ON podcastEpisode
          WHEN NEW.serverEpisodeId = '\(serverEpisodeId)'
          BEGIN
            SELECT RAISE(ABORT, 'pre-commit cut');
          END
          """)
    }
  }

  func seedEpisodes() throws {
    let database = try openDatabase()
    defer { scope.close(database) }
    try PodcastRefreshStore(database: database).apply(
      refresh(
        [episode("episode-a"), episode("episode-b"), episode("episode-c")],
        complete: true),
      decideProgress: { _ in .applyServer })
  }

  func episodeRowId(_ id: String) async throws -> Int64 {
    let database = try openDatabase()
    defer { scope.close(database) }
    return try await database.readAsync { db in
      try #require(
        try PodcastEpisodeRecord
          .filter(Column("serverEpisodeId") == id)
          .fetchOne(db)?.id)
    }
  }

  func fetchEpisodes(_ database: AppDatabase) async throws -> [PodcastEpisodeRecord] {
    try await database.readAsync { db in
      try PodcastEpisodeRecord.order(Column("serverEpisodeId")).fetchAll(db)
    }
  }

  func sessionCount(_ database: AppDatabase) async throws -> Int {
    try await database.readAsync { db in try PlaybackSessionRecord.fetchCount(db) }
  }

  func downloadCount(_ database: AppDatabase) async throws -> Int {
    try await database.readAsync { db in try DownloadRecord.fetchCount(db) }
  }

  func tick(
    position: Double, delta: Double, sequence: Int64, finished: Bool
  ) -> PlaybackTick {
    PlaybackTick(
      globalPosition: position, isFinished: finished, deltaSecondsSinceLastTick: delta,
      localSequence: sequence, originKey: "device-uuid", segmentKey: "segment-\(sequence)",
      now: now.addingTimeInterval(Double(sequence)))
  }

  func makeClient(http: any HTTPClienting) throws -> (client: ABSClient, account: TokenAccount) {
    let server = try ABSServerConfig(
      url: try #require(URL(string: "https://podcast-matrix.example.test")))
    let clientUUID = "device-uuid"
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user-1")
    let tokens = InMemoryTokenStore()
    try tokens.save(
      TokenPair(accessToken: "access-token", refreshToken: "refresh-token"), for: account)
    return (ABSClient(server: server, httpClient: http, tokenStore: tokens), account)
  }
}
