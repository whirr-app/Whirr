import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Protects a live playing position from an unrelated foreground/explicit library pull
/// (`SyncEngine.applyProgress`). `ProgressMergePolicy` is applied once at session start
/// (`PlaybackSessionCoordinator.resolveStartPosition`); this suite covers the second surface. A
/// live session's ticks land as `sessionSync`/`sessionClose` outbox rows keyed
/// `session:<clientSessionId>`, which the item-keyed check in
/// `MediaProgressDAO.hasUnacknowledgedLocalOperation` cannot see, so a mid-session pull could
/// overwrite an unacknowledged local position. Cadence/close policy (`PlaybackLifecycleTests`) and
/// the decision table (`ProgressMergePolicyTests`) are covered elsewhere; this only asserts
/// `applyProgress` feeds the right signal for a live session.
@Suite("Foreground pull vs. live playback position")
struct ForegroundPullDuringPlaybackTests {

  @Test("an older server pull never moves the playing position backward and never discards the unacknowledged delta")
  func olderPullNeverMovesPositionBackwardOrDiscardsDelta() async throws {
    let h = try await PullVsPlaybackHarness()
    let sessionId = try h.seedActiveSessionWithUnacknowledgedTick(position: 500, delta: 50, localSequence: 1)

    // Server reports a much older position with a real `lastUpdate`, as every pulled row has. A
    // live session's ticks never touch `MediaProgressRecord.serverUpdatedAt`, so it is still
    // `nil` locally. Without the fix, `ProgressMergePolicy.resolve`'s
    // `(current: .none, incoming: .some)` branch applies the incoming row regardless of position.
    h.enqueuePullCycle(
      itemID: PullVsPlaybackHarness.itemID, serverCurrentTime: 10, serverIsFinished: false,
      serverLastUpdateEpochMillis: 1_000_000_000_000)

    await h.engine.refresh()

    let progress = try #require(try h.fetchProgress())
    #expect(progress.currentTime == 500, "the playing position must never move backward")
    let rows = try h.sessionSyncRows(sessionId)
    #expect(rows.count == 1, "no duplicate sessionSync enqueued by the pull path")
    #expect(rows.first?.payloadAccumulatedDeltaSeconds == 50, "the unacknowledged delta survives untouched")
  }

  @Test("a pull landing between a tick's persistence and its acknowledgement leaves the frozen delta intact")
  func pullBetweenPersistenceAndAcknowledgementLeavesDeltaIntact() async throws {
    let h = try await PullVsPlaybackHarness()
    let sessionId = try h.seedActiveSessionWithUnacknowledgedTick(position: 120, delta: 15, localSequence: 1)
    let rowBefore = try #require(try h.sessionSyncRows(sessionId).first)

    // A pull carrying the item's own pre-session progress (before this tick ever landed), with a
    // real `lastUpdate` timestamp. The race: the tick has been durably persisted, but nothing
    // has acknowledged it yet.
    h.enqueuePullCycle(
      itemID: PullVsPlaybackHarness.itemID, serverCurrentTime: 8, serverIsFinished: false,
      serverLastUpdateEpochMillis: 1_000_000_000_000)

    await h.engine.refresh()

    let rowAfter = try #require(try h.sessionSyncRows(sessionId).first)
    #expect(rowAfter.id == rowBefore.id, "the same outbox row - never replaced")
    #expect(rowAfter.payloadAccumulatedDeltaSeconds == rowBefore.payloadAccumulatedDeltaSeconds)
    #expect(rowAfter.state == rowBefore.state)
    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.globalPosition == 120, "the session's own position is untouched by the pull")
    let progress = try #require(try h.fetchProgress())
    #expect(
      progress.currentTime == 120, "the tick's own position is not overwritten while its outbox row is unacknowledged")
  }

  @Test("an unacknowledged local finish survives a conflicting unfinished server pull")
  func unacknowledgedLocalFinishSurvivesConflictingServerPull() async throws {
    let h = try await PullVsPlaybackHarness()
    _ = try h.seedActiveSessionWithUnacknowledgedTick(
      position: 120, delta: 10, localSequence: 1, isFinished: true)

    h.enqueuePullCycle(
      itemID: PullVsPlaybackHarness.itemID, serverCurrentTime: 119, serverIsFinished: false,
      serverLastUpdateEpochMillis: 1_000_000_000_000)

    await h.engine.refresh()

    let progress = try #require(try h.fetchProgress())
    #expect(progress.currentTime == 120)
    #expect(progress.isFinished == true)
  }

  @Test("a legitimately newer server value still resolves through ProgressMergePolicy once the tick is acknowledged")
  func legitimatelyNewerServerValueStillResolvesOnceAcknowledged() async throws {
    let h = try await PullVsPlaybackHarness()
    let sessionId = try h.seedActiveSessionWithUnacknowledgedTick(position: 200, delta: 20, localSequence: 1)
    // Acknowledge the outstanding tick. Nothing is left unacknowledged for this session, so the
    // fix must not block a genuinely newer pull outright: it only protects while something really
    // is unacknowledged, never for the lifetime of a merely-active session.
    try h.acknowledgeOnlySessionSyncRow(sessionId)

    h.enqueuePullCycle(
      itemID: PullVsPlaybackHarness.itemID, serverCurrentTime: 900, serverIsFinished: false,
      serverLastUpdateEpochMillis: 2_000_000_000_000)

    await h.engine.refresh()

    let progress = try #require(try h.fetchProgress())
    #expect(progress.currentTime == 900, "resolves through ProgressMergePolicy - never blocked outright")
    #expect(try h.sessionSyncRows(sessionId).isEmpty, "still no duplicate sessionSync from the pull path")
  }
}

// MARK: - Harness

private final class PullVsPlaybackHarness: @unchecked Sendable {
  static let itemID = "item_pull_vs_playback"
  static let libraryID = "lib-pull-vs-playback"

  let http: FakeHTTPClient
  let database: AppDatabase
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let engine: SyncEngine
  let accountId: Int64
  let itemRowId: Int64
  let clock: FakeSyncClock

  init() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://pull-vs-playback.example.test")))
    let clientUUID = UUID().uuidString
    let account = try TokenAccount(
      credentialNamespace: AccountRecord.credentialNamespace(forClientUUID: clientUUID), userID: "user_fixture")
    let tokenStore = InMemoryTokenStore()
    try tokenStore.save(TokenPair(accessToken: "canary-access", refreshToken: "canary-refresh"), for: account)

    let http = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: http, tokenStore: tokenStore)

    let database = try AppDatabase.inMemory()
    let saved = try await database.writeAsync { db in
      var record = AccountRecord(
        clientUUID: clientUUID, serverBaseURL: server.baseURL.absoluteString,
        serverUserId: "user_fixture", serverVersion: "2.35.1")
      try record.save(db)
      return record
    }
    let accountId = try #require(saved.id)

    let libraryRowId = try await database.writeAsync { db -> Int64 in
      var library = LibraryRecord(
        accountId: accountId, serverLibraryId: Self.libraryID, mediaType: "book", name: "Library")
      try library.insert(db)
      return library.id!
    }
    let itemDAO = ItemDAO(database: database)
    let itemRowId = try #require(
      try await itemDAO.upsertAsync(
        ItemRecord(
          accountId: accountId, libraryId: libraryRowId, serverItemId: Self.itemID, mediaKind: "book",
          title: "Title", sortTitle: "title")
      ).id)

    let outbox = try OutboxStore(database: database)
    let sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000))

    self.http = http
    self.database = database
    self.outbox = outbox
    self.sessionStore = sessionStore
    self.accountId = accountId
    self.itemRowId = itemRowId
    self.clock = clock
    engine = SyncEngine.make(
      client: client, database: database, diagnostics: FakeDiagnosticsRecording(),
      appLifecycle: FakeAppLifecycle(), clock: clock, randomSource: { 1 }, pageLimit: 100)
  }

  @discardableResult
  func seedActiveSessionWithUnacknowledgedTick(
    position: Double, delta: Double, localSequence: Int64, isFinished: Bool = false
  ) throws
    -> Int64
  {
    let started = try sessionStore.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemRowId, duration: 3600,
      startedAt: clock.now())
    let sessionId = try #require(started.id)
    _ = try sessionStore.setServerSessionId(sessionId: sessionId, serverSessionId: "server-session-1")
    _ = try sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: position, isFinished: isFinished, deltaSecondsSinceLastTick: delta,
        localSequence: localSequence, originKey: "device-uuid", segmentKey: "seg-\(localSequence)",
        now: clock.now()))
    return sessionId
  }

  /// Acknowledges the one outstanding `sessionSync` row for `sessionId` directly (bypassing a
  /// real network round trip, as this suite is about the pull path, not the drain path).
  func acknowledgeOnlySessionSyncRow(_ sessionId: Int64) throws {
    let row = try #require(try sessionSyncRows(sessionId).first)
    try sessionStore.acknowledgeSync(operationId: try #require(row.id), sessionId: sessionId)
  }

  func sessionSyncRows(_ sessionId: Int64) throws -> [OutboxOperationRecord] {
    try database.read { db in
      try OutboxOperationRecord
        .filter(Column("playbackSessionId") == sessionId)
        .filter(Column("operationKind") == OutboxOperationKind.sessionSync.rawValue)
        .fetchAll(db)
    }
  }

  func fetchProgress() throws -> MediaProgressRecord? {
    try MediaProgressDAO(database: database).fetchCurrent(
      accountId: accountId, identity: .item(itemId: itemRowId))
  }

  /// Queues one full `refresh()` cycle's worth of responses: an empty library list matcher isn't
  /// enough (the item must actually be revisited so `applyProgress` runs against it). One
  /// library, one page containing this fixture's item, and one `/api/me` progress snapshot.
  func enqueuePullCycle(
    itemID: String, serverCurrentTime: Double, serverIsFinished: Bool,
    serverLastUpdateEpochMillis: Double? = nil
  ) {
    http.enqueue(
      Self.jsonResponse(object: ["libraries": [["id": Self.libraryID, "name": "Library", "mediaType": "book"]]]))
    var progressObject: [String: Any] = [
      "libraryItemId": itemID, "currentTime": serverCurrentTime, "isFinished": serverIsFinished,
    ]
    if let serverLastUpdateEpochMillis {
      progressObject["lastUpdate"] = serverLastUpdateEpochMillis
    }
    http.enqueue(Self.jsonResponse(object: ["mediaProgresses": [progressObject]]))
    http.enqueue(
      Self.jsonResponse(
        object: [
          "results": [
            [
              "id": itemID, "libraryId": Self.libraryID, "mediaType": "book",
              "media": ["metadata": ["title": "Title", "authorName": NSNull()]],
            ]
          ],
          "total": 1,
          "limit": 100,
          "page": 0,
        ]))
  }

  static func jsonResponse(object: Any) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }
}
