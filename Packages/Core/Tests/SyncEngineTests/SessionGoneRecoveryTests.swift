import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// The session-gone-404 classification (`OutboxDrainer`, ahead of the generic permanent-error
/// branch) and its recovery path (`PlaybackSessionStore.markSessionGone` +
/// `PlaybackSessionCoordinator.recoverFromSessionGone`). `/sync`'s `404` is unambiguous; `/close`'s
/// is reconciled against `GET /api/session/{id}` plus authoritative server progress before it
/// counts as acknowledged (API-CONVENTIONS.md). Ordinary send/ack classification for session
/// kinds is in `SessionOutboxDrainTests`.
@Suite("Session-gone-404 classification and recovery")
struct SessionGoneRecoveryTests {

  private static let itemID = GoneRecoveryHarness.itemID
  private static let syncPath = "/api/session/server-session-1/sync"
  private static let closePath = "/api/session/server-session-1/close"
  private static let getSessionPath = "/api/session/server-session-1"
  private static let mePath = "/api/me"
  private static let playPath = "/api/items/\(GoneRecoveryHarness.itemID)/play"
  private static let episodePlayPath =
    "/api/items/\(GoneRecoveryHarness.itemID)/play/\(GoneRecoveryHarness.episodeID)"
  private static let itemProgressPath = "/api/me/progress/\(GoneRecoveryHarness.itemID)"
  private static let episodeProgressPath =
    "/api/me/progress/\(GoneRecoveryHarness.itemID)/\(GoneRecoveryHarness.episodeID)"

  // MARK: - `/sync` 404 is unambiguous session-gone

  @Test func syncNotFoundMarksTheSessionDeadWithoutDeadLettering() async throws {
    let harness = try await GoneRecoveryHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.recordTick(sessionId: sessionId, position: 50, delta: 10, localSequence: 1)
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())

    let session = try harness.sessionStore.fetchSession(id: sessionId)
    #expect(session?.state == .gone)
    let rows = try harness.sessionRows(sessionId)
    #expect(rows.isEmpty, "no row survives in any state, including deadLetter")
  }

  @Test func syncNotFoundPreservesTheLastPositionThroughTheOrdinaryProgressPathNeverWithAnIdField() async throws {
    let harness = try await GoneRecoveryHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.recordTick(sessionId: sessionId, position: 50, delta: 10, localSequence: 1)
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    await harness.http.stub(
      path: "/api/me/progress/\(Self.itemID)", responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    // One pass suffices: the preserved `progress`-kind row is created after `drainOutbox`
    // snapshots its entity keys, so the same pass must re-fetch and drain it. Otherwise the rescued
    // position waits for the next lifecycle trigger, which overnight strands it.
    await harness.drainer.drainOutbox(now: Date())

    let progressRequests = await harness.http.requests(forPath: "/api/me/progress/\(Self.itemID)")
    #expect(progressRequests.count == 1)
    let object = try #require(JSONSerialization.jsonObject(with: progressRequests[0].body ?? Data()) as? [String: Any])
    #expect(object["currentTime"] as? Double == 50)
    #expect(object["id"] == nil, "rule 11: never an `id` field in a progress payload")
  }

  @Test func syncNotFoundEmitsExactlyOnePrivacySafeLostDeltaDiagnostic() async throws {
    let harness = try await GoneRecoveryHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.recordTick(sessionId: sessionId, position: 50, delta: 10, localSequence: 1)
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())

    #expect(harness.diagnostics.recorded.count == 1)
    let event = try #require(harness.diagnostics.recorded.first)
    #expect(event.category == .sessionLostDelta)
    #expect(event.statusClass == .clientError)
    #expect(event.endpointTemplate?.path == "/api/session/:id/sync")
  }

  @Test func syncNotFoundDiscardsTheDeltaExactlyOnceAndNeverCarriesItIntoAReplacement() async throws {
    let harness = try await GoneRecoveryHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.recordTick(sessionId: sessionId, position: 50, delta: 10, localSequence: 1)
    await harness.coordinator.notifyPlaybackPhase(.playing)
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    await harness.stubPlayResponse(serverSessionID: "server-session-2")

    await harness.drainer.drainOutbox(now: Date())

    let deadSession = try harness.sessionStore.fetchSession(id: sessionId)
    #expect(deadSession?.listenedDeltaSeconds == 0, "discarded on the dead session itself")
    let replacement = try #require(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId))
    #expect(replacement.id != sessionId)
    #expect(replacement.serverSessionId == "server-session-2")
    #expect(replacement.listenedDeltaSeconds == 0, "never reattributed to the replacement")
  }

  // MARK: - Recoverable active-playback result routed back to the coordinator

  @Test func whilePlayingSyncNotFoundOpensOneZeroDeltaReplacementThroughTheNormalCoordinatorPath() async throws {
    let harness = try await GoneRecoveryHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.recordTick(sessionId: sessionId, position: 50, delta: 10, localSequence: 1)
    await harness.coordinator.notifyPlaybackPhase(.playing)
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    await harness.stubPlayResponse(serverSessionID: "server-session-2")

    await harness.drainer.drainOutbox(now: Date())

    let playRequests = await harness.http.requests(forPath: Self.playPath)
    #expect(playRequests.count == 1, "a replacement session started through the normal /play path")
    let replacement = try #require(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId))
    #expect(replacement.serverSessionId == "server-session-2")
    #expect(replacement.itemId == harness.itemRowId)
  }

  @Test func activePodcastEpisodeSyncNotFoundReopensTheSameEpisodeAndPreservesOnlyEpisodeProgress() async throws {
    let harness = try await GoneRecoveryHarness()
    let sessionId = try harness.seedActiveSession(podcastEpisodeId: harness.episodeRowId)
    _ = try harness.recordTick(sessionId: sessionId, position: 50, delta: 10, localSequence: 1)
    await harness.coordinator.notifyPlaybackPhase(.playing)
    await harness.http.stub(
      path: Self.syncPath,
      responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    await harness.stubPlayResponse(
      serverSessionID: "server-session-2", episodeID: GoneRecoveryHarness.episodeID)
    await harness.http.stub(
      path: Self.episodeProgressPath, responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())
    // A second pass drains the newly-preserved `progress`-kind row, which must reach the episode's
    // own progress route, not the show's (API-CONVENTIONS.md).
    await harness.drainer.drainOutbox(now: Date())

    let progressRequests = await harness.http.requests(forPath: Self.episodeProgressPath)
    #expect(progressRequests.count == 1)
    let progressRequest = try #require(progressRequests.first)
    #expect(progressRequest.routeTemplate == "/api/me/progress/:id/:episodeId")
    let progressBody = try #require(
      JSONSerialization.jsonObject(with: progressRequest.body ?? Data()) as? [String: Any])
    #expect(progressBody["currentTime"] as? Double == 50)
    #expect(progressBody["id"] == nil, "rule 11: never an `id` field in a progress payload")
    #expect(
      await harness.http.requests(forPath: Self.itemProgressPath).isEmpty,
      "the show's own item-level progress is never written by an episode-scoped row")

    #expect(await harness.http.requestCount(forPath: Self.episodePlayPath) == 1)
    #expect(await harness.http.requests(forPath: Self.playPath).isEmpty)
    let recoveryCalls = await harness.recovery.calls
    #expect(recoveryCalls.count == 1)
    #expect(recoveryCalls.first?.itemID == GoneRecoveryHarness.itemID)
    #expect(recoveryCalls.first?.episodeID == GoneRecoveryHarness.episodeID)
    let replacement = try #require(
      try harness.sessionStore.fetchActiveSession(accountId: harness.accountId))
    #expect(replacement.serverSessionId == "server-session-2")
    #expect(replacement.itemId == harness.itemRowId)
    #expect(replacement.podcastEpisodeId == harness.episodeRowId)

    let episodeProgress = try #require(
      try MediaProgressDAO(database: harness.database).fetchCurrent(
        accountId: harness.accountId,
        identity: .episode(
          itemId: harness.itemRowId, podcastEpisodeId: harness.episodeRowId)))
    #expect(episodeProgress.currentTime == 50)
    #expect(
      try MediaProgressDAO(database: harness.database).fetchCurrent(
        accountId: harness.accountId, identity: .item(itemId: harness.itemRowId)) == nil)
  }

  @Test func whilePausedSyncNotFoundOpensNoReplacement() async throws {
    let harness = try await GoneRecoveryHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.recordTick(sessionId: sessionId, position: 50, delta: 10, localSequence: 1)
    await harness.coordinator.notifyPlaybackPhase(.playing)
    await harness.coordinator.notifyPlaybackPhase(.paused)
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())

    #expect(await harness.http.requests(forPath: Self.playPath).isEmpty)
    #expect(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId) == nil)
  }

  @Test func whileNeverPlayingSyncNotFoundOpensNoReplacement() async throws {
    let harness = try await GoneRecoveryHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.recordTick(sessionId: sessionId, position: 50, delta: 10, localSequence: 1)
    // No `notifyPlaybackPhase` call: mirrors a session that was open but never reported as
    // actively playing (cadence phase defaults to `.idle`).
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())

    #expect(await harness.http.requests(forPath: Self.playPath).isEmpty)
    #expect(try harness.sessionStore.fetchActiveSession(accountId: harness.accountId) == nil)
  }

  // MARK: - `/close` 404 is reconciled, never blindly replayed as idempotent

  @Test func closeNotFoundThatLandedOnServerAcknowledgesWithoutSessionGoneOrADiagnostic() async throws {
    let harness = try await GoneRecoveryHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.recordClose(sessionId: sessionId, position: 100, delta: 3, localSequence: 1)
    await harness.http.stub(
      path: Self.closePath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    // `GET /api/session/{id}` 404s too (closed either way), so reconciliation falls through to
    // authoritative progress, which shows our final position already landed server-side.
    await harness.http.stub(
      path: Self.getSessionPath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    await harness.http.stub(path: Self.mePath, responses: [harness.meResponse(itemID: Self.itemID, currentTime: 100)])

    await harness.drainer.drainOutbox(now: Date())

    #expect(
      try harness.sessionStore.fetchSession(id: sessionId) == nil,
      "acknowledged like a normal close - the row and session are gone")
    #expect(harness.diagnostics.recorded.isEmpty, "never a session-gone diagnostic when the close actually landed")
    let recovered = await harness.recovery.calls
    #expect(recovered.isEmpty, "no replacement is ever requested for a close that landed")
  }

  @Test func closeNotFoundStillOpenOnGetIsInconclusiveAndRetriesWithoutReplayingTheCloseItself() async throws {
    let harness = try await GoneRecoveryHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.recordClose(sessionId: sessionId, position: 100, delta: 3, localSequence: 1)
    await harness.http.stub(
      path: Self.closePath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    // Still open server-side: the close has not landed yet.
    await harness.http.stub(path: Self.getSessionPath, responses: [harness.openSessionResponse()])

    await harness.drainer.drainOutbox(now: Date(timeIntervalSince1970: 1_700_000_000), randomUnit: { 1 })

    #expect(await harness.http.requestCount(forPath: Self.closePath) == 1, "never blindly replayed")
    #expect(
      await harness.http.requests(forPath: Self.mePath).isEmpty,
      "a still-open session short-circuits before checking progress")
    let session = try #require(try harness.sessionStore.fetchSession(id: sessionId))
    #expect(session.state == .active, "neither acknowledged nor marked gone while genuinely inconclusive")
    #expect(session.closePending == true)
    let rows = try harness.sessionRows(sessionId)
    #expect(rows.first?.state == .retryWaiting)
    #expect(harness.diagnostics.recorded.isEmpty)
  }

  @Test func closeNotFoundWithNoAuthoritativeProgressIsTreatedAsSessionGone() async throws {
    let harness = try await GoneRecoveryHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.recordClose(sessionId: sessionId, position: 100, delta: 3, localSequence: 1)
    await harness.http.stub(
      path: Self.closePath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    await harness.http.stub(
      path: Self.getSessionPath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    // Authoritative progress has nothing for this item, so the close never landed.
    await harness.http.stub(path: Self.mePath, responses: [harness.meResponse(itemID: nil, currentTime: nil)])
    await harness.http.stub(
      path: "/api/me/progress/\(Self.itemID)", responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())

    let session = try harness.sessionStore.fetchSession(id: sessionId)
    #expect(session?.state == .gone)
    #expect(harness.diagnostics.recorded.count == 1)
    #expect(harness.diagnostics.recorded.first?.endpointTemplate?.path == "/api/session/:id/close")
  }

  // MARK: - Restricted to session endpoints

  @Test func anUnrelatedProgressNotFoundStillDeadLettersWhileASessionNotFoundInTheSameDrainGoesGone() async throws {
    let harness = try await GoneRecoveryHarness()
    let sessionId = try harness.seedActiveSession()
    _ = try harness.recordTick(sessionId: sessionId, position: 50, delta: 10, localSequence: 1)
    _ = try harness.outbox.enqueueProgress(
      accountId: harness.accountId, entityKey: "unrelated-item", podcastEpisodeId: nil, coalescingKey: "unrelated-item",
      localSequence: 1, payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    await harness.http.stub(path: Self.syncPath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])
    await harness.http.stub(
      path: "/api/me/progress/unrelated-item", responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])

    await harness.drainer.drainOutbox(now: Date())

    let session = try harness.sessionStore.fetchSession(id: sessionId)
    #expect(session?.state == .gone, "the session endpoint's 404 is classified as session-gone")
    let unrelatedRow = try harness.database.read { db in
      try OutboxOperationRecord.filter(Column("entityKey") == "unrelated-item").fetchOne(db)
    }
    #expect(unrelatedRow?.state == .deadLetter, "an unrelated 404 still follows the generic permanent-error policy")
    #expect(unrelatedRow?.deadLetterReason == "notFound")
  }

  // MARK: - `PlaybackSessionStore.markSessionGone`: isolation, atomicity, failure-before-commit

  @Test func markSessionGoneRemovesOnlyThisSessionsOutboxRowsNeverAnotherSessions() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertGoneTestAccountAndLibrary(database)
    let itemAId = try await insertGoneTestItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-a")
    let itemBId = try await insertGoneTestItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "item-b")
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    // Session A is quarantined out-of-band (simulating an already-superseded session that still
    // has a queued row) so Session B can become the account's one active session. The v1 schema
    // forbids two simultaneously-`active` sessions, but two sessions each holding their own
    // queued live-session rows is the "no other session" case worth proving.
    let sessionA = try store.startSession(
      accountId: accountId, clientSessionId: "session-a", itemId: itemAId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try store.recordTick(
      sessionId: sessionA.id!,
      tick: PlaybackTick(
        globalPosition: 5, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1, originKey: "d",
        segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_005)))
    try await database.writeAsync { db in
      var record = try PlaybackSessionRecord.fetchOne(db, key: sessionA.id!)!
      record.state = .quarantined
      try record.update(db)
    }

    let sessionB = try store.startSession(
      accountId: accountId, clientSessionId: "session-b", itemId: itemBId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_010))
    _ = try store.recordTick(
      sessionId: sessionB.id!,
      tick: PlaybackTick(
        globalPosition: 8, isFinished: false, deltaSecondsSinceLastTick: 3, localSequence: 1, originKey: "d",
        segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_015)))

    let outcome = try store.markSessionGone(sessionId: sessionA.id!, now: Date(timeIntervalSince1970: 1_700_000_020))
    #expect(outcome?.itemServerId == "item-a")

    let sessionARows = try database.read { db in
      try OutboxOperationRecord.filter(Column("playbackSessionId") == sessionA.id!).fetchAll(db)
    }
    #expect(sessionARows.isEmpty)
    let sessionBRows = try database.read { db in
      try OutboxOperationRecord.filter(Column("playbackSessionId") == sessionB.id!).fetchAll(db)
    }
    #expect(sessionBRows.count == 1, "an unrelated session's own queued row is untouched")

    let refreshedB = try store.fetchSession(id: sessionB.id!)
    #expect(refreshedB?.state == .active, "an unrelated session is never marked gone")
    #expect(refreshedB?.listenedDeltaSeconds == 3, "an unrelated session's delta is never discarded")
  }

  @Test func markSessionGoneIsAtomicAcrossADatabaseReopen() async throws {
    try await withOnDiskDatabases { scope in
      let itemServerId = "item-reopen"
      let database = try scope.open()
      let (accountId, libraryId) = try await insertGoneTestAccountAndLibrary(database)
      let itemId = try await insertGoneTestItem(
        database, accountId: accountId, libraryId: libraryId, serverItemId: itemServerId)
      let outbox = try OutboxStore(database: database)
      let store = PlaybackSessionStore(database: database, outbox: outbox)

      let session = try store.startSession(
        accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000))
      _ = try store.recordTick(
        sessionId: session.id!,
        tick: PlaybackTick(
          globalPosition: 42, isFinished: false, deltaSecondsSinceLastTick: 9, localSequence: 1, originKey: "d",
          segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_005)))

      _ = try store.markSessionGone(sessionId: session.id!, now: Date(timeIntervalSince1970: 1_700_000_010))
      let sessionId = session.id!
      scope.close(database)

      let reopened = try scope.open()
      let recoveredSession = try await reopened.readAsync { db in
        try PlaybackSessionRecord.fetchOne(db, key: sessionId)
      }
      #expect(recoveredSession?.state == .gone)
      #expect(recoveredSession?.listenedDeltaSeconds == 0)

      let survivingSessionRows = try await reopened.readAsync { db in
        try OutboxOperationRecord.filter(Column("playbackSessionId") == sessionId).fetchAll(db)
      }
      #expect(survivingSessionRows.isEmpty)

      let progressRows = try await reopened.readAsync { db in
        try OutboxOperationRecord.filter(Column("operationKind") == OutboxOperationKind.progress.rawValue).fetchAll(db)
      }
      #expect(progressRows.count == 1, "the position-preservation row committed together with the rest")
      #expect(progressRows[0].entityKey == itemServerId)
      #expect(progressRows[0].payloadCurrentTime == 42)
    }
  }

  @Test func markSessionGoneOnAMissingSessionReturnsNilAndTouchesNothing() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertGoneTestAccountAndLibrary(database)
    _ = try await insertGoneTestItem(database, accountId: accountId, libraryId: libraryId, serverItemId: "item-missing")
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let outcome = try store.markSessionGone(sessionId: 999_999, now: Date())

    #expect(outcome == nil)
    let allOutboxRows = try database.read { db in try OutboxOperationRecord.fetchAll(db) }
    #expect(allOutboxRows.isEmpty, "the guard fails before any write - nothing is touched")
  }
}

// MARK: - Test harness

private final class GoneRecoveryHarness: @unchecked Sendable {
  static let itemID = "item_gone_fixture"
  static let episodeID = "episode_gone_fixture"

  let http: SessionScriptedHTTPClient
  let database: AppDatabase
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let client: ABSClient
  let account: TokenAccount
  let accountId: Int64
  let itemRowId: Int64
  let episodeRowId: Int64
  let diagnostics: FakeDiagnosticsRecording
  let recovery: SessionGoneRecoveryRecorder
  let coordinator: PlaybackSessionCoordinator
  let drainer: OutboxDrainer

  init() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://gone.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user-1")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "access-token", refreshToken: "refresh-token"), for: account)
    let http = SessionScriptedHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

    let database = try AppDatabase.inMemory()
    let savedAccount = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString, serverUserId: "user-1",
        serverVersion: "2.35.1")
      try record.save(db)
      return record
    }
    let accountId = try #require(savedAccount.id)

    let libraryId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(accountId: accountId, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: database)
    let itemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: accountId, libraryId: libraryId, serverItemId: Self.itemID, mediaKind: "book", title: "Title",
          sortTitle: "title")
      ).id)
    let episodeRowId = try #require(
      try PodcastEpisodeDAO(database: database).upsert(
        PodcastEpisodeRecord(
          accountId: accountId, itemId: itemRowId, serverEpisodeId: Self.episodeID,
          title: "Episode", lastSeenGeneration: 1)
      ).id)

    let outbox = try OutboxStore(database: database)
    let sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
    let diagnostics = FakeDiagnosticsRecording()
    let recovery = SessionGoneRecoveryRecorder()

    let coordinator = PlaybackSessionCoordinator(
      client: client, database: database, outbox: outbox,
      clock: FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000)),
      scheduler: FakePlaybackCadenceScheduling())

    self.http = http
    self.database = database
    self.outbox = outbox
    self.sessionStore = sessionStore
    self.client = client
    self.account = account
    self.accountId = accountId
    self.itemRowId = itemRowId
    self.episodeRowId = episodeRowId
    self.diagnostics = diagnostics
    self.recovery = recovery
    self.coordinator = coordinator
    drainer = OutboxDrainer(
      outboxStore: outbox, database: database, absClient: client, account: account, accountId: accountId,
      diagnostics: diagnostics,
      notifySessionGoneRecovery: { itemID, episodeID in
        await recovery.record(itemID: itemID, episodeID: episodeID)
        await coordinator.recoverFromSessionGone(itemID: itemID, episodeID: episodeID)
      }
    )
  }

  @discardableResult
  func seedActiveSession(
    clientSessionId: String = UUID().uuidString,
    serverSessionId: String? = "server-session-1",
    podcastEpisodeId: Int64? = nil,
    duration: Double? = 3600,
    startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
  ) throws -> Int64 {
    let started = try sessionStore.startSession(
      accountId: accountId, clientSessionId: clientSessionId, itemId: itemRowId,
      podcastEpisodeId: podcastEpisodeId, duration: duration, startedAt: startedAt)
    let sessionId = try #require(started.id)
    if let serverSessionId {
      _ = try sessionStore.setServerSessionId(sessionId: sessionId, serverSessionId: serverSessionId)
    }
    return sessionId
  }

  @discardableResult
  func recordTick(sessionId: Int64, position: Double, delta: Double, localSequence: Int64) throws
    -> PlaybackSessionRecord
  {
    try sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: position, isFinished: false, deltaSecondsSinceLastTick: delta, localSequence: localSequence,
        originKey: "device-uuid", segmentKey: "seg-\(localSequence)",
        now: Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(Double(localSequence))))
  }

  @discardableResult
  func recordClose(sessionId: Int64, position: Double, delta: Double, localSequence: Int64) throws
    -> PlaybackSessionRecord
  {
    try sessionStore.close(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: position, deltaSecondsSinceLastSend: delta, localSequence: localSequence,
        now: Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(Double(localSequence))))
  }

  func sessionRows(_ sessionId: Int64) throws -> [OutboxOperationRecord] {
    try database.read { db in
      try OutboxOperationRecord.filter(Column("playbackSessionId") == sessionId).fetchAll(db)
    }
  }

  func stubPlayResponse(serverSessionID: String, episodeID: String? = nil) async {
    let object: [String: Any] = [
      "id": serverSessionID,
      "libraryItemId": Self.itemID,
      "mediaType": "book",
      "displayTitle": "Fixture Book",
      "duration": 3600,
      "currentTime": 0,
      "playMethod": 0,
      "deviceInfo": ["deviceId": "server-echoed-id"],
      "audioTracks": [
        [
          "index": 1, "startOffset": 0, "duration": 100, "title": "Track 1",
          "contentUrl": "/api/items/\(Self.itemID)/file/101", "mimeType": "audio/mpeg",
        ]
      ],
      "chapters": [] as [Any],
    ]
    let path =
      episodeID.map { "/api/items/\(Self.itemID)/play/\($0)" }
      ?? "/api/items/\(Self.itemID)/play"
    await http.stub(
      path: path,
      responses: [
        HTTPResponse(
          statusCode: 200, headers: ["Content-Type": "application/json"],
          body: try! JSONSerialization.data(withJSONObject: object))
      ])
  }

  /// `GET /api/session/{id}`: still open (`200`).
  func openSessionResponse(serverSessionID: String = "server-session-1") -> HTTPResponse {
    let object: [String: Any] = [
      "id": serverSessionID,
      "libraryItemId": Self.itemID,
      "mediaType": "book",
      "audioTracks": [
        [
          "index": 1, "startOffset": 0, "duration": 100,
          "contentUrl": "/api/items/\(Self.itemID)/file/101",
        ]
      ],
      "chapters": [] as [Any],
    ]
    return HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }

  /// `GET /api/me`: the authoritative-progress check close-ambiguity reconciliation uses.
  /// `itemID: nil` produces an empty `mediaProgresses` array (nothing authoritative to compare
  /// against, which is itself the "session gone" outcome).
  func meResponse(itemID: String?, currentTime: Double?) -> HTTPResponse {
    var progresses: [[String: Any]] = []
    if let itemID {
      progresses.append(["libraryItemId": itemID, "currentTime": currentTime as Any, "isFinished": false])
    }
    let object: [String: Any] = ["mediaProgresses": progresses]
    return HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }
}

private func insertGoneTestAccountAndLibrary(_ database: AppDatabase) async throws -> (
  accountId: Int64, libraryId: Int64
) {
  try await database.writeAsync { db in
    var account = AccountRecord(
      clientUUID: UUID().uuidString, serverBaseURL: "https://gone.example.test", serverUserId: "user-1",
      serverVersion: "2.35.1")
    try account.insert(db)
    var library = LibraryRecord(accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
    try library.insert(db)
    return (account.id!, library.id!)
  }
}

private func insertGoneTestItem(
  _ database: AppDatabase, accountId: Int64, libraryId: Int64, serverItemId: String
) async throws -> Int64 {
  try await database.writeAsync { db in
    var item = ItemRecord(
      accountId: accountId, libraryId: libraryId, serverItemId: serverItemId, mediaKind: "book", title: "Title",
      sortTitle: "title")
    try item.insert(db)
    return item.id!
  }
}
