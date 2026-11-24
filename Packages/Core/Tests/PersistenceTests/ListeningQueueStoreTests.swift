import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// `ListeningQueueStore`: the one durable queue store over a mixed audiobook/podcast-episode
/// `ListeningIdentity` order.
@Suite struct ListeningQueueStoreTests {

  // MARK: - Mixed append/insertNext/remove/move, dedupe, dense reordering

  @Test("append is ordered and deduplicated across audiobooks and episodes")
  func appendIsOrderedAndDeduplicatedAcrossMediaKinds() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 2, episodeCount: 2)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)

    try await store.append(identity: fixture.audiobook(0))
    try await store.append(identity: fixture.episode(0))
    try await store.append(identity: fixture.audiobook(0))  // idempotent no-op, does not move
    try await store.append(identity: fixture.episode(1))

    let queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.audiobook(0), fixture.episode(0), fixture.episode(1)])
    #expect(queue.map(\.position) == [0, 1, 2])
  }

  @Test("insert-next moves an existing identity to position zero; a new one still inserts there")
  func insertNextMovesExistingToFrontAndInsertsNewAtFront() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 2, episodeCount: 2)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))
    try await store.append(identity: fixture.episode(0))

    try await store.insertNext(identity: fixture.audiobook(0))
    #expect(await store.fetchQueue().map(\.identity) == [fixture.audiobook(0), fixture.episode(0)])

    try await store.insertNext(identity: fixture.episode(1))
    #expect(
      await store.fetchQueue().map(\.identity) == [
        fixture.episode(1), fixture.audiobook(0), fixture.episode(0),
      ])
    #expect(await store.fetchQueue().map(\.position) == [0, 1, 2])
  }

  @Test("move, remove, and clear preserve contiguous positions across media kinds")
  func moveRemoveAndClearAcrossMediaKinds() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 2, episodeCount: 2)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))
    try await store.append(identity: fixture.episode(0))
    try await store.append(identity: fixture.audiobook(1))
    try await store.append(identity: fixture.episode(1))

    try await store.move(identity: fixture.episode(1), to: 1)
    #expect(
      await store.fetchQueue().map(\.identity) == [
        fixture.audiobook(0), fixture.episode(1), fixture.episode(0), fixture.audiobook(1),
      ])
    #expect(await store.fetchQueue().map(\.position) == [0, 1, 2, 3])

    try await store.remove(identity: fixture.episode(1))
    #expect(
      await store.fetchQueue().map(\.identity) == [
        fixture.audiobook(0), fixture.episode(0), fixture.audiobook(1),
      ])
    #expect(await store.fetchQueue().map(\.position) == [0, 1, 2])

    _ = try await store.clear()
    #expect(await store.fetchQueue().isEmpty)
  }

  @Test("removing an identity or a row never queued, or moving a missing row, is a no-op")
  func removeAndMoveAreNoOpsWhenAbsent() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 1, episodeCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))

    try await store.remove(identity: fixture.episode(0))
    try await store.remove(rowID: 999_999)
    try await store.move(rowID: 999_999, to: 0)
    #expect(await store.fetchQueue().map(\.identity) == [fixture.audiobook(0)])
  }

  // MARK: - Relaunch

  @Test("queue survives reopening an on-disk database")
  func survivesRelaunch() async throws {
    try await withOnDiskDatabases { scope in
      let database = try scope.open()
      let fixture = try await Self.seed(database, audiobookCount: 1, episodeCount: 1)
      try await ListeningQueueStore(database: database, accountId: fixture.accountId)
        .append(identity: fixture.audiobook(0))
      scope.close(database)

      let reopened = try scope.open(at: scope.url())
      let rows = await ListeningQueueStore(database: reopened, accountId: fixture.accountId).fetchQueue()
      #expect(rows.map(\.identity) == [fixture.audiobook(0)])
    }
  }

  // MARK: - Projection: titles, category, tombstones

  @Test("audiobook rows project title/author; episode rows project episode/show titles")
  func projectionCarriesPrimaryAndSecondaryTitlesPerMediaKind() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 1, episodeCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))
    try await store.append(identity: fixture.episode(0))

    let queue = await store.fetchQueue()
    let audiobookRow = try #require(queue.first { $0.identity == fixture.audiobook(0) })
    #expect(audiobookRow.primaryTitle == "Book 1")
    #expect(audiobookRow.secondaryTitle == "Author 1")
    #expect(audiobookRow.category == .audiobook)

    let episodeRow = try #require(queue.first { $0.identity == fixture.episode(0) })
    #expect(episodeRow.primaryTitle == "Episode 1")
    #expect(episodeRow.secondaryTitle == "Show primary")
    #expect(episodeRow.category == .podcast)
  }

  @Test("download candidates contain queued identities without a download row")
  func fetchQueueIdentitiesWithoutDownloads() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 2, episodeCount: 2)
    let queue = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await queue.append(identity: fixture.audiobook(0))
    try await queue.append(identity: fixture.episode(0))
    try await queue.append(identity: fixture.audiobook(1))
    try await queue.append(identity: fixture.episode(1))

    let downloads = try DownloadStore(database: database)
    _ = try await downloads.enqueueAsync(
      accountId: fixture.accountId, itemId: fixture.audiobookItemIds[0],
      serverFileIno: "book-file-1", orderIndex: 0, destinationRelativePath: "book-1.m4b",
      expectedBytes: 100, expectedMimeType: "audio/mp4", fileDurationSeconds: 10)
    _ = try await downloads.enqueueAsync(
      accountId: fixture.accountId, itemId: fixture.showItemId,
      podcastEpisodeId: fixture.episodeIds[1], serverFileIno: "episode-file-2", orderIndex: 0,
      destinationRelativePath: "episode-2.m4a", expectedBytes: 100,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 10)

    #expect(
      try await queue.fetchQueueIdentitiesWithoutDownloads() == [
        fixture.episode(0), fixture.audiobook(1),
      ])
  }

  @Test("soft-deleted audiobook and soft-deleted episode both remain as queue tombstones")
  func softDeletedRowsRemainTombstones() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 1, episodeCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))
    try await store.append(identity: fixture.episode(0))

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [fixture.audiobookItemIds[0]])
      try db.execute(
        sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE id = ?",
        arguments: [fixture.episodeIds[0]])
    }

    let queue = await store.fetchQueue()
    #expect(queue.first { $0.identity == fixture.audiobook(0) }?.isTombstone == true)
    #expect(queue.first { $0.identity == fixture.episode(0) }?.isTombstone == true)
  }

  // MARK: - Rejection rules

  @Test("another account's item is rejected")
  func anotherAccountsItemIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, suffix: "first", audiobookCount: 1)
    let other = try await Self.seed(database, suffix: "second", audiobookCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)

    await #expect(throws: ListeningQueueStoreError.itemNotFound) {
      try await store.append(identity: other.audiobook(0))
    }
  }

  @Test("an unknown item is rejected")
  func unknownItemIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    let identity = try #require(ListeningIdentity.audiobook(itemID: "does-not-exist"))

    await #expect(throws: ListeningQueueStoreError.itemNotFound) {
      try await store.append(identity: identity)
    }
  }

  @Test("a soft-deleted item is rejected on insertion")
  func softDeletedItemIsRejectedOnInsertion() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 1)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [fixture.audiobookItemIds[0]])
    }
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)

    await #expect(throws: ListeningQueueStoreError.itemSoftDeleted) {
      try await store.append(identity: fixture.audiobook(0))
    }
  }

  @Test("an ebook is rejected")
  func ebookIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    let identity = try #require(
      ListeningIdentity.audiobook(itemID: fixture.ebookServerItemID))

    await #expect(throws: ListeningQueueStoreError.ebookNotQueueable) {
      try await store.append(identity: identity)
    }
  }

  @Test("a podcast item supplied without an episode identity is rejected")
  func podcastItemWithoutEpisodeIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, episodeCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    let identity = try #require(
      ListeningIdentity.audiobook(itemID: fixture.showServerItemID))

    await #expect(throws: ListeningQueueStoreError.episodeIdentityRequired) {
      try await store.append(identity: identity)
    }
  }

  @Test("an audiobook supplied with an episode identity is rejected")
  func audiobookWithEpisodeIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    let identity = try #require(
      ListeningIdentity.podcastEpisode(
        itemID: fixture.audiobookServerIDs[0], episodeID: "episode-1"))

    await #expect(throws: ListeningQueueStoreError.episodeIdentityNotAllowed) {
      try await store.append(identity: identity)
    }
  }

  @Test("an unknown episode under a real podcast item is rejected")
  func unknownEpisodeIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, episodeCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    let identity = try #require(
      ListeningIdentity.podcastEpisode(
        itemID: fixture.showServerItemID, episodeID: "no-such-episode"))

    await #expect(throws: ListeningQueueStoreError.episodeNotFound) {
      try await store.append(identity: identity)
    }
  }

  @Test("an episode belonging to a different show is rejected")
  func episodeBelongingToADifferentShowIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, suffix: "first", episodeCount: 1)
    let other = try await Self.seed(database, suffix: "second", episodeCount: 1)
    // Both shows belong to the same account, so the mismatch under test is purely
    // show-vs-episode ownership, not account isolation (that is the earlier test).
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET accountId = ? WHERE id = ?",
        arguments: [fixture.accountId, other.showItemId])
      try db.execute(
        sql: "UPDATE podcastEpisode SET accountId = ? WHERE itemId = ?",
        arguments: [fixture.accountId, other.showItemId])
    }
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    let identity = try #require(
      ListeningIdentity.podcastEpisode(
        itemID: fixture.showServerItemID, episodeID: other.episodeServerIDs[0]))

    await #expect(throws: ListeningQueueStoreError.episodeNotFound) {
      try await store.append(identity: identity)
    }
  }

  // MARK: - Concurrency at the injected mutation checkpoints

  @Test("concurrent appends across audiobooks and episodes commit one row each, densely ordered")
  func concurrentAppendsAcrossMediaKinds() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 6, episodeCount: 6)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<6 {
        group.addTask { try await store.append(identity: fixture.audiobook(index)) }
        group.addTask { try await store.append(identity: fixture.episode(index)) }
      }
      try await group.waitForAll()
    }

    let rows = await store.fetchQueue()
    #expect(rows.count == 12)
    #expect(Set(rows.map(\.identity)).count == 12)
    #expect(rows.map(\.position) == Array(0..<12))
  }

  @Test(
    "failure at either renumber checkpoint rolls the entire move back",
    arguments: [
      ListeningQueueMutationCheckpoint.afterTemporaryRenumber,
      ListeningQueueMutationCheckpoint.afterFinalRenumber,
    ])
  func reorderFailureRollsBack(checkpointToFail: ListeningQueueMutationCheckpoint) async throws {
    struct InjectedFailure: Error {}
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 2, episodeCount: 2)
    let normal = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await normal.append(identity: fixture.audiobook(0))
    try await normal.append(identity: fixture.episode(0))
    try await normal.append(identity: fixture.audiobook(1))

    let failing = ListeningQueueStore(
      database: database, accountId: fixture.accountId,
      mutationCheckpoint: { checkpoint in
        if checkpoint == checkpointToFail { throw InjectedFailure() }
      })
    await #expect(throws: InjectedFailure.self) {
      try await failing.move(identity: fixture.audiobook(1), to: 0)
    }
    #expect(
      await normal.fetchQueue().map(\.identity) == [
        fixture.audiobook(0), fixture.episode(0), fixture.audiobook(1),
      ])
    #expect(await normal.fetchQueue().map(\.position) == [0, 1, 2])
  }

  @Test("conflicting concurrent edits leave one contiguous committed order")
  func concurrentConflictingEdits() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 3, episodeCount: 3)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    for index in 0..<3 {
      try await store.append(identity: fixture.audiobook(index))
      try await store.append(identity: fixture.episode(index))
    }

    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { try await store.insertNext(identity: fixture.episode(2)) }
      group.addTask { try await store.move(identity: fixture.audiobook(2), to: 1) }
      group.addTask { try await store.remove(identity: fixture.episode(0)) }
      try await group.waitForAll()
    }

    let rows = await store.fetchQueue()
    #expect(rows.count == 5)
    #expect(Set(rows.map(\.identity)).count == 5)
    #expect(rows.contains(where: { $0.identity == fixture.episode(0) }) == false)
    #expect(rows.map(\.position) == Array(0..<5))
  }

  // MARK: - Clear / restore

  @Test("clear then restore round-trips the exact prior order")
  func clearThenRestoreRoundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 2, episodeCount: 2)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))
    try await store.append(identity: fixture.episode(0))
    try await store.append(identity: fixture.audiobook(1))
    let originalOrder = await store.fetchQueue().map(\.identity)

    let token = try await store.clear()
    #expect(await store.fetchQueue().isEmpty)

    try await store.restore(token: token)
    let restored = await store.fetchQueue()
    #expect(restored.map(\.identity) == originalOrder)
    #expect(restored.map(\.position) == [0, 1, 2])
  }

  @Test("a token minted for a different account is rejected")
  func wrongAccountTokenIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, suffix: "first", audiobookCount: 1)
    let other = try await Self.seed(database, suffix: "second", audiobookCount: 1)
    let firstStore = ListeningQueueStore(database: database, accountId: fixture.accountId)
    let secondStore = ListeningQueueStore(database: database, accountId: other.accountId)
    try await firstStore.append(identity: fixture.audiobook(0))
    let token = try await firstStore.clear()

    await #expect(throws: ListeningQueueStoreError.restoreTokenWrongAccount) {
      try await secondStore.restore(token: token)
    }
  }

  @Test("a token is stale once another mutation has happened since its clear")
  func staleTokenAfterInterveningMutationIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 2)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))
    let token = try await store.clear()

    try await store.append(identity: fixture.audiobook(1))

    await #expect(throws: ListeningQueueStoreError.restoreTokenStale) {
      try await store.restore(token: token)
    }
    // The stale restore attempt must not have touched the queue at all.
    #expect(await store.fetchQueue().map(\.identity) == [fixture.audiobook(1)])
  }

  @Test("an already-consumed token cannot be replayed")
  func alreadyConsumedTokenIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))
    let token = try await store.clear()

    try await store.restore(token: token)
    await #expect(throws: ListeningQueueStoreError.restoreTokenStale) {
      try await store.restore(token: token)
    }
  }

  @Test("a tombstoned identity restores as a tombstone, not a rejection")
  func tombstonedIdentityRestoresAsTombstone() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, episodeCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.episode(0))

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE id = ?",
        arguments: [fixture.episodeIds[0]])
    }

    let token = try await store.clear()
    try await store.restore(token: token)

    let restored = try #require(await store.fetchQueue().first)
    #expect(restored.identity == fixture.episode(0))
    #expect(restored.isTombstone)
  }

  /// Clear committed before restore-token publication. `clear()` commits before it can hand its
  /// token to anybody, so a process that ends between those two moments leaves a durably empty
  /// queue and no way back: the restore option does not exist next launch
  /// (`ListeningQueueRestoreToken` is transient, never persisted).
  @Test("clear is durable the moment it commits, whether or not its token is ever consumed")
  func clearIsDurableEvenIfItsTokenIsNeverPublished() async throws {
    try await withOnDiskDatabases { scope in
      let database = try scope.open()
      let fixture = try await Self.seed(database, audiobookCount: 2)
      let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
      try await store.append(identity: fixture.audiobook(0))
      try await store.append(identity: fixture.audiobook(1))

      // The token is dropped here, as when a process ends between `clear()` committing and the
      // model retaining its offer.
      _ = try await store.clear()
      scope.close(database)

      let reopened = try scope.open(at: scope.url())
      let reopenedStore = ListeningQueueStore(database: reopened, accountId: fixture.accountId)
      #expect(await reopenedStore.fetchQueue().isEmpty)
      let revision = try await reopened.readAsync { db in
        try Int64.fetchOne(
          db, sql: "SELECT revision FROM nativeListeningQueueRevision WHERE id = 1")
      }
      #expect(revision == 3, "the clear's own revision bump is durable too - two appends, one clear")
    }
  }

  /// Restore interrupted mid-transaction. The all-or-nothing test below fails during resolution,
  /// before any row is written; this one fails part-way through the insert loop, the only point
  /// at which a partial rebuild could survive.
  @Test("a restore interrupted mid-insert rebuilds nothing and leaves its token still usable")
  func restoreInterruptedMidTransactionRebuildsNothing() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 2, episodeCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))
    try await store.append(identity: fixture.episode(0))
    try await store.append(identity: fixture.audiobook(1))
    let originalOrder = await store.fetchQueue().map(\.identity)
    let token = try await store.clear()

    // Nothing in production can reach this trigger; it exists only to abort one statement inside
    // `restore`'s own transaction, after its first two rows are already inserted.
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          CREATE TRIGGER interrupt_listening_queue_restore
          BEFORE INSERT ON listeningQueueEntry
          WHEN (SELECT COUNT(*) FROM listeningQueueEntry WHERE accountId = NEW.accountId) = 2
          BEGIN SELECT RAISE(ABORT, 'interrupted'); END
          """)
    }

    await #expect(throws: (any Error).self) { try await store.restore(token: token) }
    #expect(await store.fetchQueue().isEmpty, "a partial rebuild is never left behind")

    // The rolled-back attempt never reached `bumpRevision`, so the token is still the live one.
    // An interrupted restore costs the user nothing but the retry.
    try await database.writeAsync { db in
      try db.execute(sql: "DROP TRIGGER interrupt_listening_queue_restore")
    }
    try await store.restore(token: token)
    #expect(await store.fetchQueue().map(\.identity) == originalOrder)
    #expect(await store.fetchQueue().map(\.position) == [0, 1, 2])
  }

  @Test("restore is all-or-nothing: one unresolvable identity rebuilds nothing")
  func restoreIsAllOrNothing() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 2)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))
    try await store.append(identity: fixture.audiobook(1))
    let token = try await store.clear()

    // The second queued item is hard-deleted after the clear, so the first identity's resolution
    // succeeds before the second fails. That proves the first is not left behind.
    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM item WHERE id = ?", arguments: [fixture.audiobookItemIds[1]])
    }

    await #expect(throws: ListeningQueueStoreError.restoreIdentityUnavailable) {
      try await store.restore(token: token)
    }
    #expect(await store.fetchQueue().isEmpty)
  }

  // MARK: - acknowledgeStarted

  @Test("acknowledgeStarted removes a row from the middle and redensifies")
  func acknowledgeStartedRemovesFromTheMiddle() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 2, episodeCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))
    try await store.append(identity: fixture.episode(0))
    try await store.append(identity: fixture.audiobook(1))

    try await store.acknowledgeStarted(identity: fixture.episode(0), rowID: nil)

    let rows = await store.fetchQueue()
    #expect(rows.map(\.identity) == [fixture.audiobook(0), fixture.audiobook(1)])
    #expect(rows.map(\.position) == [0, 1])
  }

  @Test("acknowledgeStarted is a no-op when the identity is not queued")
  func acknowledgeStartedIsNoOpWhenAbsent() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 1, episodeCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))

    try await store.acknowledgeStarted(identity: fixture.episode(0), rowID: nil)
    #expect(await store.fetchQueue().map(\.identity) == [fixture.audiobook(0)])
  }

  // MARK: - peekNextLive

  @Test("peekNextLive returns the first live row without removing it")
  func peekNextLiveDoesNotRemove() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 2)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))
    try await store.append(identity: fixture.audiobook(1))

    let first = await store.peekNextLive()
    let second = await store.peekNextLive()
    #expect(first?.identity == fixture.audiobook(0))
    #expect(second?.identity == fixture.audiobook(0))
    #expect(await store.fetchQueue().count == 2)
  }

  @Test("peekNextLive skips a tombstone without deleting it")
  func peekNextLiveSkipsTombstonesButRetainsThem() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 2)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))
    try await store.append(identity: fixture.audiobook(1))
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [fixture.audiobookItemIds[0]])
    }

    let next = await store.peekNextLive()
    #expect(next?.identity == fixture.audiobook(1))
    #expect(await store.fetchQueue().map(\.identity) == [fixture.audiobook(0), fixture.audiobook(1)])
  }

  @Test("peekNextLive returns nil once every remaining row is a tombstone")
  func peekNextLiveReturnsNilWhenAllTombstoned() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.audiobook(0))
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = 1 WHERE id = ?", arguments: [fixture.audiobookItemIds[0]])
    }

    #expect(await store.peekNextLive() == nil)
    #expect(await store.fetchQueue().count == 1)
  }

  // MARK: - No sync side effects

  @Test("queue mutations stay local and create no outbox operation")
  func mutationsCreateNoOutbox() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 1, episodeCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)

    try await store.append(identity: fixture.audiobook(0))
    try await store.append(identity: fixture.episode(0))
    try await store.insertNext(identity: fixture.episode(0))
    _ = try await store.clear()
    try await store.append(identity: fixture.audiobook(0))
    try await store.acknowledgeStarted(identity: fixture.audiobook(0), rowID: nil)

    let outboxCount = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outboxOperation")
    }
    #expect(outboxCount == 0)
  }

  @Test("queue observation re-emits committed order")
  func observationReemits() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database, audiobookCount: 1)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    let observations = PersistenceObservationCollector(store.observeQueue())
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let initial = try #require(observations.values.first)
    #expect(initial.isEmpty)

    try await store.append(identity: fixture.audiobook(0))
    #expect(await TestSupport.waitUntil { observations.contains { $0.isEmpty == false } })
    let rows = try #require(observations.last { $0.isEmpty == false })
    #expect(rows.map(\.identity) == [fixture.audiobook(0)])
  }

  // MARK: - Fixtures

  private struct Fixture {
    let accountId: Int64
    let audiobookItemIds: [Int64]
    let audiobookServerIDs: [String]
    let ebookServerItemID: String
    let showItemId: Int64
    let showServerItemID: String
    let episodeIds: [Int64]
    let episodeServerIDs: [String]
    let audiobookIdentities: [ListeningIdentity]
    let episodeIdentities: [ListeningIdentity]

    func audiobook(_ index: Int) -> ListeningIdentity {
      audiobookIdentities[index]
    }

    func episode(_ index: Int) -> ListeningIdentity {
      episodeIdentities[index]
    }
  }

  private static func seed(
    _ database: AppDatabase,
    suffix: String = "primary",
    audiobookCount: Int = 0,
    episodeCount: Int = 0
  ) async throws -> Fixture {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-\(suffix)-\(UUID().uuidString)", serverBaseURL: "server-\(suffix)",
        serverUserId: "user-\(suffix)", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library-\(suffix)", mediaType: "book",
        name: "Library")
      try library.insert(db)

      var audiobookItemIds: [Int64] = []
      var audiobookServerIDs: [String] = []
      for number in 1...max(audiobookCount, 1) where audiobookCount > 0 {
        let serverItemID = "book-\(suffix)-\(number)"
        var item = ItemRecord(
          accountId: account.id!, libraryId: library.id!, serverItemId: serverItemID,
          mediaKind: "book", title: "Book \(number)", sortTitle: "book \(number)",
          author: "Author \(number)", numAudioFiles: 4)
        try item.insert(db)
        audiobookItemIds.append(item.id!)
        audiobookServerIDs.append(serverItemID)
      }

      let ebookServerItemID = "ebook-\(suffix)"
      var ebookItem = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: ebookServerItemID,
        mediaKind: "book", title: "Ebook", sortTitle: "ebook", ebookFormat: "epub")
      try ebookItem.insert(db)

      let showServerItemID = "show-\(suffix)"
      var showItem = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: showServerItemID,
        mediaKind: "podcast", title: "Show \(suffix)", sortTitle: "show")
      try showItem.insert(db)

      var episodeIds: [Int64] = []
      var episodeServerIDs: [String] = []
      for number in 1...max(episodeCount, 1) where episodeCount > 0 {
        let serverEpisodeID = "episode-\(suffix)-\(number)"
        var episode = PodcastEpisodeRecord(
          accountId: account.id!, itemId: showItem.id!, serverEpisodeId: serverEpisodeID,
          title: "Episode \(number)", lastSeenGeneration: 1)
        try episode.insert(db)
        episodeIds.append(episode.id!)
        episodeServerIDs.append(serverEpisodeID)
      }

      return Fixture(
        accountId: account.id!,
        audiobookItemIds: audiobookItemIds,
        audiobookServerIDs: audiobookServerIDs,
        ebookServerItemID: ebookServerItemID,
        showItemId: showItem.id!,
        showServerItemID: showServerItemID,
        episodeIds: episodeIds,
        episodeServerIDs: episodeServerIDs,
        audiobookIdentities: try audiobookServerIDs.map {
          try #require(ListeningIdentity.audiobook(itemID: $0))
        },
        episodeIdentities: try episodeServerIDs.map {
          try #require(
            ListeningIdentity.podcastEpisode(itemID: showServerItemID, episodeID: $0))
        })
    }
  }
}
