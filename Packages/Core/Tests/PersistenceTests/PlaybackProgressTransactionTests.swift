import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The atomic tick/close transactions. A tick commits `MediaProgress`, the session and a
/// `sessionSync` outbox row together; stale captured sequences are rejected; coalescing follows the
/// segment-boundary rule of `progress`-kind rows; close freezes the final delta plus `closePending`
/// atomically ahead of any request.
@Suite struct PlaybackProgressTransactionTests {

  // MARK: - Atomic tick

  @Test func tickAtomicallyUpdatesMediaProgressSessionAndCreatesOneOutboxRow() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let session = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId, duration: 500,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    let updated = try store.recordTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 20, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "client-uuid", segmentKey: "seg-1",
        now: Date(timeIntervalSince1970: 1_700_000_020)))

    #expect(updated.globalPosition == 20)
    #expect(updated.listenedDeltaSeconds == 5)
    #expect(updated.lastLocalSequence == 1)

    let progress = try database.read { db in
      try MediaProgressRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("itemId") == itemId)
        .filter(Column("podcastEpisodeId") == nil)
        .fetchOne(db)
    }
    #expect(progress?.currentTime == 20)
    #expect(progress?.isFinished == false)
    #expect(progress?.localSequence == 1)
    #expect(progress?.origin == .local)
    #expect(progress?.originKey == "client-uuid")

    let outboxRows = try database.read { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.sessionSync.rawValue)
        .fetchAll(db)
    }
    #expect(outboxRows.count == 1)
    #expect(outboxRows[0].playbackSessionId == session.id)
    #expect(outboxRows[0].payloadCurrentTime == 20)
    #expect(outboxRows[0].payloadAccumulatedDeltaSeconds == 5)
    #expect(outboxRows[0].payloadDurationSeconds == 500)
  }

  @Test func aFailingTickLeavesNoPartialWrites() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let session = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try store.recordTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 20, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 10,
        originKey: "client-uuid", segmentKey: "seg-1",
        now: Date(timeIntervalSince1970: 1_700_000_020)))

    // A stale tick must roll back the whole transaction cleanly: no session/progress mutation
    // and no new/mutated outbox row survive the rejection.
    #expect(throws: PlaybackSessionStoreError.self) {
      try store.recordTick(
        sessionId: session.id!,
        tick: PlaybackTick(
          globalPosition: 999, isFinished: false, deltaSecondsSinceLastTick: 1, localSequence: 1,
          originKey: "client-uuid", segmentKey: "seg-1",
          now: Date(timeIntervalSince1970: 1_700_000_030)))
    }

    let progress = try database.read { db in
      try MediaProgressRecord.filter(Column("itemId") == itemId).fetchOne(db)
    }
    #expect(progress?.currentTime == 20, "the rejected stale tick must not overwrite progress")

    let session2 = try store.fetchSession(id: session.id!)
    #expect(session2?.globalPosition == 20)
    #expect(session2?.listenedDeltaSeconds == 5, "the rejected tick's delta must not be applied")

    let outboxRows = try database.read { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.sessionSync.rawValue)
        .fetchAll(db)
    }
    #expect(outboxRows.count == 1, "no second/mutated row survives the rejected tick")
    #expect(outboxRows[0].payloadAccumulatedDeltaSeconds == 5)
  }

  // MARK: - Stale captured sequence

  @Test func rejectsATickWithASequenceThatPredatesTheCurrentProgressRow() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let session = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try store.recordTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 20, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 5,
        originKey: "client-uuid", segmentKey: "seg-1",
        now: Date(timeIntervalSince1970: 1_700_000_020)))

    #expect(throws: PlaybackSessionStoreError.self) {
      try store.recordTick(
        sessionId: session.id!,
        tick: PlaybackTick(
          globalPosition: 999, isFinished: false, deltaSecondsSinceLastTick: 1, localSequence: 4,
          originKey: "client-uuid", segmentKey: "seg-1",
          now: Date(timeIntervalSince1970: 1_700_000_030)))
    }
  }

  @Test func acceptsATickWithAnEqualOrLaterSequence() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let session = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try store.recordTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 20, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 5,
        originKey: "client-uuid", segmentKey: "seg-1",
        now: Date(timeIntervalSince1970: 1_700_000_020)))

    let updated = try store.recordTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 25, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 6,
        originKey: "client-uuid", segmentKey: "seg-1",
        now: Date(timeIntervalSince1970: 1_700_000_025)))
    #expect(updated.globalPosition == 25)
  }

  @Test func nextTickAdvancesPastTheHighestDurableSequenceInsideTheTransaction() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)
    let session = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: accountId,
        itemId: itemId,
        currentTime: 10,
        isFinished: false,
        localSequence: 40,
        origin: .local,
        originKey: "prior-write")
      try progress.insert(db)
    }

    let updated = try store.recordNextTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 20, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 0,
        originKey: "client-uuid", segmentKey: "seg-1",
        now: Date(timeIntervalSince1970: 1_700_000_020)))

    #expect(updated.lastLocalSequence == 41)
    let progress = try database.read { db in
      try MediaProgressRecord.filter(Column("itemId") == itemId).fetchOne(db)
    }
    #expect(progress?.localSequence == 41)
  }

  // MARK: - Coalescing

  @Test func coalescesOnlyUnsentTicksForTheSameSessionAndOrdinarySegment() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let session = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    _ = try store.recordTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "client-uuid", segmentKey: "seg-1",
        now: Date(timeIntervalSince1970: 1_700_000_010)))
    _ = try store.recordTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 15, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 2,
        originKey: "client-uuid", segmentKey: "seg-1",
        now: Date(timeIntervalSince1970: 1_700_000_015)))

    let rows = try database.read { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.sessionSync.rawValue)
        .fetchAll(db)
    }
    #expect(rows.count == 1, "two ordinary ticks in the same segment must merge into one row")
    #expect(rows[0].payloadCurrentTime == 15)
    #expect(rows[0].payloadAccumulatedDeltaSeconds == 10, "delta accumulates across the merge")
  }

  @Test func neverCoalescesAcrossASeekBoundary() async throws {
    try await assertNoCoalesce(firstSegment: "seg-1", secondSegment: "seg-1:seek")
  }

  @Test func neverCoalescesAcrossAFinishedTransitionBoundary() async throws {
    try await assertNoCoalesce(firstSegment: "seg-1:unfinished", secondSegment: "seg-1:finished")
  }

  private func assertNoCoalesce(firstSegment: String, secondSegment: String) async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let session = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    _ = try store.recordTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "client-uuid", segmentKey: firstSegment,
        now: Date(timeIntervalSince1970: 1_700_000_010)))
    _ = try store.recordTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 200, isFinished: true, deltaSecondsSinceLastTick: 1, localSequence: 2,
        originKey: "client-uuid", segmentKey: secondSegment,
        now: Date(timeIntervalSince1970: 1_700_000_011)))

    let rows = try database.read { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.sessionSync.rawValue)
        .fetchAll(db)
    }
    #expect(rows.count == 2, "a new segment must never merge into the previous one")
  }

  @Test func neverCoalescesAcrossACloseBoundary() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let session = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try store.recordTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "client-uuid", segmentKey: "seg-1",
        now: Date(timeIntervalSince1970: 1_700_000_010)))
    _ = try store.close(
      sessionId: session.id!,
      tick: PlaybackSessionClose(
        globalPosition: 12, deltaSecondsSinceLastSend: 2, localSequence: 2,
        now: Date(timeIntervalSince1970: 1_700_000_012)))

    let syncRows = try database.read { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.sessionSync.rawValue)
        .fetchAll(db)
    }
    let closeRows = try database.read { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.sessionClose.rawValue)
        .fetchAll(db)
    }
    #expect(syncRows.count == 1, "the earlier sync row is untouched by close")
    #expect(closeRows.count == 1, "close always creates its own row, never merged into the sync row")
    #expect(closeRows[0].payloadAccumulatedDeltaSeconds == 2)
  }

  // MARK: - Close atomicity

  @Test func closeAtomicallyFreezesFinalDeltaAndClosePending() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let session = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try store.recordTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 5, localSequence: 1,
        originKey: "client-uuid", segmentKey: "seg-1",
        now: Date(timeIntervalSince1970: 1_700_000_010)))

    let closed = try store.close(
      sessionId: session.id!,
      tick: PlaybackSessionClose(
        globalPosition: 14, deltaSecondsSinceLastSend: 3, localSequence: 2,
        now: Date(timeIntervalSince1970: 1_700_000_014)))

    #expect(closed.closePending == true)
    #expect(closed.listenedDeltaSeconds == 8, "prior tick delta (5) plus the close remainder (3)")
    #expect(closed.globalPosition == 14)

    let closeRow = try database.read { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.sessionClose.rawValue)
        .fetchOne(db)
    }
    #expect(closeRow?.payloadAccumulatedDeltaSeconds == 3)
    #expect(closeRow?.playbackSessionId == session.id)
  }

  @Test func closeAtomicallyPersistsAcrossACrashAndReopen() async throws {
    try await withOnDiskDatabases { scope in
      let databaseURL = scope.url()
      let database = try scope.open(fileAttributes: FakeFileAttributeApplying())
      let (accountId, libraryId) = try await insertAccountAndLibrary(database)
      let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
      let outbox = try OutboxStore(database: database)
      let store = PlaybackSessionStore(database: database, outbox: outbox)

      let session = try store.startSession(
        accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000))
      let closed = try store.close(
        sessionId: session.id!,
        tick: PlaybackSessionClose(
          globalPosition: 9, deltaSecondsSinceLastSend: 9, localSequence: 1,
          now: Date(timeIntervalSince1970: 1_700_000_009)))
      let sessionId = closed.id!
      // Process dies here. The close write already committed durably.
      scope.close(database)

      let reopened = try scope.open(at: databaseURL, fileAttributes: FakeFileAttributeApplying())
      let recoveredSession = try await reopened.readAsync { db in
        try PlaybackSessionRecord.fetchOne(db, key: sessionId)
      }
      let recoveredOutbox = try await reopened.readAsync { db in
        try OutboxOperationRecord
          .filter(Column("operationKind") == OutboxOperationKind.sessionClose.rawValue)
          .fetchOne(db)
      }
      #expect(recoveredSession?.closePending == true)
      #expect(recoveredSession?.listenedDeltaSeconds == 9)
      #expect(recoveredOutbox?.payloadAccumulatedDeltaSeconds == 9)
    }
  }

  @Test func closingTwiceWithoutAcknowledgementIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let outbox = try OutboxStore(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)

    let session = try store.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try store.close(
      sessionId: session.id!,
      tick: PlaybackSessionClose(
        globalPosition: 5, deltaSecondsSinceLastSend: 5, localSequence: 1,
        now: Date(timeIntervalSince1970: 1_700_000_005)))

    #expect(throws: PlaybackSessionStoreError.self) {
      try store.close(
        sessionId: session.id!,
        tick: PlaybackSessionClose(
          globalPosition: 6, deltaSecondsSinceLastSend: 1, localSequence: 2,
          now: Date(timeIntervalSince1970: 1_700_000_006)))
    }
  }

  // MARK: - Helpers

  private func insertAccountAndLibrary(_ database: AppDatabase) async throws -> (
    accountId: Int64, libraryId: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.10.0")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)

      return (account.id!, library.id!)
    }
  }

}
