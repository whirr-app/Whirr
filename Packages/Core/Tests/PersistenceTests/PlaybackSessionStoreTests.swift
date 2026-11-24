import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// `PlaybackSessionStore` lifecycle. One locally-active online session
/// per account/device, a stable client session UUID, full field round trips, old-session lookup
/// on relaunch, and duplicate-`clientSessionId` quarantine.
@Suite struct PlaybackSessionStoreTests {

  // MARK: - One active online session per account/device

  @Test func onlyOneActiveOnlineSessionIsAllowedPerAccount() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    _ = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    #expect(throws: PlaybackSessionStoreError.self) {
      try store.startSession(
        accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_100))
    }

    let rows = try database.read { db in try PlaybackSessionRecord.fetchAll(db) }
    #expect(rows.count == 1, "the rejected second session must never be persisted")
  }

  @Test func differentAccountsMayEachHaveTheirOwnActiveSession() async throws {
    let database = try AppDatabase.inMemory()
    let (firstAccountId, libraryId) = try await insertAccountAndLibrary(database, serverUserId: "user-1")
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: firstAccountId, libraryId: libraryId)
    let secondAccountId = try await PersistenceFixtures.insertAccount(database, serverUserId: "user-2")
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    _ = try store.startSession(
      accountId: firstAccountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try store.startSession(
      accountId: secondAccountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    let rows = try database.read { db in try PlaybackSessionRecord.fetchAll(db) }
    #expect(rows.count == 2)
  }

  // MARK: - Stable client session UUID

  @Test func clientSessionIdNeverChangesAcrossTicks() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)
    let clientSessionId = UUID().uuidString

    let started = try store.startSession(
      accountId: accountId, clientSessionId: clientSessionId, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    let ticked = try store.recordTick(
      sessionId: started.id!,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 10, localSequence: 1,
        originKey: "client-uuid", segmentKey: "seg-1",
        now: Date(timeIntervalSince1970: 1_700_000_010)))

    #expect(ticked.clientSessionId == clientSessionId)
  }

  // MARK: - Full field round trip

  @Test func fieldsRoundTripThroughStartAndTick() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let started = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId, duration: 3600,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(started.duration == 3600)
    #expect(started.state == .active)
    #expect(started.closePending == false)
    #expect(started.serverSessionId == nil)
    #expect(started.itemId == itemId)

    var withServerId = started
    withServerId.serverSessionId = "server-session-1"
    let toSave = withServerId
    let saved = try await database.writeAsync { db in try toSave.saved(db) }
    #expect(saved.serverSessionId == "server-session-1")

    let ticked = try store.recordTick(
      sessionId: saved.id!,
      tick: PlaybackTick(
        globalPosition: 42, isFinished: false, deltaSecondsSinceLastTick: 12, localSequence: 5,
        originKey: "client-uuid", segmentKey: "seg-1",
        now: Date(timeIntervalSince1970: 1_700_000_050)))

    #expect(ticked.serverSessionId == "server-session-1")
    #expect(ticked.itemId == itemId)
    #expect(ticked.globalPosition == 42)
    #expect(ticked.duration == 3600)
    #expect(ticked.state == .active)
    #expect(ticked.lastLocalSequence == 5)
    #expect(ticked.listenedDeltaSeconds == 12)
    #expect(ticked.closePending == false)
  }

  // MARK: - Persist-id-first

  @Test func setServerSessionIdPersistsTheServerIdOntoTheExistingRow() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let started = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(started.serverSessionId == nil)

    let confirmed = try store.setServerSessionId(sessionId: started.id!, serverSessionId: "server-session-1")
    #expect(confirmed.serverSessionId == "server-session-1")
    #expect(confirmed.id == started.id)

    let reread = try store.fetchSession(id: started.id!)
    #expect(reread?.serverSessionId == "server-session-1")
  }

  @Test func setServerSessionIdThrowsForAnUnknownSession() throws {
    let database = try AppDatabase.inMemory()
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    #expect(throws: PlaybackSessionStoreError.sessionNotFound(999)) {
      try store.setServerSessionId(sessionId: 999, serverSessionId: "server-session-1")
    }
  }

  @Test func fieldsRoundTripAcrossACrashAndReopen() async throws {
    try await withOnDiskDatabases { scope in
      let databaseURL = scope.url()
      let clientSessionId = UUID().uuidString
      let database = try scope.open(fileAttributes: FakeFileAttributeApplying())
      let (accountId, libraryId) = try await insertAccountAndLibrary(database)
      let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
      let outbox = try OutboxStore(database: database)
      let store = PlaybackSessionStore(database: database, outbox: outbox)

      let started = try store.startSession(
        accountId: accountId, clientSessionId: clientSessionId, itemId: itemId, duration: 100,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000))
      let ticked = try store.recordTick(
        sessionId: started.id!,
        tick: PlaybackTick(
          globalPosition: 30, isFinished: false, deltaSecondsSinceLastTick: 8, localSequence: 2,
          originKey: "client-uuid", segmentKey: "seg-1",
          now: Date(timeIntervalSince1970: 1_700_000_030)))
      let sessionId = ticked.id!
      scope.close(database)

      let reopened = try scope.open(at: databaseURL, fileAttributes: FakeFileAttributeApplying())
      let recovered = try await reopened.readAsync { db in
        try PlaybackSessionRecord.fetchOne(db, key: sessionId)
      }
      #expect(recovered?.clientSessionId == clientSessionId)
      #expect(recovered?.globalPosition == 30)
      #expect(recovered?.listenedDeltaSeconds == 8)
      #expect(recovered?.lastLocalSequence == 2)
      #expect(recovered?.duration == 100)
    }
  }

  // MARK: - Old-session lookup on relaunch

  @Test func fetchActiveSessionFindsThePreviouslyOpenSessionAfterRelaunch() async throws {
    try await withOnDiskDatabases { scope in
      let databaseURL = scope.url()
      let clientSessionId = UUID().uuidString
      let database = try scope.open(fileAttributes: FakeFileAttributeApplying())
      let (insertedAccountId, libraryId) = try await insertAccountAndLibrary(database)
      let accountId = insertedAccountId
      let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
      let outbox = try OutboxStore(database: database)
      let store = PlaybackSessionStore(database: database, outbox: outbox)
      _ = try store.startSession(
        accountId: accountId, clientSessionId: clientSessionId, itemId: itemId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000))
      scope.close(database)

      let reopened = try scope.open(at: databaseURL, fileAttributes: FakeFileAttributeApplying())
      let reopenedOutbox = try OutboxStore(database: reopened)
      let reopenedStore = PlaybackSessionStore(database: reopened, outbox: reopenedOutbox)

      let active = try reopenedStore.fetchActiveSession(accountId: accountId)
      #expect(active?.clientSessionId == clientSessionId)
    }
  }

  @Test func fetchActiveSessionIsNilWhenNoSessionExists() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    #expect(try store.fetchActiveSession(accountId: accountId) == nil)
  }

  // MARK: - Duplicate UUID quarantine

  @Test func duplicateClientSessionIdQuarantinesTheExistingRowAndThrows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)
    let clientSessionId = UUID().uuidString

    let first = try store.startSession(
      accountId: accountId, clientSessionId: clientSessionId, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    #expect(throws: PlaybackSessionStoreError.self) {
      try store.startSession(
        accountId: accountId, clientSessionId: clientSessionId, itemId: itemId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_100))
    }

    let quarantined = try database.read { db in try PlaybackSessionRecord.fetchOne(db, key: first.id) }
    #expect(quarantined?.state == .quarantined)

    let rows = try database.read { db in try PlaybackSessionRecord.fetchAll(db) }
    #expect(rows.count == 1, "no second row is created for the rejected duplicate")

    // A quarantined row must never satisfy the active-session lookup or block a fresh session.
    #expect(try store.fetchActiveSession(accountId: accountId) == nil)
  }

  // MARK: - Local session upload material + acknowledgement

  @Test func fetchLocalSessionUploadMaterialReportsIdentityTimestampsAndFinishedState() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let started = try store.startSession(
      accountId: accountId, clientSessionId: "client-session-1", itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000), isOffline: true)
    let sessionId = try #require(started.id)
    _ = try store.recordLocalTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 30, isFinished: true, deltaSecondsSinceLastTick: 30, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-0", now: Date(timeIntervalSince1970: 1_700_000_030)))
    _ = try store.closeLocalSession(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: 30, deltaSecondsSinceLastSend: 0, localSequence: 1,
        now: Date(timeIntervalSince1970: 1_700_000_030)))

    let material = try #require(try store.fetchLocalSessionUploadMaterial(sessionId: sessionId))
    #expect(material.clientSessionId == "client-session-1")
    #expect(material.itemServerId == "item-1")
    #expect(material.episodeServerId == nil)
    #expect(material.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
    #expect(material.updatedAt == Date(timeIntervalSince1970: 1_700_000_030))
    #expect(material.isFinished == true)
    #expect(material.state == .closedAwaitingUpload)
    // Never recorded for this session, so the upload has no start to claim. Distinct from a
    // recorded start of `0`.
    #expect(material.startPosition == nil)
  }

  @Test func localSessionUploadMaterialCarriesTheRecordedStartPosition() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let started = try store.startSession(
      accountId: accountId, clientSessionId: "client-session-start", itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000), isOffline: true)
    let sessionId = try #require(started.id)
    _ = try store.setStartPosition(sessionId: sessionId, startPosition: 19_520.5)

    // Ticking past the start never moves it: a session's start is frozen at open time.
    _ = try store.recordLocalTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 19_580, isFinished: false, deltaSecondsSinceLastTick: 60, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-0", now: Date(timeIntervalSince1970: 1_700_000_060)))
    _ = try store.closeLocalSession(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: 19_580, deltaSecondsSinceLastSend: 0, localSequence: 1,
        now: Date(timeIntervalSince1970: 1_700_000_060)))

    let material = try #require(try store.fetchLocalSessionUploadMaterial(sessionId: sessionId))
    #expect(material.startPosition == 19_520.5)
  }

  @Test func acknowledgeLocalUploadDeletesTheOutboxRowAndTheSessionRowTogether() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let started = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000), isOffline: true)
    let sessionId = try #require(started.id)
    _ = try store.closeLocalSession(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: 10, deltaSecondsSinceLastSend: 10, localSequence: 1,
        now: Date(timeIntervalSince1970: 1_700_000_010)))
    let queued = try outbox.fetchQueuedLocalSessionUploads(accountId: accountId, limit: 50)
    let operationId = try #require(queued.first?.id)

    try store.acknowledgeLocalUpload(operationId: operationId, sessionId: sessionId)

    #expect(try store.fetchSession(id: sessionId) == nil)
    #expect(try outbox.fetchQueuedLocalSessionUploads(accountId: accountId, limit: 50).isEmpty)
  }

  @Test func releaseHeldLocalUploadOverwritesTimestampsAndReturnsTheRowToPending() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let started = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000), isOffline: true)
    let sessionId = try #require(started.id)
    _ = try store.closeLocalSession(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: 10, deltaSecondsSinceLastSend: 10, localSequence: 1,
        now: Date(timeIntervalSince1970: 9_999_999_999)))
    let queued = try outbox.fetchQueuedLocalSessionUploads(accountId: accountId, limit: 50)
    let operationId = try #require(queued.first?.id)
    try await outbox.transitionAsync(operationId: operationId, to: .needsResolution)

    let clampedStart = Date(timeIntervalSince1970: 1_700_000_300)
    let clampedUpdate = Date(timeIntervalSince1970: 1_700_000_300)
    try store.releaseHeldLocalUpload(
      operationId: operationId, sessionId: sessionId, clampedStartedAt: clampedStart, clampedUpdatedAt: clampedUpdate)

    let material = try #require(try store.fetchLocalSessionUploadMaterial(sessionId: sessionId))
    #expect(material.startedAt == clampedStart)
    #expect(material.updatedAt == clampedUpdate)
    let released = try #require(
      try outbox.fetchQueued(accountId: accountId, entityKey: "session:\(started.clientSessionId)").first)
    #expect(released.state == .pending)
  }

  @Test func discardHeldLocalUploadRemovesTheOutboxRowButKeepsTheSessionAsHistory() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let started = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000), isOffline: true)
    let sessionId = try #require(started.id)
    _ = try store.closeLocalSession(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: 10, deltaSecondsSinceLastSend: 10, localSequence: 1,
        now: Date(timeIntervalSince1970: 1_700_000_010)))
    let queued = try outbox.fetchQueuedLocalSessionUploads(accountId: accountId, limit: 50)
    let operationId = try #require(queued.first?.id)

    try store.discardHeldLocalUpload(operationId: operationId)

    #expect(try outbox.fetchQueuedLocalSessionUploads(accountId: accountId, limit: 50).isEmpty)
    let survivingSession = try #require(try store.fetchSession(id: sessionId))
    #expect(survivingSession.state == .closedAwaitingUpload, "retained as local history, never marked uploaded")
  }

  // MARK: - Async persistence surface (w3c)

  @Test func startSessionAsyncMatchesTheSyncTwin() async throws {
    let sync = try await makeFixture()
    let async = try await makeFixture()
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

    let syncRecord = try sync.store.startSession(
      accountId: sync.accountId, clientSessionId: "session-1", itemId: sync.itemId,
      duration: 3600, startedAt: startedAt)
    let asyncRecord = try await async.store.startSessionAsync(
      accountId: async.accountId, clientSessionId: "session-1", itemId: async.itemId,
      duration: 3600, startedAt: startedAt)

    #expect(asyncRecord == syncRecord)
    #expect(try await sessionRows(in: async) == sessionRows(in: sync))
  }

  @Test func fetchActiveSessionAsyncMatchesTheSyncTwin() async throws {
    let sync = try await makeFixture()
    let async = try await makeFixture()
    _ = try seedSession(in: sync, clientSessionId: "session-1")
    _ = try seedSession(in: async, clientSessionId: "session-1")

    let syncRecord = try sync.store.fetchActiveSession(accountId: sync.accountId)
    let asyncRecord = try await async.store.fetchActiveSessionAsync(accountId: async.accountId)

    #expect(asyncRecord == syncRecord)
  }

  @Test func fetchActiveOfflineSessionAsyncMatchesTheSyncTwin() async throws {
    let sync = try await makeFixture()
    let async = try await makeFixture()
    _ = try seedSession(in: sync, clientSessionId: "offline-1", isOffline: true)
    _ = try seedSession(in: async, clientSessionId: "offline-1", isOffline: true)

    let syncRecord = try sync.store.fetchActiveOfflineSession(accountId: sync.accountId)
    let asyncRecord = try await async.store.fetchActiveOfflineSessionAsync(accountId: async.accountId)

    #expect(asyncRecord == syncRecord)
  }

  @Test func fetchSessionAsyncMatchesTheSyncTwin() async throws {
    let sync = try await makeFixture()
    let async = try await makeFixture()
    let syncRecord = try seedSession(in: sync, clientSessionId: "session-1")
    let asyncRecord = try seedSession(in: async, clientSessionId: "session-1")
    let syncSessionId = try #require(syncRecord.id)
    let asyncSessionId = try #require(asyncRecord.id)

    let expected = try sync.store.fetchSession(id: syncSessionId)
    let actual = try await async.store.fetchSessionAsync(id: asyncSessionId)

    #expect(actual == expected)
  }

  @Test func setServerSessionIdAsyncMatchesTheSyncTwin() async throws {
    let sync = try await makeFixture()
    let async = try await makeFixture()
    let syncRecord = try seedSession(in: sync, clientSessionId: "session-1")
    let asyncRecord = try seedSession(in: async, clientSessionId: "session-1")

    let syncUpdated = try sync.store.setServerSessionId(
      sessionId: try #require(syncRecord.id), serverSessionId: "server-session-1")
    let asyncUpdated = try await async.store.setServerSessionIdAsync(
      sessionId: try #require(asyncRecord.id), serverSessionId: "server-session-1")

    #expect(asyncUpdated == syncUpdated)
    #expect(try await sessionRows(in: async) == sessionRows(in: sync))
  }

  @Test func closeAsyncMatchesTheSyncTwinAndKeepsTheCloseTransactionShape() async throws {
    let sync = try await makeFixture()
    let async = try await makeFixture()
    let syncRecord = try seedSession(in: sync, clientSessionId: "session-1", duration: 3600)
    let asyncRecord = try seedSession(in: async, clientSessionId: "session-1", duration: 3600)
    let syncSessionId = try #require(syncRecord.id)
    let asyncSessionId = try #require(asyncRecord.id)
    _ = try sync.store.recordTick(
      sessionId: syncSessionId,
      tick: PlaybackTick(
        globalPosition: 42, isFinished: false, deltaSecondsSinceLastTick: 12, localSequence: 1,
        originKey: "client-uuid", segmentKey: "segment-1",
        now: Date(timeIntervalSince1970: 1_700_000_042)))
    _ = try async.store.recordTick(
      sessionId: asyncSessionId,
      tick: PlaybackTick(
        globalPosition: 42, isFinished: false, deltaSecondsSinceLastTick: 12, localSequence: 1,
        originKey: "client-uuid", segmentKey: "segment-1",
        now: Date(timeIntervalSince1970: 1_700_000_042)))
    let tick = PlaybackSessionClose(
      globalPosition: 50, deltaSecondsSinceLastSend: 3, localSequence: 2,
      now: Date(timeIntervalSince1970: 1_700_000_050))

    let syncClosed = try sync.store.close(sessionId: syncSessionId, tick: tick)
    let asyncClosed = try await async.store.closeAsync(sessionId: asyncSessionId, tick: tick)

    #expect(asyncClosed == syncClosed)
    #expect(try await sessionRows(in: async) == sessionRows(in: sync))
    #expect(try await outboxShapes(in: async) == outboxShapes(in: sync))
    #expect(try await outboxShapes(in: async).count == 2)
  }

  @Test func closeLocalSessionAsyncMatchesTheSyncTwinAndKeepsTheUploadTransactionShape() async throws {
    let sync = try await makeFixture()
    let async = try await makeFixture()
    let syncRecord = try seedSession(in: sync, clientSessionId: "offline-1", isOffline: true)
    let asyncRecord = try seedSession(in: async, clientSessionId: "offline-1", isOffline: true)
    let syncSessionId = try #require(syncRecord.id)
    let asyncSessionId = try #require(asyncRecord.id)
    _ = try sync.store.recordLocalTick(
      sessionId: syncSessionId,
      tick: PlaybackTick(
        globalPosition: 30, isFinished: true, deltaSecondsSinceLastTick: 30, localSequence: 1,
        originKey: "client-uuid", segmentKey: "segment-1",
        now: Date(timeIntervalSince1970: 1_700_000_030)))
    _ = try async.store.recordLocalTick(
      sessionId: asyncSessionId,
      tick: PlaybackTick(
        globalPosition: 30, isFinished: true, deltaSecondsSinceLastTick: 30, localSequence: 1,
        originKey: "client-uuid", segmentKey: "segment-1",
        now: Date(timeIntervalSince1970: 1_700_000_030)))
    let tick = PlaybackSessionClose(
      globalPosition: 40, deltaSecondsSinceLastSend: 5, localSequence: 2,
      now: Date(timeIntervalSince1970: 1_700_000_040))

    let syncClosed = try sync.store.closeLocalSession(sessionId: syncSessionId, tick: tick)
    let asyncClosed = try await async.store.closeLocalSessionAsync(sessionId: asyncSessionId, tick: tick)

    #expect(asyncClosed == syncClosed)
    #expect(try await sessionRows(in: async) == sessionRows(in: sync))
    #expect(try await outboxShapes(in: async) == outboxShapes(in: sync))
    let shapes = try await outboxShapes(in: async)
    #expect(
      shapes.filter { $0.operationKind == OutboxOperationKind.localSessionUpload.rawValue }.count == 1,
      "exactly one upload row, whichever else the close leaves behind")
    #expect(shapes.count == 3, "that upload plus the rule-11a position mirror and finished assertion")
  }

  @Test func acknowledgeSyncAsyncMatchesTheSyncTwinAndRemovesOnlyItsOperation() async throws {
    let sync = try await makeFixture()
    let async = try await makeFixture()
    let syncRecord = try seedSession(in: sync, clientSessionId: "session-1")
    let asyncRecord = try seedSession(in: async, clientSessionId: "session-1")
    let syncSessionId = try #require(syncRecord.id)
    let asyncSessionId = try #require(asyncRecord.id)
    _ = try sync.store.recordTick(
      sessionId: syncSessionId,
      tick: PlaybackTick(
        globalPosition: 20, isFinished: false, deltaSecondsSinceLastTick: 20, localSequence: 1,
        originKey: "client-uuid", segmentKey: "segment-1",
        now: Date(timeIntervalSince1970: 1_700_000_020)))
    _ = try async.store.recordTick(
      sessionId: asyncSessionId,
      tick: PlaybackTick(
        globalPosition: 20, isFinished: false, deltaSecondsSinceLastTick: 20, localSequence: 1,
        originKey: "client-uuid", segmentKey: "segment-1",
        now: Date(timeIntervalSince1970: 1_700_000_020)))
    let syncOperationId = try #require(
      try sync.outbox.fetchQueued(accountId: sync.accountId, entityKey: "session:session-1").first?.id)
    let asyncOperationId = try #require(
      try async.outbox.fetchQueued(accountId: async.accountId, entityKey: "session:session-1").first?.id)

    try sync.store.acknowledgeSync(operationId: syncOperationId, sessionId: syncSessionId)
    try await async.store.acknowledgeSyncAsync(operationId: asyncOperationId, sessionId: asyncSessionId)

    #expect(try await sessionRows(in: async) == sessionRows(in: sync))
    #expect(try await outboxShapes(in: async) == outboxShapes(in: sync))
    #expect(try await outboxShapes(in: async).isEmpty)
    #expect(try await sessionRows(in: async).first?.listenedDeltaSeconds == 0)
  }

  @Test func acknowledgeCloseAsyncMatchesTheSyncTwinAndDeletesTheSessionWithItsOperation() async throws {
    let sync = try await makeFixture()
    let async = try await makeFixture()
    let syncRecord = try seedSession(in: sync, clientSessionId: "session-1")
    let asyncRecord = try seedSession(in: async, clientSessionId: "session-1")
    let syncSessionId = try #require(syncRecord.id)
    let asyncSessionId = try #require(asyncRecord.id)
    let tick = PlaybackSessionClose(
      globalPosition: 10, deltaSecondsSinceLastSend: 10, localSequence: 1,
      now: Date(timeIntervalSince1970: 1_700_000_010))
    _ = try sync.store.close(sessionId: syncSessionId, tick: tick)
    _ = try async.store.close(sessionId: asyncSessionId, tick: tick)
    let syncOperationId = try #require(
      try sync.outbox.fetchQueued(accountId: sync.accountId, entityKey: "session:session-1").last?.id)
    let asyncOperationId = try #require(
      try async.outbox.fetchQueued(accountId: async.accountId, entityKey: "session:session-1").last?.id)

    try sync.store.acknowledgeClose(operationId: syncOperationId, sessionId: syncSessionId)
    try await async.store.acknowledgeCloseAsync(operationId: asyncOperationId, sessionId: asyncSessionId)

    #expect(try await sessionRows(in: async) == sessionRows(in: sync))
    #expect(try await outboxShapes(in: async) == outboxShapes(in: sync))
    #expect(try await sessionRows(in: async).isEmpty)
    #expect(try await outboxShapes(in: async).isEmpty)
  }

  @Test func fetchLocalSessionUploadMaterialAsyncMatchesTheSyncTwin() async throws {
    let sync = try await makeFixture()
    let async = try await makeFixture()
    let syncRecord = try seedSession(in: sync, clientSessionId: "offline-1", isOffline: true)
    let asyncRecord = try seedSession(in: async, clientSessionId: "offline-1", isOffline: true)
    let syncSessionId = try #require(syncRecord.id)
    let asyncSessionId = try #require(asyncRecord.id)
    let tick = PlaybackSessionClose(
      globalPosition: 25, deltaSecondsSinceLastSend: 7, localSequence: 1,
      now: Date(timeIntervalSince1970: 1_700_000_025))
    _ = try sync.store.closeLocalSession(sessionId: syncSessionId, tick: tick)
    _ = try async.store.closeLocalSession(sessionId: asyncSessionId, tick: tick)

    let syncMaterial = try sync.store.fetchLocalSessionUploadMaterial(sessionId: syncSessionId)
    let asyncMaterial = try await async.store.fetchLocalSessionUploadMaterialAsync(sessionId: asyncSessionId)

    #expect(asyncMaterial == syncMaterial)
  }

  @Test func releaseHeldLocalUploadAsyncMatchesTheSyncTwin() async throws {
    let sync = try await makeFixture()
    let async = try await makeFixture()
    let syncRecord = try seedSession(in: sync, clientSessionId: "offline-1", isOffline: true)
    let asyncRecord = try seedSession(in: async, clientSessionId: "offline-1", isOffline: true)
    let syncSessionId = try #require(syncRecord.id)
    let asyncSessionId = try #require(asyncRecord.id)
    let tick = PlaybackSessionClose(
      globalPosition: 25, deltaSecondsSinceLastSend: 7, localSequence: 1,
      now: Date(timeIntervalSince1970: 1_700_000_025))
    _ = try sync.store.closeLocalSession(sessionId: syncSessionId, tick: tick)
    _ = try async.store.closeLocalSession(sessionId: asyncSessionId, tick: tick)
    let syncOperationId = try #require(
      try sync.outbox.fetchQueuedLocalSessionUploads(accountId: sync.accountId, limit: 50).first?.id)
    let asyncOperationId = try #require(
      try async.outbox.fetchQueuedLocalSessionUploads(accountId: async.accountId, limit: 50).first?.id)
    _ = try await sync.outbox.transitionAsync(operationId: syncOperationId, to: .needsResolution)
    _ = try await async.outbox.transitionAsync(operationId: asyncOperationId, to: .needsResolution)
    let clamped = Date(timeIntervalSince1970: 1_700_000_300)

    try sync.store.releaseHeldLocalUpload(
      operationId: syncOperationId, sessionId: syncSessionId,
      clampedStartedAt: clamped, clampedUpdatedAt: clamped)
    try await async.store.releaseHeldLocalUploadAsync(
      operationId: asyncOperationId, sessionId: asyncSessionId,
      clampedStartedAt: clamped, clampedUpdatedAt: clamped)

    #expect(try await sessionRows(in: async) == sessionRows(in: sync))
    #expect(try await outboxShapes(in: async) == outboxShapes(in: sync))
    let material = try await async.store.fetchLocalSessionUploadMaterialAsync(sessionId: asyncSessionId)
    #expect(material?.startedAt == clamped)
    #expect(material?.updatedAt == clamped)
    #expect(try await outboxShapes(in: async).first?.state == .pending)
  }

  @Test func discardHeldLocalUploadAsyncMatchesThePlainSyncTwin() async throws {
    let sync = try await makeFixture()
    let async = try await makeFixture()
    let syncRecord = try seedSession(in: sync, clientSessionId: "offline-1", isOffline: true)
    let asyncRecord = try seedSession(in: async, clientSessionId: "offline-1", isOffline: true)
    let syncSessionId = try #require(syncRecord.id)
    let asyncSessionId = try #require(asyncRecord.id)
    let tick = PlaybackSessionClose(
      globalPosition: 25, deltaSecondsSinceLastSend: 7, localSequence: 1,
      now: Date(timeIntervalSince1970: 1_700_000_025))
    _ = try sync.store.closeLocalSession(sessionId: syncSessionId, tick: tick)
    _ = try async.store.closeLocalSession(sessionId: asyncSessionId, tick: tick)
    let syncOperationId = try #require(
      try sync.outbox.fetchQueuedLocalSessionUploads(accountId: sync.accountId, limit: 50).first?.id)
    let asyncOperationId = try #require(
      try async.outbox.fetchQueuedLocalSessionUploads(accountId: async.accountId, limit: 50).first?.id)

    try sync.store.discardHeldLocalUpload(operationId: syncOperationId)
    try await async.store.discardHeldLocalUploadAsync(operationId: asyncOperationId)

    #expect(try await sessionRows(in: async) == sessionRows(in: sync))
    #expect(try await outboxShapes(in: async) == outboxShapes(in: sync))
  }

  @Test func discardHeldLocalUploadAsyncMatchesTheServerApplyingSyncTwin() async throws {
    let sync = try await makeFixture()
    let async = try await makeFixture()
    let syncRecord = try seedSession(in: sync, clientSessionId: "offline-1", isOffline: true)
    let asyncRecord = try seedSession(in: async, clientSessionId: "offline-1", isOffline: true)
    let syncSessionId = try #require(syncRecord.id)
    let asyncSessionId = try #require(asyncRecord.id)
    let tick = PlaybackSessionClose(
      globalPosition: 25, deltaSecondsSinceLastSend: 7, localSequence: 1,
      now: Date(timeIntervalSince1970: 1_700_000_025))
    _ = try sync.store.closeLocalSession(sessionId: syncSessionId, tick: tick)
    _ = try async.store.closeLocalSession(sessionId: asyncSessionId, tick: tick)
    let syncOperationId = try #require(
      try sync.outbox.fetchQueuedLocalSessionUploads(accountId: sync.accountId, limit: 50).first?.id)
    let asyncOperationId = try #require(
      try async.outbox.fetchQueuedLocalSessionUploads(accountId: async.accountId, limit: 50).first?.id)
    let serverUpdatedAt = Date(timeIntervalSince1970: 1_700_000_400)

    try sync.store.discardHeldLocalUpload(
      operationId: syncOperationId, sessionId: syncSessionId, applyingServerCurrentTime: 4,
      serverIsFinished: true, serverUpdatedAt: serverUpdatedAt)
    try await async.store.discardHeldLocalUploadAsync(
      operationId: asyncOperationId, sessionId: asyncSessionId, applyingServerCurrentTime: 4,
      serverIsFinished: true, serverUpdatedAt: serverUpdatedAt)

    #expect(try await sessionRows(in: async) == sessionRows(in: sync))
    #expect(try await outboxShapes(in: async) == outboxShapes(in: sync))
    #expect(try await progressRows(in: async) == progressRows(in: sync))
    #expect(try await outboxShapes(in: async).isEmpty)
    let progress = try #require(try await progressRows(in: async).first)
    #expect(progress.currentTime == 4)
    #expect(progress.isFinished)
    #expect(progress.serverUpdatedAt == serverUpdatedAt)
    #expect(progress.origin == .server)
    #expect(progress.originKey == ProgressOrigin.serverOriginKey)
  }

  // MARK: - Local-session position mirroring

  @Test func localTickMirrorsItsPositionWithoutEverAssertingUnfinished() async throws {
    let fixture = try await makeFixture()
    let started = try seedSession(in: fixture, clientSessionId: "client-session-1", isOffline: true)
    let sessionId = try #require(started.id)

    _ = try fixture.store.recordLocalTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 30, isFinished: false, deltaSecondsSinceLastTick: 30, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-0", now: Date(timeIntervalSince1970: 1_700_000_030)))

    let mirrored = try await progressOutboxRows(in: fixture)
    #expect(mirrored.count == 1, "a local tick mirrors its position for the server, not only at close")
    let row = try #require(mirrored.first)
    #expect(row.entityKey == "item-1")
    #expect(row.podcastEpisodeId == nil)
    #expect(row.coalescingKey == "local-session-progress")
    #expect(row.payloadCurrentTime == 30)
    #expect(
      row.payloadIsFinished == nil,
      "a position mirror must omit isFinished entirely - sending false would un-finish a server row")
    #expect(row.payloadAccumulatedDeltaSeconds == 0, "listening time stays on the rule-10 local-all path")
  }

  @Test func repeatedLocalTicksCoalesceIntoOneMirroredProgressRow() async throws {
    let fixture = try await makeFixture()
    let started = try seedSession(in: fixture, clientSessionId: "client-session-1", isOffline: true)
    let sessionId = try #require(started.id)

    for (index, position) in [30.0, 45.0, 60.0].enumerated() {
      _ = try fixture.store.recordLocalTick(
        sessionId: sessionId,
        tick: PlaybackTick(
          globalPosition: position, isFinished: false, deltaSecondsSinceLastTick: 15,
          localSequence: Int64(index + 1), originKey: "device-uuid", segmentKey: "seg-0",
          now: Date(timeIntervalSince1970: 1_700_000_000 + position)))
    }

    let mirrored = try await progressOutboxRows(in: fixture)
    #expect(mirrored.count == 1, "an unsent mirror is overwritten, never queued once per tick")
    #expect(mirrored.first?.payloadCurrentTime == 60)
    #expect(mirrored.first?.localSequence == 3)
  }

  @Test func aLocalTickThatFinishesAssertsFinishedExactlyOnce() async throws {
    let fixture = try await makeFixture()
    let started = try seedSession(in: fixture, clientSessionId: "client-session-1", isOffline: true)
    let sessionId = try #require(started.id)

    for (index, tick) in [(30.0, false), (60.0, true), (62.0, true)].enumerated() {
      _ = try fixture.store.recordLocalTick(
        sessionId: sessionId,
        tick: PlaybackTick(
          globalPosition: tick.0, isFinished: tick.1, deltaSecondsSinceLastTick: 15,
          localSequence: Int64(index + 1), originKey: "device-uuid", segmentKey: "seg-\(index)",
          now: Date(timeIntervalSince1970: 1_700_000_000 + tick.0)))
    }

    let finished = try await progressOutboxRows(in: fixture).filter { $0.payloadIsFinished == true }
    #expect(finished.count == 1, "the transition asserts finished; later already-finished ticks do not repeat it")
    #expect(finished.first?.payloadCurrentTime == 60)
    #expect(finished.first?.coalescingKey == "playback-finished:seg-1")
  }

  @Test func localTickMirrorsEpisodeScopedProgressAgainstItsEpisodeRow() async throws {
    let fixture = try await makeFixture()
    let episodeId = try await PersistenceFixtures.insertEpisode(
      fixture.database, accountId: fixture.accountId, itemId: fixture.itemId)
    let started = try fixture.store.startSession(
      accountId: fixture.accountId, clientSessionId: "client-session-1", itemId: fixture.itemId,
      podcastEpisodeId: episodeId, startedAt: Date(timeIntervalSince1970: 1_700_000_000), isOffline: true)
    let sessionId = try #require(started.id)

    _ = try fixture.store.recordLocalTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 120, isFinished: true, deltaSecondsSinceLastTick: 15, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-0", now: Date(timeIntervalSince1970: 1_700_000_120)))

    let rows = try await progressOutboxRows(in: fixture)
    #expect(rows.isEmpty == false)
    #expect(
      rows.allSatisfy { $0.entityKey == "item-1" && $0.podcastEpisodeId == episodeId },
      "every mirrored row is episode-scoped, so the drainer reaches /api/me/progress/{item}/{episode}")
    #expect(rows.contains { $0.payloadCurrentTime == 120 && $0.payloadIsFinished == nil })
    #expect(rows.contains { $0.payloadIsFinished == true })
  }

  @Test func closingALocalSessionMirrorsItsFinalPositionAlongsideTheUploadRow() async throws {
    let fixture = try await makeFixture()
    let started = try seedSession(in: fixture, clientSessionId: "client-session-1", isOffline: true)
    let sessionId = try #require(started.id)
    _ = try fixture.store.recordLocalTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 60, isFinished: false, deltaSecondsSinceLastTick: 60, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-0", now: Date(timeIntervalSince1970: 1_700_000_060)))

    _ = try fixture.store.closeLocalSession(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: 90, deltaSecondsSinceLastSend: 30, localSequence: 2,
        now: Date(timeIntervalSince1970: 1_700_000_090)))

    let mirrored = try await progressOutboxRows(in: fixture)
    #expect(mirrored.count == 1)
    #expect(
      mirrored.first?.payloadCurrentTime == 90,
      "the close carries a position up to a whole tick interval ahead of the last mirror")
    let uploads = try fixture.outbox.fetchQueuedLocalSessionUploads(accountId: fixture.accountId, limit: 50)
    #expect(uploads.count == 1, "mirroring never displaces the rule-10 local-all upload")
  }

  @Test func takingTheServerValueDropsEveryUnsentLocalClaimForThatIdentity() async throws {
    let fixture = try await makeFixture()
    let started = try seedSession(in: fixture, clientSessionId: "client-session-1", isOffline: true)
    let sessionId = try #require(started.id)
    _ = try fixture.store.recordLocalTick(
      sessionId: sessionId,
      tick: PlaybackTick(
        globalPosition: 30, isFinished: true, deltaSecondsSinceLastTick: 30, localSequence: 1,
        originKey: "device-uuid", segmentKey: "seg-0", now: Date(timeIntervalSince1970: 1_700_000_030)))
    _ = try fixture.store.closeLocalSession(
      sessionId: sessionId,
      tick: PlaybackSessionClose(
        globalPosition: 30, deltaSecondsSinceLastSend: 0, localSequence: 2,
        now: Date(timeIntervalSince1970: 1_700_000_030)))
    let uploadId = try #require(
      try fixture.outbox.fetchQueuedLocalSessionUploads(accountId: fixture.accountId, limit: 50).first?.id)

    try fixture.store.discardHeldLocalUpload(
      operationId: uploadId, sessionId: sessionId, applyingServerCurrentTime: 4,
      serverIsFinished: false, serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_500))

    #expect(
      try await progressOutboxRows(in: fixture).isEmpty,
      "a resolution that takes the server's value must not leave a mirror behind to push the local one back")
    let progress = try #require(try await progressRows(in: fixture).first)
    #expect(progress.currentTime == 4)
    #expect(progress.isFinished == false)
  }

  // MARK: - Helpers

  private func progressOutboxRows(in fixture: SessionFixture) async throws -> [OutboxOperationRecord] {
    try await fixture.database.readAsync { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.progress.rawValue)
        .order(Column("id"))
        .fetchAll(db)
    }
  }

  private struct SessionFixture {
    let database: AppDatabase
    let accountId: Int64
    let itemId: Int64
    let outbox: OutboxStore
    let store: PlaybackSessionStore
  }

  private struct OutboxShape: Equatable, Sendable {
    let accountId: Int64
    let entityKey: String
    let podcastEpisodeId: Int64?
    let operationKind: String
    let coalescingKey: String
    let payloadVersion: Int
    let localSequence: Int64
    let attempts: Int
    let nextAttemptAt: Date?
    let state: OutboxOperationState
    let payloadCurrentTime: Double?
    let payloadIsFinished: Bool?
    let payloadAccumulatedDeltaSeconds: Double?
    let payloadEbookProgress: Double?
    let payloadEbookLocation: String?
    let payloadDurationSeconds: Double?
    let playbackSessionId: Int64?
    let deadLetterReason: String?

    init(_ record: OutboxOperationRecord) {
      accountId = record.accountId
      entityKey = record.entityKey
      podcastEpisodeId = record.podcastEpisodeId
      operationKind = record.operationKind
      coalescingKey = record.coalescingKey
      payloadVersion = record.payloadVersion
      localSequence = record.localSequence
      attempts = record.attempts
      nextAttemptAt = record.nextAttemptAt
      state = record.state
      payloadCurrentTime = record.payloadCurrentTime
      payloadIsFinished = record.payloadIsFinished
      payloadAccumulatedDeltaSeconds = record.payloadAccumulatedDeltaSeconds
      payloadEbookProgress = record.payloadEbookProgress
      payloadEbookLocation = record.payloadEbookLocation
      payloadDurationSeconds = record.payloadDurationSeconds
      playbackSessionId = record.playbackSessionId
      deadLetterReason = record.deadLetterReason
    }
  }

  private func makeFixture() async throws -> SessionFixture {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    return SessionFixture(
      database: database, accountId: accountId, itemId: itemId, outbox: outbox,
      store: PlaybackSessionStore(database: database, outbox: outbox))
  }

  private func seedSession(
    in fixture: SessionFixture,
    clientSessionId: String,
    duration: Double? = nil,
    isOffline: Bool = false
  ) throws -> PlaybackSessionRecord {
    try fixture.store.startSession(
      accountId: fixture.accountId, clientSessionId: clientSessionId, itemId: fixture.itemId,
      duration: duration, startedAt: Date(timeIntervalSince1970: 1_700_000_000), isOffline: isOffline)
  }

  private func sessionRows(in fixture: SessionFixture) async throws -> [PlaybackSessionRecord] {
    try await fixture.database.readAsync { db in
      try PlaybackSessionRecord.order(Column("id")).fetchAll(db)
    }
  }

  private func outboxShapes(in fixture: SessionFixture) async throws -> [OutboxShape] {
    try await fixture.database.readAsync { db in
      try OutboxOperationRecord
        .order(Column("id"))
        .fetchAll(db)
        .map(OutboxShape.init)
    }
  }

  private func progressRows(in fixture: SessionFixture) async throws -> [MediaProgressRecord] {
    try await fixture.database.readAsync { db in
      try MediaProgressRecord.order(Column("id")).fetchAll(db)
    }
  }

  private func insertAccountAndLibrary(_ database: AppDatabase, serverUserId: String = "user-1")
    async throws -> (accountId: Int64, libraryId: Int64)
  {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: serverUserId, serverVersion: "2.10.0")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)

      return (account.id!, library.id!)
    }
  }

}
