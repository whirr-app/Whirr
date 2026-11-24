import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// Acknowledging session outbox rows. A `sessionSync` acknowledgement
/// subtracts its own frozen delta, never a concurrently-accrued one; a `sessionClose`
/// acknowledgement removes the session only in the same transaction as its outbox row.
@Suite struct PlaybackAcknowledgementTests {

  // MARK: - Sync acknowledgement

  @Test func acknowledgingASyncSubtractsExactlyThatRowsFrozenDelta() async throws {
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

    let operation = try database.read { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.sessionSync.rawValue)
        .fetchOne(db)
    }!
    try await outbox.transitionAsync(operationId: operation.id!, to: .sending)

    try store.acknowledgeSync(operationId: operation.id!, sessionId: session.id!)

    let updatedSession = try store.fetchSession(id: session.id!)
    #expect(updatedSession?.listenedDeltaSeconds == 0)

    let rows = try database.read { db in try OutboxOperationRecord.fetchAll(db) }
    #expect(rows.isEmpty)
  }

  @Test func acknowledgingASyncPreservesDeltaAccruedConcurrently() async throws {
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

    let firstOperation = try database.read { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.sessionSync.rawValue)
        .fetchOne(db)
    }!
    // Marking it `sending` excludes it from further coalescing, like the progress-outbox
    // in-flight guard (OutboxStoreTests.inFlightOperationsAreNotCoalescedAway). A new tick has to
    // open a fresh row instead of rewriting the in-flight one.
    try await outbox.transitionAsync(operationId: firstOperation.id!, to: .sending)

    // A tick lands while the first row is in flight. It gets its own segment, since a real caller
    // never reuses a coalescing key that already has a `sending` row.
    _ = try store.recordTick(
      sessionId: session.id!,
      tick: PlaybackTick(
        globalPosition: 13, isFinished: false, deltaSecondsSinceLastTick: 4, localSequence: 2,
        originKey: "client-uuid", segmentKey: "seg-2",
        now: Date(timeIntervalSince1970: 1_700_000_014)))

    try store.acknowledgeSync(operationId: firstOperation.id!, sessionId: session.id!)

    let updatedSession = try store.fetchSession(id: session.id!)
    #expect(
      updatedSession?.listenedDeltaSeconds == 4,
      "only the acknowledged row's delta (5) is subtracted from the running total (9)")

    let remainingRows = try database.read { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.sessionSync.rawValue)
        .fetchAll(db)
    }
    #expect(remainingRows.count == 1)
    #expect(remainingRows[0].payloadAccumulatedDeltaSeconds == 4)
  }

  @Test func acknowledgingASyncAcrossACrashAndReopenIsAtomic() async throws {
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
      _ = try store.recordTick(
        sessionId: session.id!,
        tick: PlaybackTick(
          globalPosition: 10, isFinished: false, deltaSecondsSinceLastTick: 6, localSequence: 1,
          originKey: "client-uuid", segmentKey: "seg-1",
          now: Date(timeIntervalSince1970: 1_700_000_010)))
      let operation = try database.read { db in
        try OutboxOperationRecord
          .filter(Column("operationKind") == OutboxOperationKind.sessionSync.rawValue)
          .fetchOne(db)
      }!
      try await outbox.transitionAsync(operationId: operation.id!, to: .sending)
      try store.acknowledgeSync(operationId: operation.id!, sessionId: session.id!)
      let sessionId = session.id!
      let operationId = operation.id!
      scope.close(database)

      let reopened = try scope.open(at: databaseURL, fileAttributes: FakeFileAttributeApplying())
      let recoveredSession = try await reopened.readAsync { db in
        try PlaybackSessionRecord.fetchOne(db, key: sessionId)
      }
      let recoveredOperation = try await reopened.readAsync { db in
        try OutboxOperationRecord.fetchOne(db, key: operationId)
      }
      #expect(recoveredSession?.listenedDeltaSeconds == 0)
      #expect(recoveredOperation == nil)
    }
  }

  // MARK: - Close acknowledgement

  @Test func acknowledgingCloseRemovesTheSessionOnlyWithItsOutboxRow() async throws {
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

    let closeOperation = try database.read { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.sessionClose.rawValue)
        .fetchOne(db)
    }!
    try await outbox.transitionAsync(operationId: closeOperation.id!, to: .sending)

    try store.acknowledgeClose(operationId: closeOperation.id!, sessionId: session.id!)

    let remainingSession = try store.fetchSession(id: session.id!)
    #expect(remainingSession == nil)
    let remainingOperation = try database.read { db in
      try OutboxOperationRecord.fetchOne(db, key: closeOperation.id)
    }
    #expect(remainingOperation == nil)
  }

  @Test func aFailingCloseAcknowledgementRemovesNeitherRow() async throws {
    struct InjectedFailure: Error {}
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
    let closeOperation = try database.read { db in
      try OutboxOperationRecord
        .filter(Column("operationKind") == OutboxOperationKind.sessionClose.rawValue)
        .fetchOne(db)
    }!

    #expect(throws: InjectedFailure.self) {
      try outbox.acknowledge(operationId: closeOperation.id!) { _ in throw InjectedFailure() }
    }

    #expect(try store.fetchSession(id: session.id!) != nil)
    let stillThere = try database.read { db in
      try OutboxOperationRecord.fetchOne(db, key: closeOperation.id)
    }
    #expect(stillThere != nil)
  }

  @Test func acknowledgingCloseAcrossACrashAndReopenIsAtomic() async throws {
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
      _ = try store.close(
        sessionId: session.id!,
        tick: PlaybackSessionClose(
          globalPosition: 5, deltaSecondsSinceLastSend: 5, localSequence: 1,
          now: Date(timeIntervalSince1970: 1_700_000_005)))
      let closeOperation = try database.read { db in
        try OutboxOperationRecord
          .filter(Column("operationKind") == OutboxOperationKind.sessionClose.rawValue)
          .fetchOne(db)
      }!
      try await outbox.transitionAsync(operationId: closeOperation.id!, to: .sending)
      try store.acknowledgeClose(operationId: closeOperation.id!, sessionId: session.id!)
      let sessionId = session.id!
      let operationId = closeOperation.id!
      scope.close(database)

      let reopened = try scope.open(at: databaseURL, fileAttributes: FakeFileAttributeApplying())
      let recoveredSession = try await reopened.readAsync { db in
        try PlaybackSessionRecord.fetchOne(db, key: sessionId)
      }
      let recoveredOperation = try await reopened.readAsync { db in
        try OutboxOperationRecord.fetchOne(db, key: operationId)
      }
      #expect(recoveredSession == nil)
      #expect(recoveredOperation == nil)
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
