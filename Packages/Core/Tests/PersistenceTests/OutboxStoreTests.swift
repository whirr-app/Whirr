import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// Outbox store, transition matrix, and coalescing.
@Suite struct OutboxStoreTests {

  // MARK: - Entity change + outbox row atomicity

  @Test func entityChangeAndOutboxRowCommitInOneTransaction() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let store = try OutboxStore(database: database)

    _ = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:\(itemId)", podcastEpisodeId: nil, coalescingKey: "session-1",
      localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 12, isFinished: false, accumulatedDeltaSeconds: 5),
      updatingLocalState: { db in
        _ = try MediaProgressRecord(
          accountId: accountId, itemId: itemId, currentTime: 12, isFinished: false,
          localSequence: 1, origin: .local, originKey: "client-uuid"
        ).inserted(db)
      })

    let (progressCount, outboxCount) = try database.read { db in
      (try MediaProgressRecord.fetchCount(db), try OutboxOperationRecord.fetchCount(db))
    }
    #expect(progressCount == 1)
    #expect(outboxCount == 1)
  }

  @Test func entityChangeAndOutboxRowCommitOrNeitherOnFailure() async throws {
    struct InjectedFailure: Error {}
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let store = try OutboxStore(database: database)

    #expect(throws: InjectedFailure.self) {
      try store.enqueueProgress(
        accountId: accountId, entityKey: "item:\(itemId)", podcastEpisodeId: nil, coalescingKey: "session-1",
        localSequence: 1,
        payload: OutboxProgressPayload(
          currentTime: 12, isFinished: false, accumulatedDeltaSeconds: 5),
        updatingLocalState: { _ in throw InjectedFailure() })
    }

    let (progressCount, outboxCount) = try database.read { db in
      (try MediaProgressRecord.fetchCount(db), try OutboxOperationRecord.fetchCount(db))
    }
    #expect(progressCount == 0)
    #expect(outboxCount == 0)
  }

  // MARK: - Launch recovery

  @Test func launchRecoveryReturnsStaleSendingRowsToPending() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)

    let operationId = try await database.writeAsync { db in
      var operation = OutboxOperationRecord(
        accountId: accountId, clientOperationId: UUID().uuidString, entityKey: "item:1",
        podcastEpisodeId: nil,
        operationKind: OutboxOperationKind.progress.rawValue, coalescingKey: "session-1",
        payloadVersion: 1, localSequence: 1, state: .sending)
      try operation.insert(db)
      return operation.id!
    }

    let store = try OutboxStore(database: database)
    _ = store

    let recovered = try database.read { db in
      try OutboxOperationRecord.fetchOne(db, key: operationId)
    }
    #expect(recovered?.state == .pending)
  }

  @Test func launchRecoveryLeavesOtherStatesUntouched() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)

    let pendingId = try await database.writeAsync { db in
      var operation = OutboxOperationRecord(
        accountId: accountId, clientOperationId: UUID().uuidString, entityKey: "item:1",
        podcastEpisodeId: nil,
        operationKind: OutboxOperationKind.progress.rawValue, coalescingKey: "session-1",
        payloadVersion: 1, localSequence: 1, state: .pending)
      try operation.insert(db)
      return operation.id!
    }
    let retryWaitingId = try await database.writeAsync { db in
      var operation = OutboxOperationRecord(
        accountId: accountId, clientOperationId: UUID().uuidString, entityKey: "item:2",
        podcastEpisodeId: nil,
        operationKind: OutboxOperationKind.progress.rawValue, coalescingKey: "session-2",
        payloadVersion: 1, localSequence: 1, state: .retryWaiting)
      try operation.insert(db)
      return operation.id!
    }

    _ = try OutboxStore(database: database)

    let pending = try database.read { db in try OutboxOperationRecord.fetchOne(db, key: pendingId) }
    let retryWaiting = try database.read { db in
      try OutboxOperationRecord.fetchOne(db, key: retryWaitingId)
    }
    #expect(pending?.state == .pending)
    #expect(retryWaiting?.state == .retryWaiting)
  }

  // MARK: - Coalescing

  @Test func coalescingMergesUnsentProgressUpdatesKeepingNewestPositionFlagsAndAccumulatedDelta()
    async throws
  {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)

    let first = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 10, isFinished: false, accumulatedDeltaSeconds: 5))
    let second = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 2,
      payload: OutboxProgressPayload(
        currentTime: 20, isFinished: false, accumulatedDeltaSeconds: 7))

    #expect(first.id == second.id, "merge must keep a single row for the coalescing key")

    let rows = try database.read { db in try OutboxOperationRecord.fetchAll(db) }
    #expect(rows.count == 1)
    #expect(rows[0].payloadCurrentTime == 20)
    #expect(rows[0].payloadIsFinished == false)
    #expect(rows[0].payloadAccumulatedDeltaSeconds == 12)
    #expect(rows[0].localSequence == 2)
  }

  @Test func coalescingNeverMergesAcrossDifferingCoalescingKeys() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)

    // Different session UUID or a seek-reset boundary, modelled as differing coalescing keys for
    // the same entity.
    _ = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 10, isFinished: false, accumulatedDeltaSeconds: 5))
    _ = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-2", localSequence: 2,
      payload: OutboxProgressPayload(
        currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))

    let rows = try database.read { db in try OutboxOperationRecord.fetchAll(db) }
    #expect(rows.count == 2)
  }

  @Test func coalescingNeverMergesItemAndEpisodeProgressForTheSameServerItem() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let episodeId = try await insertEpisode(database, accountId: accountId, itemId: itemId)
    let store = try OutboxStore(database: database)

    let item = try store.enqueueProgress(
      accountId: accountId, entityKey: "item-1", podcastEpisodeId: nil,
      coalescingKey: "same-segment", localSequence: 1,
      payload: OutboxProgressPayload(
        currentTime: 10, isFinished: false, accumulatedDeltaSeconds: 1))
    let episode = try store.enqueueProgress(
      accountId: accountId, entityKey: "item-1", podcastEpisodeId: episodeId,
      coalescingKey: "same-segment", localSequence: 2,
      payload: OutboxProgressPayload(
        currentTime: 20, isFinished: false, accumulatedDeltaSeconds: 1))

    #expect(item.id != episode.id)
    #expect(item.podcastEpisodeId == nil)
    #expect(episode.podcastEpisodeId == episodeId)
  }

  @Test func continueListeningVisibilityCoalescesWithNewestIntent() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let episodeId = try await insertEpisode(database, accountId: accountId, itemId: itemId)
    let store = try OutboxStore(database: database)

    let first = try store.enqueueContinueListeningVisibility(
      accountId: accountId,
      entityKey: "show-1",
      podcastEpisodeId: episodeId,
      localSequence: 1,
      hideFromContinueListening: true)
    let second = try store.enqueueContinueListeningVisibility(
      accountId: accountId,
      entityKey: "show-1",
      podcastEpisodeId: episodeId,
      localSequence: 2,
      hideFromContinueListening: false)

    #expect(second.id == first.id)
    let rows = try database.read { db in try OutboxOperationRecord.fetchAll(db) }
    #expect(rows.count == 1)
    #expect(rows[0].operationKind == OutboxOperationKind.continueListeningVisibility.rawValue)
    #expect(rows[0].coalescingKey == "continue-listening:\(accountId):show-1:\(episodeId)")
    #expect(rows[0].payloadHideFromContinueListening == false)
    #expect(rows[0].localSequence == 2)
  }

  @Test func continueListeningVisibilityNeverMergesWithProgress() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let episodeId = try await insertEpisode(database, accountId: accountId, itemId: itemId)
    let store = try OutboxStore(database: database)

    let progress = try store.enqueueProgress(
      accountId: accountId,
      entityKey: "show-1",
      podcastEpisodeId: episodeId,
      coalescingKey: "continue-listening:\(accountId):show-1:\(episodeId)",
      localSequence: 1,
      payload: OutboxProgressPayload(
        currentTime: 120, isFinished: false, accumulatedDeltaSeconds: 0))
    let visibility = try store.enqueueContinueListeningVisibility(
      accountId: accountId,
      entityKey: "show-1",
      podcastEpisodeId: episodeId,
      localSequence: 2,
      hideFromContinueListening: true)

    #expect(visibility.id != progress.id)
    let rows = try database.read { db in try OutboxOperationRecord.fetchAll(db) }
    #expect(rows.count == 2)
    #expect(rows.contains { $0.operationKind == OutboxOperationKind.progress.rawValue })
    #expect(
      rows.contains {
        $0.operationKind == OutboxOperationKind.continueListeningVisibility.rawValue
          && $0.payloadHideFromContinueListening == true
      })
  }

  @Test func coalescingNeverMergesAFinishedTransitionBoundary() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)

    _ = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1:unfinished",
      localSequence: 1,
      payload: OutboxProgressPayload(
        currentTime: 100, isFinished: false, accumulatedDeltaSeconds: 5))
    // The finished transition is its own coalescing boundary: a new coalescing key, not a merge.
    _ = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1:finished",
      localSequence: 2,
      payload: OutboxProgressPayload(
        currentTime: 200, isFinished: true, accumulatedDeltaSeconds: 3))

    let rows = try database.read { db in try OutboxOperationRecord.fetchAll(db) }
    #expect(rows.count == 2)
  }

  @Test func inFlightOperationsAreNotCoalescedAway() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)

    let first = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 10, isFinished: false, accumulatedDeltaSeconds: 5))
    try store.transition(operationId: first.id!, to: .sending)

    // A new update for the same entity/coalescing key arrives while the first is in flight. It
    // must not rewrite the row an acknowledgement is already pending against.
    let second = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 2,
      payload: OutboxProgressPayload(
        currentTime: 20, isFinished: false, accumulatedDeltaSeconds: 7))

    #expect(second.id != first.id)
    let rows = try database.read { db in try OutboxOperationRecord.fetchAll(db) }
    #expect(rows.count == 2)
    let sendingRow = rows.first { $0.id == first.id }
    #expect(sendingRow?.state == .sending)
    #expect(sendingRow?.payloadCurrentTime == 10, "the in-flight row's payload must not mutate")
  }

  // MARK: - Transition matrix

  private static let allStates: [OutboxOperationState] = [
    .pending, .sending, .retryWaiting, .needsResolution, .deadLetter,
  ]

  /// The full legal-transition matrix: every pair not listed here must throw. See
  /// `OutboxStore.legalTransitions` for the rationale behind each edge.
  private static let legalTransitions: Set<[OutboxOperationState]> = [
    [.pending, .sending],
    [.pending, .needsResolution],
    [.sending, .pending],
    [.sending, .retryWaiting],
    [.sending, .deadLetter],
    [.sending, .needsResolution],
    [.retryWaiting, .sending],
    [.retryWaiting, .needsResolution],
    [.needsResolution, .pending],
    [.needsResolution, .deadLetter],
    [.deadLetter, .pending],
  ]

  @Test(arguments: allStates, allStates)
  func transitionMatrix(from: OutboxOperationState, to: OutboxOperationState) async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)

    let operationId = try await database.writeAsync { db in
      var operation = OutboxOperationRecord(
        accountId: accountId, clientOperationId: UUID().uuidString, entityKey: "item:1",
        podcastEpisodeId: nil,
        operationKind: OutboxOperationKind.progress.rawValue, coalescingKey: "session-1",
        payloadVersion: 1, localSequence: 1, state: from)
      try operation.insert(db)
      return operation.id!
    }

    let isLegal = Self.legalTransitions.contains([from, to])

    if isLegal {
      let updated = try store.transition(operationId: operationId, to: to)
      #expect(updated.state == to)
    } else {
      #expect(throws: OutboxStoreError.self) {
        try store.transition(operationId: operationId, to: to)
      }
      let unchanged = try database.read { db in
        try OutboxOperationRecord.fetchOne(db, key: operationId)
      }
      #expect(unchanged?.state == from, "an illegal transition must not mutate the row")
    }
  }

  @Test func transitioningToSendingIncrementsAttempts() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)

    let operation = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    #expect(operation.attempts == 0)

    let sending = try store.transition(operationId: operation.id!, to: .sending)
    #expect(sending.attempts == 1)

    let retryWaiting = try store.transition(operationId: sending.id!, to: .retryWaiting)
    #expect(retryWaiting.attempts == 1, "a failure classification does not itself add an attempt")

    let sendingAgain = try store.transition(operationId: retryWaiting.id!, to: .sending)
    #expect(sendingAgain.attempts == 2)
  }

  @Test func cancellationReturnsSendingToPendingWithoutIncreasingAttempts() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)

    let operation = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    let sending = try store.transition(operationId: operation.id!, to: .sending)
    #expect(sending.attempts == 1)

    let cancelled = try store.transition(operationId: sending.id!, to: .pending)
    #expect(cancelled.attempts == 1)
    #expect(cancelled.state == .pending)
  }

  @Test func deadLetterRetainsAPrivacySafeReasonAndClearsOnRecovery() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)

    let operation = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    let sending = try store.transition(operationId: operation.id!, to: .sending)
    let deadLettered = try store.transition(
      operationId: sending.id!, to: .deadLetter, deadLetterReason: "notFound")
    #expect(deadLettered.deadLetterReason == "notFound")

    let retried = try store.transition(operationId: deadLettered.id!, to: .pending)
    #expect(retried.deadLetterReason == nil, "re-queueing clears the stale dead-letter reason")
  }

  @Test func nextAttemptAtIsRecordedOnRetryWaitingTransition() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)

    let operation = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    let sending = try store.transition(operationId: operation.id!, to: .sending)
    let nextAttemptAt = Date(timeIntervalSince1970: 1_700_000_500)
    let retryWaiting = try store.transition(
      operationId: sending.id!, to: .retryWaiting, nextAttemptAt: nextAttemptAt)
    #expect(retryWaiting.nextAttemptAt == nextAttemptAt)
  }

  @Test func transitionOnAMissingOperationThrowsOperationNotFound() async throws {
    let database = try AppDatabase.inMemory()
    _ = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)

    #expect(throws: OutboxStoreError.self) {
      try store.transition(operationId: 999_999, to: .sending)
    }
  }

  @Test func asyncTransitionMatchesSynchronousTwin() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let operation = try await insertOperation(
      database, accountId: accountId, state: .pending, deadLetterReason: "stale")
    let store = try OutboxStore(database: database)
    let nextAttemptAt = Date(timeIntervalSince1970: 1_700_000_500)

    let transitioned = try await store.transitionAsync(
      operationId: operation.id!, to: .sending, nextAttemptAt: nextAttemptAt)
    let persisted = try await database.readAsync { db in
      try OutboxOperationRecord.fetchOne(db, key: operation.id)
    }

    #expect(transitioned.state == .sending)
    #expect(transitioned.attempts == 1)
    #expect(transitioned.nextAttemptAt == nextAttemptAt)
    #expect(transitioned.deadLetterReason == nil)
    #expect(persisted == transitioned)
  }

  // MARK: - Acknowledgement / deletion

  @Test func rowsDeleteOnlyTogetherWithTheTransactionUpdatingLocalAuthoritativeState() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let store = try OutboxStore(database: database)

    let progressId = try await database.writeAsync { db in
      try MediaProgressRecord(
        accountId: accountId, itemId: itemId, currentTime: 5, isFinished: false, localSequence: 1,
        origin: .local, originKey: "client-uuid"
      ).inserted(db).id!
    }
    let operation = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:\(itemId)", podcastEpisodeId: nil, coalescingKey: "session-1",
      localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 5, isFinished: false, accumulatedDeltaSeconds: 5))
    try store.transition(operationId: operation.id!, to: .sending)

    try store.acknowledge(operationId: operation.id!) { db in
      guard var progress = try MediaProgressRecord.fetchOne(db, key: progressId) else {
        Issue.record("progress row must exist")
        return
      }
      progress.serverUpdatedAt = Date(timeIntervalSince1970: 1_700_000_000)
      try progress.update(db)
    }

    let (deletedOperation, progress) = try database.read { db in
      (
        try OutboxOperationRecord.fetchOne(db, key: operation.id),
        try MediaProgressRecord.fetchOne(db, key: progressId)
      )
    }
    #expect(deletedOperation == nil)
    #expect(progress?.serverUpdatedAt == Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test func acknowledgeRollsBackBothOnFailure() async throws {
    struct InjectedFailure: Error {}
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)

    let operation = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))

    #expect(throws: InjectedFailure.self) {
      try store.acknowledge(operationId: operation.id!) { _ in throw InjectedFailure() }
    }

    let stillThere = try database.read { db in
      try OutboxOperationRecord.fetchOne(db, key: operation.id)
    }
    #expect(stillThere != nil, "a failed local-state update must not delete the outbox row")
  }

  @Test func asyncAcknowledgeDeletesOnlyWithTheLocalAuthoritativeUpdate() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let store = try OutboxStore(database: database)
    let progress = try await database.writeAsync { db in
      try MediaProgressRecord(
        accountId: accountId, itemId: itemId, currentTime: 5, isFinished: false, localSequence: 1,
        origin: .local, originKey: "client-uuid"
      ).inserted(db)
    }
    let operation = try await insertOperation(
      database, accountId: accountId, state: .sending, entityKey: "item:\(itemId)")
    let acknowledgedAt = Date(timeIntervalSince1970: 1_700_000_000)

    try await store.acknowledgeAsync(operationId: operation.id!) { db in
      guard var progress = try MediaProgressRecord.fetchOne(db, key: progress.id) else {
        Issue.record("progress row must exist")
        return
      }
      progress.serverUpdatedAt = acknowledgedAt
      try progress.update(db)
    }

    let (deletedOperation, persistedProgress) = try await database.readAsync { db in
      (
        try OutboxOperationRecord.fetchOne(db, key: operation.id),
        try MediaProgressRecord.fetchOne(db, key: progress.id)
      )
    }
    #expect(deletedOperation == nil)
    #expect(persistedProgress?.serverUpdatedAt == acknowledgedAt)
  }

  @Test func asyncAcknowledgePropagatesLocalPersistenceFailureAndRollsBack() async throws {
    struct InjectedFailure: Error {}
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)
    let operation = try await insertOperation(database, accountId: accountId, state: .sending)

    do {
      try await store.acknowledgeAsync(operationId: operation.id!) { _ in
        throw InjectedFailure()
      }
      Issue.record("acknowledgeAsync must propagate a local persistence failure")
    } catch {
      #expect(error is InjectedFailure)
    }

    let stillThere = try await database.readAsync { db in
      try OutboxOperationRecord.fetchOne(db, key: operation.id)
    }
    #expect(stillThere != nil, "a failed local-state update must not delete the outbox row")
  }

  // MARK: - Async queries

  @Test func asyncFetchOperationMatchesSynchronousTwin() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let operation = try await insertOperation(database, accountId: accountId)
    let store = try OutboxStore(database: database)

    let synchronousResult = try store.fetchOperation(id: operation.id!)
    let asynchronousResult = try await store.fetchOperationAsync(id: operation.id!)

    #expect(asynchronousResult == synchronousResult)
  }

  @Test func asyncFetchDeadLettersMatchesSynchronousTwin() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)
    _ = try await insertOperation(
      database, accountId: accountId, state: .deadLetter, deadLetterReason: "notFound")
    _ = try await insertOperation(database, accountId: accountId, state: .pending)

    let synchronousResult = try store.fetchDeadLetters(accountId: accountId)
    let asynchronousResult = try await store.fetchDeadLettersAsync(accountId: accountId)

    #expect(asynchronousResult == synchronousResult)
    #expect(asynchronousResult.count == 1)
    #expect(asynchronousResult.first?.deadLetterReason == "notFound")
  }

  @Test func asyncFetchHeldLocalSessionUploadsMatchesSynchronousTwin() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let sessionId = try await insertLocalSession(
      database, accountId: accountId, itemId: itemId, clientSessionId: "local-held")
    let store = try OutboxStore(database: database)
    let held = try await insertOperation(
      database,
      accountId: accountId,
      state: .needsResolution,
      operationKind: OutboxOperationKind.localSessionUpload.rawValue,
      playbackSessionId: sessionId)
    _ = try await insertOperation(
      database,
      accountId: accountId,
      state: .pending,
      operationKind: OutboxOperationKind.localSessionUpload.rawValue,
      playbackSessionId: sessionId)
    _ = try await insertOperation(
      database,
      accountId: accountId,
      state: .needsResolution,
      operationKind: OutboxOperationKind.progress.rawValue)

    let synchronousResult = try store.fetchHeldLocalSessionUploads(accountId: accountId)
    let asynchronousResult = try await store.fetchHeldLocalSessionUploadsAsync(accountId: accountId)

    #expect(asynchronousResult == synchronousResult)
    #expect(asynchronousResult == [held])
  }

  // MARK: - Local-sequence ordering

  @Test func fetchQueuedOrdersByLocalSequencePerEntity() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)

    _ = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-3", localSequence: 3,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    _ = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    _ = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-2", localSequence: 2,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    // A different entity must not interleave into item:1's queue.
    _ = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:2", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 0,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))

    let queued = try store.fetchQueued(accountId: accountId, entityKey: "item:1")
    #expect(queued.map(\.localSequence) == [1, 2, 3])
  }

  @Test func distinctQueuedEntityKeysListsEachEntityWithAQueuedOperationOnce() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await PersistenceFixtures.insertAccount(database)
    let store = try OutboxStore(database: database)

    let first = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    _ = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1:finished",
      localSequence: 2,
      payload: OutboxProgressPayload(currentTime: 2, isFinished: true, accumulatedDeltaSeconds: 1))
    _ = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:2", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    let deadLettered = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:3", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    try store.transition(operationId: deadLettered.id!, to: .sending)
    try store.transition(operationId: deadLettered.id!, to: .deadLetter, deadLetterReason: "notFound")

    let keys = try store.distinctQueuedEntityKeys(accountId: accountId)
    #expect(Set(keys) == ["item:1", "item:2"], "item:3 has no queued row - it is fully dead-lettered")
    #expect(keys.filter { $0 == "item:1" }.count == 1, "each entity key appears once regardless of row count")
    _ = first
  }

  // MARK: - localSessionUpload routing

  @Test func distinctQueuedEntityKeysExcludesLocalSessionUploadRowsEntirely() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let sessionId = try await insertLocalSession(
      database, accountId: accountId, itemId: itemId, clientSessionId: "local-1")
    let store = try OutboxStore(database: database)

    _ = try store.enqueueProgress(
      accountId: accountId, entityKey: "item:1", podcastEpisodeId: nil, coalescingKey: "session-1", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    _ = try store.enqueueLocalSessionUpload(
      accountId: accountId, playbackSessionId: sessionId, entityKey: "session:local-1",
      coalescingKey: "session:local-1:local-upload", localSequence: 1,
      payload: OutboxSessionPayload(currentTime: 10, accumulatedDeltaSeconds: 10))

    let keys = try store.distinctQueuedEntityKeys(accountId: accountId)
    #expect(
      Set(keys) == ["item:1"],
      "localSessionUpload rows drain exclusively through fetchQueuedLocalSessionUploads, never the generic per-entity loop"
    )
  }

  @Test func fetchQueuedLocalSessionUploadsOrdersByLocalSequenceAndCapsAtTheGivenLimit() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let store = try OutboxStore(database: database)

    for sequence in stride(from: 3, through: 1, by: -1) {
      let sessionId = try await insertLocalSession(
        database, accountId: accountId, itemId: itemId, clientSessionId: "local-\(sequence)")
      _ = try store.enqueueLocalSessionUpload(
        accountId: accountId, playbackSessionId: sessionId, entityKey: "session:local-\(sequence)",
        coalescingKey: "session:local-\(sequence):local-upload", localSequence: Int64(sequence),
        payload: OutboxSessionPayload(currentTime: 10, accumulatedDeltaSeconds: 10))
    }

    let rows = try store.fetchQueuedLocalSessionUploads(accountId: accountId, limit: 2)
    #expect(rows.map(\.localSequence) == [1, 2], "oldest first, capped at the requested limit")
  }

  @Test func queuedOperationsForAnOrdinarySoftDeletedItemRemainRunnable() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let itemId = try await PersistenceFixtures.insertItem(database, accountId: accountId, libraryId: libraryId)
    let sessionId = try await insertLocalSession(
      database, accountId: accountId, itemId: itemId, clientSessionId: "quarantined-item-session")
    let store = try OutboxStore(database: database)

    let itemOperation = try store.enqueueProgress(
      accountId: accountId, entityKey: "item-1", podcastEpisodeId: nil,
      coalescingKey: "quarantined-item-progress", localSequence: 1,
      payload: OutboxProgressPayload(currentTime: 1, isFinished: false, accumulatedDeltaSeconds: 1))
    _ = try await insertOperation(
      database, accountId: accountId, entityKey: "session:quarantined-item-session",
      operationKind: OutboxOperationKind.sessionSync.rawValue, playbackSessionId: sessionId)
    _ = try await insertOperation(
      database, accountId: accountId, entityKey: "session:quarantined-item-session",
      operationKind: OutboxOperationKind.localSessionUpload.rawValue, playbackSessionId: sessionId)

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [itemId])
    }

    #expect(
      try store.fetchQueued(accountId: accountId, entityKey: "item-1").count == 1,
      "ordinary soft deletion is reversible and must not silently withhold item work")
    #expect(
      try store.fetchQueued(accountId: accountId, entityKey: "session:quarantined-item-session").count == 2,
      "ordinary soft deletion is reversible and must not silently withhold session work")
    #expect(
      Set(try store.distinctQueuedEntityKeys(accountId: accountId))
        == ["item-1", "session:quarantined-item-session"],
      "the generic drainer still discovers ordinary soft-deleted work")
    #expect(
      try store.fetchQueuedLocalSessionUploads(accountId: accountId, limit: 10).count == 1,
      "the local-session batch drainer still discovers ordinary soft-deleted work")

    let itemOperationID = try #require(itemOperation.id)
    let retained = try #require(try store.fetchOperation(id: itemOperationID))
    #expect(retained.state == .pending)
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

  private func insertEpisode(
    _ database: AppDatabase, accountId: Int64, itemId: Int64
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: itemId, serverEpisodeId: "episode-1", title: "Episode",
        lastSeenGeneration: 1)
      try episode.insert(db)
      return episode.id!
    }
  }

  /// A closed offline session row satisfying `outboxOperation`'s `playbackSessionId` FK. The
  /// `enqueueLocalSessionUpload` calls above need a real row to reference (`PRAGMA foreign_keys =
  /// ON`, AppDatabase.swift).
  private func insertLocalSession(
    _ database: AppDatabase, accountId: Int64, itemId: Int64, clientSessionId: String
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var session = PlaybackSessionRecord(
        accountId: accountId, clientSessionId: clientSessionId, itemId: itemId,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000), isOffline: true,
        state: .closedAwaitingUpload)
      try session.insert(db)
      return session.id!
    }
  }

  private func insertOperation(
    _ database: AppDatabase,
    accountId: Int64,
    state: OutboxOperationState = .pending,
    attempts: Int = 0,
    nextAttemptAt: Date? = nil,
    deadLetterReason: String? = nil,
    entityKey: String = "item:1",
    operationKind: String = OutboxOperationKind.progress.rawValue,
    playbackSessionId: Int64? = nil
  ) async throws -> OutboxOperationRecord {
    try await database.writeAsync { db in
      var operation = OutboxOperationRecord(
        accountId: accountId,
        clientOperationId: "operation-\(UUID().uuidString)",
        entityKey: entityKey,
        podcastEpisodeId: nil,
        operationKind: operationKind,
        coalescingKey: "session-1",
        payloadVersion: 1,
        localSequence: 1,
        attempts: attempts,
        nextAttemptAt: nextAttemptAt,
        state: state,
        payloadCurrentTime: 1,
        payloadIsFinished: false,
        payloadAccumulatedDeltaSeconds: 1,
        playbackSessionId: playbackSessionId,
        deadLetterReason: deadLetterReason)
      try operation.insert(db)
      return operation
    }
  }
}
