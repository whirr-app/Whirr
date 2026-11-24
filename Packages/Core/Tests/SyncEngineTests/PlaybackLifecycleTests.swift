import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Session recovery and closure across app-lifecycle changes: `SyncEngine`'s single `AppLifecycle`
/// subscription routes to playback policy (`PlaybackSyncing.handleAppBackgrounded`), fresh-process
/// recovery (`recoverOpenSessions`) and the logout preflight (`quiesceForLogout`). Covers only the
/// lifecycle wiring; `ProgressMergePolicy`, the foreground-pull race
/// (`ForegroundPullDuringPlaybackTests`) and cadence policy (`PlaybackCadenceTests`) are tested
/// elsewhere.
///
/// Waits are event-driven (`SessionScriptedHTTPClient.waitUntilRequested`,
/// `FakeAppLifecycle.waitForBackgroundTasks`), not poll-with-deadline: under a full parallel
/// `swift test` run a useful wall-clock deadline is long enough to be missed. The two waits on a
/// GRDB session-store row going away have no mutation hook, so they poll with no deadline; the
/// `.timeLimit` trait turns an unsatisfiable wait into a failure, not a hang.
@Suite("Playback lifecycle: background/foreground/recovery/logout", .timeLimit(.minutes(1)))
struct PlaybackLifecycleTests {

  // MARK: - Background while playing keeps the session open

  @Test("background while playing enqueues and immediately drains one sync, never closes, and cadence continues")
  func backgroundWhilePlayingDrainsOneSyncAndDoesNotClose() async throws {
    let h = try await LifecycleHarness()
    let sessionId = try await h.startPlayingSessionWithTick(position: 50, delta: 10)
    await h.http.stub(path: LifecycleHarness.syncPath, responses: [LifecycleHarness.okResponse()])
    // `startSession`'s switch/stale-leftover step already cancels the (nonexistent) former
    // session's deadline once. Captured so the assertion below covers backgrounding only.
    let cancelCountBeforeBackground = h.scheduler.cancelCount

    h.appLifecycle.simulateBackground()
    await h.http.waitUntilRequested(path: LifecycleHarness.syncPath)
    #expect(await h.http.requestCount(forPath: LifecycleHarness.syncPath) == 1)
    #expect(await h.http.requestCount(forPath: LifecycleHarness.closePath) == 0)
    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.state == .active, "still open - backgrounding a playing session never closes it")
    // Cadence continues: backgrounding does not cancel the periodic deadline.
    #expect(h.scheduler.cancelCount == cancelCountBeforeBackground)
    #expect(h.scheduler.pendingInterval == 15)
  }

  // MARK: - Background while paused closes, in a bounded task

  @Test("background while paused atomically marks closePending then attempts close in a bounded task")
  func backgroundWhilePausedMarksClosePendingThenClosesInABoundedTask() async throws {
    let h = try await LifecycleHarness()
    let sessionId = try await h.startPausedSessionWithAcknowledgedTick(position: 80, delta: 5)
    await h.http.hang(path: LifecycleHarness.closePath)

    h.appLifecycle.simulateBackground()
    await h.http.waitUntilRequested(path: LifecycleHarness.closePath)

    // The close attempt is in flight (hung). The durable `closePending` write must have
    // committed before the network call, all inside one bounded background task.
    let midClose = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(midClose.closePending == true)
    #expect(midClose.state == .active, "not yet acknowledged")
    #expect(h.appLifecycle.backgroundTaskBeginCount == 1)
    #expect(h.appLifecycle.activeBackgroundTaskCount == 1)

    await h.http.release(path: LifecycleHarness.closePath, with: LifecycleHarness.okResponse())
    await TestSupport.waitUntil { (try? h.sessionStore.fetchSession(id: sessionId)) == nil }
    // The row disappears just inside the bounded operation's completion; `endBackgroundTask`
    // follows a few scheduler hops later, so wait on it rather than assume a number of yields.
    await h.appLifecycle.waitForBackgroundTasks { _, endCount in endCount == 1 }

    #expect(await h.http.requestCount(forPath: LifecycleHarness.closePath) == 1)
    #expect(h.appLifecycle.backgroundTaskEndCount == 1)
  }

  @Test("backgrounding with no active session at all is a safe no-op")
  func backgroundingWithNoActiveSessionIsANoOp() async throws {
    let h = try await LifecycleHarness()

    h.appLifecycle.simulateBackground()
    await h.appLifecycle.waitForBackgroundTasks { _, endCount in endCount == 1 }

    #expect(await h.http.requests.isEmpty)
    #expect(h.appLifecycle.backgroundTaskBeginCount == 1, "still wrapped, even though there is nothing to do")
    #expect(h.appLifecycle.backgroundTaskEndCount == 1)
  }

  // MARK: - Foreground never duplicates either operation, and still pulls

  @Test("foreground does not duplicate the background-triggered sync or close, and still triggers the library pull")
  func foregroundDoesNotDuplicateAndStillPulls() async throws {
    let h = try await LifecycleHarness()
    _ = try await h.startPlayingSessionWithTick(position: 50, delta: 10)
    await h.http.stub(path: LifecycleHarness.syncPath, responses: [LifecycleHarness.okResponse()])
    h.appLifecycle.simulateBackground()
    await h.http.waitUntilRequested(path: LifecycleHarness.syncPath)
    await h.enqueueLibraryPullCycle()
    h.appLifecycle.simulateForeground()
    await h.http.waitUntilRequested(path: "/api/libraries")
    #expect(await h.http.requestCount(forPath: LifecycleHarness.syncPath) == 1, "never duplicated by foregrounding")
    #expect(await h.http.requestCount(forPath: LifecycleHarness.closePath) == 0)
    #expect(await h.http.requests.contains { $0.url.path == "/api/libraries" })
  }

  // MARK: - Expiration/cancellation leaves pending work durable

  @Test("a bounded background task's expiration cancels the close attempt but leaves the durable close intact")
  func expirationCancelsTheAttemptButLeavesTheDurableCloseIntact() async throws {
    let h = try await LifecycleHarness()
    let sessionId = try await h.startPausedSessionWithAcknowledgedTick(position: 80, delta: 5)
    await h.http.hang(path: LifecycleHarness.closePath)

    h.appLifecycle.simulateBackground()
    await h.http.waitUntilRequested(path: LifecycleHarness.closePath)
    h.appLifecycle.simulateBackgroundTaskExpiration()
    #expect(
      await TestSupport.waitUntil {
        (try? h.sessionStore.fetchSession(id: sessionId))?.closePending == true
      })

    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.closePending == true, "the durable close survives an expired network attempt")
    #expect(session.state == .active)
    let queued = try h.sessionCloseRows(sessionId)
    #expect(queued.isEmpty == false, "the sessionClose outbox row is never lost")
  }

  // MARK: - Idempotence across repeated transitions

  @Test("repeated background transitions without an intervening foreground are idempotent")
  func repeatedBackgroundTransitionsAreIdempotent() async throws {
    let h = try await LifecycleHarness()
    let sessionId = try await h.startPausedSessionWithAcknowledgedTick(position: 80, delta: 5)
    await h.http.stub(
      path: LifecycleHarness.closePath, responses: [LifecycleHarness.okResponse(), LifecycleHarness.okResponse()])

    h.appLifecycle.simulateBackground()
    await TestSupport.waitUntil { (try? h.sessionStore.fetchSession(id: sessionId)) == nil }
    await h.appLifecycle.waitForBackgroundTasks { _, endCount in endCount == 1 }
    // A second background transition with no session left active must not crash or enqueue
    // anything new.
    h.appLifecycle.simulateBackground()
    await h.appLifecycle.waitForBackgroundTasks { beginCount, _ in beginCount == 2 }
    await h.appLifecycle.waitForBackgroundTasks { _, endCount in endCount == 2 }

    #expect(try h.sessionStore.fetchSession(id: sessionId) == nil)
    #expect(h.appLifecycle.backgroundTaskEndCount == h.appLifecycle.backgroundTaskBeginCount)
    #expect(h.appLifecycle.backgroundTaskBeginCount == 2, "both transitions were still wrapped")
  }

  // MARK: - Fresh-process recovery

  @Test("recovery confirms a still-open local session via GET and leaves it active")
  func recoveryConfirmsStillOpenSessionAndLeavesItActive() async throws {
    let h = try await LifecycleHarness()
    let sessionId = try h.seedLocallyActiveSession(serverSessionId: "server-session-1")
    await h.http.stub(path: LifecycleHarness.getSessionPath, responses: [LifecycleHarness.openSessionResponse()])

    await h.coordinator.recoverOpenSessions()

    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.state == .active)
    #expect(await h.http.requestCount(forPath: LifecycleHarness.closePath) == 0)
  }

  @Test("recovery closes a locally-persisted session the server confirms is gone")
  func recoveryClosesASessionTheServerConfirmsIsGone() async throws {
    let h = try await LifecycleHarness()
    let sessionId = try h.seedLocallyActiveSession(serverSessionId: "server-session-1")
    await h.http.stub(
      path: LifecycleHarness.getSessionPath, responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])

    await h.coordinator.recoverOpenSessions()

    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.state == .gone)
  }

  @Test("recovery closes an unrecorded post-/play orphan for this device without touching another device's session")
  func recoveryClosesAnOrphanForThisDeviceOnlyOnly() async throws {
    let h = try await LifecycleHarness()
    // No locally-persisted session: only the best-effort `/api/sessions/open` path applies.
    await h.http.stub(
      path: "/api/sessions/open",
      responses: [
        LifecycleHarness.openSessionsListResponse(sessions: [
          (id: "orphan-session", deviceID: h.clientUUID),
          (id: "other-device-session", deviceID: "some-other-installation"),
        ])
      ])
    await h.http.stub(path: "/api/session/orphan-session/close", responses: [LifecycleHarness.okResponse()])

    await h.coordinator.recoverOpenSessions()

    #expect(await h.http.requestCount(forPath: "/api/session/orphan-session/close") == 1)
    #expect(await h.http.requestCount(forPath: "/api/session/other-device-session/close") == 0)
  }

  @Test("recovery blocks a replacement /play until the never-confirmed prior session's closure is persisted")
  func recoveryBlocksReplacementPlayUntilClosurePersisted() async throws {
    let h = try await LifecycleHarness()
    // Never confirmed server-side (a crash between `/play` returning and `setServerSessionId`).
    let staleSessionId = try h.seedLocallyActiveSession(serverSessionId: nil)
    await h.http.stub(
      path: "/api/sessions/open", responses: [HTTPResponse(statusCode: 404, headers: [:], body: Data())])

    await h.coordinator.recoverOpenSessions()
    let stale = try #require(try h.sessionStore.fetchSession(id: staleSessionId))
    #expect(stale.state == .gone, "freed before any replacement /play is attempted")

    await h.enqueuePlayResponse(serverSessionID: "server-session-2")
    let prepared = try await h.coordinator.startSession(itemID: LifecycleHarness.itemID, episodeID: nil)
    #expect(prepared.itemID == LifecycleHarness.itemID)
    let replacement = try #require(try h.sessionStore.fetchActiveSession(accountId: h.accountId))
    #expect(replacement.serverSessionId == "server-session-2")
    #expect(replacement.id != staleSessionId)
  }

  // MARK: - Logout preflight

  @Test("quiesceForLogout persists the final state, makes one close attempt, and blocks further playback work")
  func quiesceForLogoutPersistsAndClosesAndBlocksFurtherWork() async throws {
    let h = try await LifecycleHarness()
    _ = try await h.startPlayingSessionWithTick(position: 200, delta: 30)
    await h.http.stub(path: LifecycleHarness.syncPath, responses: [LifecycleHarness.okResponse()])
    await h.http.stub(path: LifecycleHarness.closePath, responses: [LifecycleHarness.okResponse()])

    await h.coordinator.quiesceForLogout()

    #expect(await h.http.requestCount(forPath: LifecycleHarness.closePath) == 1)
    await h.enqueuePlayResponse(serverSessionID: "server-session-should-never-be-used")
    await #expect(throws: PlaybackCoordinatorError.quiescedForLogout) {
      _ = try await h.coordinator.startSession(itemID: LifecycleHarness.itemID, episodeID: nil)
    }
  }

  @Test("quiesceForLogout still returns normally when the close attempt fails")
  func quiesceForLogoutReturnsNormallyEvenWhenCloseFails() async throws {
    let h = try await LifecycleHarness()
    let sessionId = try await h.startPlayingSessionWithTick(position: 200, delta: 30)
    await h.http.stub(path: LifecycleHarness.syncPath, responses: [LifecycleHarness.okResponse()])
    await h.http.stub(
      path: LifecycleHarness.closePath, responses: [HTTPResponse(statusCode: 500, headers: [:], body: Data())])

    await h.coordinator.quiesceForLogout()

    // The caller must be free to proceed with account removal regardless, so nothing here may
    // throw or hang waiting on a retry.
    let session = try #require(try h.sessionStore.fetchSession(id: sessionId))
    #expect(session.closePending == true, "the durable close still committed before the failed attempt")
  }
}

// MARK: - Harness

private final class LifecycleHarness: @unchecked Sendable {
  static let itemID = "item_lifecycle_fixture"
  static let libraryID = "lib-lifecycle"
  static let syncPath = "/api/session/server-session-1/sync"
  static let closePath = "/api/session/server-session-1/close"
  static let getSessionPath = "/api/session/server-session-1"

  let http: SessionScriptedHTTPClient
  let database: AppDatabase
  let outbox: OutboxStore
  let sessionStore: PlaybackSessionStore
  let appLifecycle: FakeAppLifecycle
  let scheduler: FakePlaybackCadenceScheduling
  let client: ABSClient
  let accountId: Int64
  let itemRowId: Int64
  let clientUUID: String
  let coordinator: PlaybackSessionCoordinator
  let drainer: OutboxDrainer
  let engine: SyncEngine

  init() async throws {
    let server = try ABSServerConfig(url: try #require(URL(string: "https://lifecycle.example.test")))
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
      try record.insert(db)
      return record
    }
    let accountId = try #require(savedAccount.id)

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
    let appLifecycle = FakeAppLifecycle()
    let scheduler = FakePlaybackCadenceScheduling()

    let drainer = OutboxDrainer(
      outboxStore: outbox, database: database, absClient: client, account: account, accountId: accountId)

    let coordinator = PlaybackSessionCoordinator(
      client: client, database: database, outbox: outbox,
      clock: FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000)), scheduler: scheduler,
      requestDrain: { await drainer.drainOutbox() })

    self.http = http
    self.database = database
    self.outbox = outbox
    self.sessionStore = sessionStore
    self.appLifecycle = appLifecycle
    self.scheduler = scheduler
    self.client = client
    self.accountId = accountId
    self.itemRowId = itemRowId
    self.clientUUID = clientUUID
    self.coordinator = coordinator
    self.drainer = drainer
    engine = SyncEngine.make(
      client: client, database: database, diagnostics: FakeDiagnosticsRecording(), appLifecycle: appLifecycle,
      playback: coordinator, clock: FakeSyncClock(now: Date(timeIntervalSince1970: 1_700_000_000)),
      randomSource: { 1 })
  }

  // MARK: - Session setup helpers

  func enqueuePlayResponse(serverSessionID: String = "server-session-1") async {
    let object: [String: Any] = [
      "id": serverSessionID,
      "libraryItemId": Self.itemID,
      "mediaType": "book",
      "displayTitle": "Fixture Book",
      "duration": 3600,
      "currentTime": 0,
      "playMethod": 0,
      "deviceInfo": ["deviceId": clientUUID],
      "audioTracks": [
        [
          "index": 1, "startOffset": 0, "duration": 100, "title": "Track 1",
          "contentUrl": "/api/items/\(Self.itemID)/file/101", "mimeType": "audio/mpeg",
        ]
      ],
      "chapters": [] as [Any],
    ]
    await http.stub(
      path: "/api/items/\(Self.itemID)/play",
      responses: [
        HTTPResponse(
          statusCode: 200, headers: ["Content-Type": "application/json"],
          body: try! JSONSerialization.data(withJSONObject: object))
      ])
  }

  @discardableResult
  func startPlayingSessionWithTick(position: Double, delta: Double) async throws -> Int64 {
    await enqueuePlayResponse()
    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    let sessionId = try #require(try sessionStore.fetchActiveSession(accountId: accountId)?.id)
    _ = try sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: position, isFinished: false, deltaSecondsSinceLastTick: delta, localSequence: 1,
        originKey: clientUUID, segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    await coordinator.notifyPlaybackPhase(.playing)
    return sessionId
  }

  /// Starts a session, records one tick, then acknowledges it directly (bypassing the network) so
  /// the session enters `.paused` with nothing outstanding.
  @discardableResult
  func startPausedSessionWithAcknowledgedTick(position: Double, delta: Double) async throws -> Int64 {
    await enqueuePlayResponse()
    _ = try await coordinator.startSession(itemID: Self.itemID, episodeID: nil)
    let sessionId = try #require(try sessionStore.fetchActiveSession(accountId: accountId)?.id)
    _ = try sessionStore.recordTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: position, isFinished: false, deltaSecondsSinceLastTick: delta, localSequence: 1,
        originKey: clientUUID, segmentKey: "seg-1", now: Date(timeIntervalSince1970: 1_700_000_010)))
    let queued = try sessionSyncRows(sessionId)
    for row in queued {
      try sessionStore.acknowledgeSync(operationId: try #require(row.id), sessionId: sessionId)
    }
    await coordinator.notifyPlaybackPhase(.paused)
    return sessionId
  }

  /// Seeds an already-locally-active session directly (bypassing `/play`), as a fresh process
  /// would find it on disk.
  @discardableResult
  func seedLocallyActiveSession(serverSessionId: String?) throws -> Int64 {
    let started = try sessionStore.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemRowId, duration: 3600,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let sessionId = try #require(started.id)
    if let serverSessionId {
      _ = try sessionStore.setServerSessionId(sessionId: sessionId, serverSessionId: serverSessionId)
    }
    return sessionId
  }

  func sessionSyncRows(_ sessionId: Int64) throws -> [OutboxOperationRecord] {
    try database.read { db in
      try OutboxOperationRecord
        .filter(Column("playbackSessionId") == sessionId)
        .filter(Column("operationKind") == OutboxOperationKind.sessionSync.rawValue)
        .fetchAll(db)
    }
  }

  func sessionCloseRows(_ sessionId: Int64) throws -> [OutboxOperationRecord] {
    try database.read { db in
      try OutboxOperationRecord
        .filter(Column("playbackSessionId") == sessionId)
        .filter(Column("operationKind") == OutboxOperationKind.sessionClose.rawValue)
        .fetchAll(db)
    }
  }

  // MARK: - Library pull fixtures

  func enqueueLibraryPullCycle() async {
    await http.stub(
      path: "/api/libraries",
      responses: [
        Self.jsonResponse(object: ["libraries": [["id": Self.libraryID, "name": "Library", "mediaType": "book"]]])
      ]
    )
    await http.stub(path: "/api/me", responses: [Self.jsonResponse(object: ["mediaProgresses": [] as [Any]])])
    await http.stub(
      path: "/api/libraries/\(Self.libraryID)/items",
      responses: [
        Self.jsonResponse(
          object: [
            "results": [
              [
                "id": Self.itemID, "libraryId": Self.libraryID, "mediaType": "book",
                "media": ["metadata": ["title": "Title", "authorName": NSNull()]],
              ]
            ],
            "total": 1,
            "limit": 100,
            "page": 0,
          ])
      ])
  }

  // MARK: - Recovery fixtures

  static func openSessionResponse(serverSessionID: String = "server-session-1") -> HTTPResponse {
    let object: [String: Any] = [
      "id": serverSessionID,
      "libraryItemId": Self.itemID,
      "mediaType": "book",
      "audioTracks": [
        ["index": 1, "startOffset": 0, "duration": 100, "contentUrl": "/api/items/\(Self.itemID)/file/101"]
      ],
      "chapters": [] as [Any],
    ]
    return Self.jsonResponse(object: object)
  }

  static func openSessionsListResponse(sessions: [(id: String, deviceID: String)]) -> HTTPResponse {
    let object: [String: Any] = [
      "sessions": sessions.map { entry in
        [
          "id": entry.id,
          "libraryItemId": Self.itemID,
          "mediaType": "book",
          "deviceInfo": ["deviceId": entry.deviceID],
          "audioTracks": [
            ["index": 1, "startOffset": 0, "duration": 100, "contentUrl": "/api/items/\(Self.itemID)/file/101"]
          ],
          "chapters": [] as [Any],
        ]
      }
    ]
    return Self.jsonResponse(object: object)
  }

  static func okResponse() -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: [:], body: Data())
  }

  static func jsonResponse(object: Any) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: try! JSONSerialization.data(withJSONObject: object))
  }
}
