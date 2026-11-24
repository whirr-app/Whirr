import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// Crash recovery at every outbox transition. Each test commits an operation into some state
/// through an on-disk `AppDatabase`, then simulates a mid-drain crash by opening a fresh instance
/// over the same file. `OutboxStore` recovers in `init`, so opening it is the relaunch moment.
@Suite struct OutboxCrashRecoveryTests {

  private static let legalEdges: [(from: OutboxOperationState, to: OutboxOperationState)] =
    OutboxStore.legalTransitions
    .flatMap { from, destinations in destinations.map { (from: from, to: $0) } }
    .sorted {
      let lhsFrom = String(describing: $0.from)
      let rhsFrom = String(describing: $1.from)
      if lhsFrom != rhsFrom { return lhsFrom < rhsFrom }
      return String(describing: $0.to) < String(describing: $1.to)
    }

  @Test func aFreshInsertSurvivesACrashUnchanged() async throws {
    try await withOnDiskDatabases { scope in
      let preCrashDatabase = try scope.open()
      let accountId = try await PersistenceFixtures.insertAccount(preCrashDatabase)
      let store = try OutboxStore(database: preCrashDatabase)
      let operation = try store.enqueueProgress(
        accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
        payload: OutboxProgressPayload(
          currentTime: 42, isFinished: false, accumulatedDeltaSeconds: 5))
      let operationId = operation.id!

      // Reopen fresh over the same file: the "crash" boundary.
      scope.close(preCrashDatabase)

      let reopened = try scope.open(at: scope.url())
      _ = try OutboxStore(database: reopened)

      let recovered = try await reopened.readAsync { db in
        try OutboxOperationRecord.fetchOne(db, key: operationId)
      }
      #expect(recovered?.state == .pending)
      #expect(recovered?.payloadCurrentTime == 42)
      #expect(recovered?.accountId == accountId)
    }
  }

  /// Every legal edge of the transition matrix, crossed with a crash immediately after it
  /// commits. `sending` recovers to `pending` on reopen (the crash-mid-send contract); every
  /// other committed state is durable and unchanged.
  @Test(
    arguments: legalEdges
  )
  func crashImmediatelyAfterATransitionLeavesAConsistentResumableState(
    from: OutboxOperationState, to: OutboxOperationState
  ) async throws {
    try await withOnDiskDatabases { scope in
      let preCrashDatabase = try scope.open()
      let accountId = try await PersistenceFixtures.insertAccount(preCrashDatabase)
      let store = try OutboxStore(database: preCrashDatabase)

      let operationId = try await preCrashDatabase.writeAsync { db in
        var operation = OutboxOperationRecord(
          accountId: accountId, clientOperationId: UUID().uuidString, entityKey: "item:1",
          podcastEpisodeId: nil,
          operationKind: OutboxOperationKind.progress.rawValue, coalescingKey: "session-1",
          payloadVersion: 1, localSequence: 1, state: from)
        try operation.insert(db)
        return operation.id!
      }

      let deadLetterReason: String? = (to == .deadLetter) ? "notFound" : nil
      _ = try await store.transitionAsync(
        operationId: operationId, to: to, deadLetterReason: deadLetterReason)
      // Process dies here, before any further work. The on-disk WAL write inside `transition`
      // has already committed durably.
      scope.close(preCrashDatabase)

      let reopened = try scope.open(at: scope.url())
      _ = try OutboxStore(database: reopened)

      let recovered = try await reopened.readAsync { db in
        try OutboxOperationRecord.fetchOne(db, key: operationId)
      }
      #expect(recovered != nil, "the operation must never be lost across a crash")

      if to == .sending {
        #expect(
          recovered?.state == .pending, "a crash mid-send must not strand the row in `sending`")
      } else {
        #expect(recovered?.state == to)
        if to == .deadLetter {
          #expect(recovered?.deadLetterReason == "notFound")
        }
      }
    }
  }

  @Test func crashDuringSendingWithConcurrentUnrelatedRowsRecoversOnlyTheStrandedRow() async throws {
    try await withOnDiskDatabases { scope in
      let preCrashDatabase = try scope.open()
      let accountId = try await PersistenceFixtures.insertAccount(preCrashDatabase)
      let store = try OutboxStore(database: preCrashDatabase)

      let sending = try store.enqueueProgress(
        accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
        payload: OutboxProgressPayload(
          currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
      let sendingId = sending.id!
      _ = try await store.transitionAsync(operationId: sendingId, to: .sending)

      let pending = try store.enqueueProgress(
        accountId: accountId, entityKey: "item:2", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
        payload: OutboxProgressPayload(
          currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
      let pendingId = pending.id!

      let deadLetterSource = try store.enqueueProgress(
        accountId: accountId, entityKey: "item:3", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
        payload: OutboxProgressPayload(
          currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
      let deadLetterId = deadLetterSource.id!
      _ = try await store.transitionAsync(operationId: deadLetterId, to: .sending)
      _ = try await store.transitionAsync(
        operationId: deadLetterId, to: .deadLetter, deadLetterReason: "invalid")
      scope.close(preCrashDatabase)

      let reopened = try scope.open(at: scope.url())
      _ = try OutboxStore(database: reopened)

      let rows = try await reopened.readAsync { db -> [Int64: OutboxOperationRecord] in
        let all = try OutboxOperationRecord.fetchAll(db)
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id!, $0) })
      }
      #expect(rows.count == 3, "no row may be lost across a crash")
      #expect(rows[sendingId]?.state == .pending)
      #expect(rows[pendingId]?.state == .pending)
      #expect(rows[deadLetterId]?.state == .deadLetter)
      #expect(rows[deadLetterId]?.deadLetterReason == "invalid")
    }
  }

  // MARK: - Helpers

}
