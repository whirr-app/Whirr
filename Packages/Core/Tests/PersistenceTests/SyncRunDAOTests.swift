import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// Regression: `SyncRunDAO.inferDeletions`'s second-pass hard-delete/tombstone sweep must treat an
/// item with an outstanding `progress`-kind outbox row as referenced and tombstone it, not
/// hard-delete it. Progress rows are keyed by the real server item id, as written by
/// `PlaybackSessionStore.markSessionGone`'s preserved-position row and
/// `OutboxDrainer.sendProgress`'s wire `libraryItemID`. Matching a local-row-id shape
/// (`"item:<rowId>"`, which no production writer produces) would let a hard delete drop a pending
/// preserved position.
@Suite struct SyncRunDAOTests {

  @Test func tombstonesAnItemReferencedOnlyByAMarkSessionGoneProgressRow() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, serverItemId) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)

    let outbox = try OutboxStore(database: database)
    let sessionStore = PlaybackSessionStore(database: database, outbox: outbox)
    let dao = SyncRunDAO(database: database)

    // Seed the reference through the real production path: a session-gone event enqueues a
    // preserved-position `progress`-kind outbox row keyed by the server item id.
    let session = try sessionStore.startSession(
      accountId: accountId, clientSessionId: UUID().uuidString, itemId: itemId,
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try sessionStore.markSessionGone(sessionId: session.id!, now: Date(timeIntervalSince1970: 1_700_000_020))

    // markSessionGone leaves the session row behind (state `.gone`), which `isReferenced` would
    // catch via its own session branch and mask the outbox branch under test. Remove it so the
    // pending progress outbox row is the sole reference keeping this item alive.
    try await database.writeAsync { db in _ = try PlaybackSessionRecord.deleteOne(db, key: session.id!) }

    let queued = try outbox.fetchQueued(accountId: accountId, entityKey: serverItemId)
    #expect(queued.count == 1)
    #expect(queued.first?.operationKind == OutboxOperationKind.progress.rawValue)

    // Two completed traversals under later generations: pass 1 soft-deletes the now-unseen row,
    // pass 2 makes it a hard-delete candidate, which must resolve to a tombstone, not a delete.
    let first = try dao.inferDeletions(libraryId: libraryId, generation: 2)
    #expect(first.softDeletedCount == 1)
    #expect(first.hardDeletedCount == 0)
    #expect(first.tombstonedCount == 0)

    let second = try dao.inferDeletions(libraryId: libraryId, generation: 3)
    #expect(second.hardDeletedCount == 0)
    #expect(second.tombstonedCount == 1)

    let tombstone = try #require(try database.read { db in try ItemRecord.fetchOne(db, key: itemId) })
    #expect(tombstone.softDeleted == true)
    #expect(tombstone.title == "")
    #expect(tombstone.author == nil)
  }

  @Test func hardDeletesAnUnreferencedItemOnTheSecondPass() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(database, accountId: accountId, libraryId: libraryId)
    let dao = SyncRunDAO(database: database)

    _ = try dao.inferDeletions(libraryId: libraryId, generation: 2)
    let second = try dao.inferDeletions(libraryId: libraryId, generation: 3)

    #expect(second.hardDeletedCount == 1)
    #expect(second.tombstonedCount == 0)
    #expect(try database.read { db in try ItemRecord.fetchOne(db, key: itemId) } == nil)
  }

  @Test func reapsAnInvalidItemReferencedOnlyByItsTerminalQuarantineWork() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let itemId = try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "rss:7",
        mediaKind: "podcast", title: "Invalid", sortTitle: "invalid", softDeleted: true)
      try item.insert(db)
      let itemId = try #require(item.id)
      try db.execute(
        sql: """
          INSERT INTO itemQuarantine (
            itemId, accountId, serverItemId, reason, quarantinedAt, terminalizedOperationCount
          ) VALUES (?, ?, 'rss:7', 'reservedPodcastSourceIdentity', ?, 1)
          """,
        arguments: [itemId, accountId, Date(timeIntervalSince1970: 1_700_000_000)])
      var operation = OutboxOperationRecord(
        accountId: accountId, clientOperationId: "quarantine-terminal", entityKey: "rss:7",
        podcastEpisodeId: nil, operationKind: OutboxOperationKind.progress.rawValue,
        coalescingKey: "quarantine-terminal", payloadVersion: 1, localSequence: 1,
        state: .deadLetter, deadLetterReason: OutboxStore.quarantinedItemDeadLetterReason)
      try operation.insert(db)
      return itemId
    }

    let result = try SyncRunDAO(database: database).inferDeletions(
      libraryId: libraryId, generation: 2)

    #expect(result.hardDeletedCount == 1)
    try database.read { db in
      let item = try ItemRecord.fetchOne(db, key: itemId)
      let marker = try ItemQuarantineRecord.fetchOne(db, key: itemId)
      let terminalCount =
        try OutboxOperationRecord
        .filter(Column("deadLetterReason") == OutboxStore.quarantinedItemDeadLetterReason)
        .fetchCount(db)
      #expect(item == nil)
      #expect(marker != nil)
      #expect(
        terminalCount == 1,
        "the detached marker and terminal operation remain auditable after item reaping")
    }
  }

  @Test func tombstonesAnItemReferencedOnlyByASavedShelfEntry() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId)
    try await database.writeAsync { db in
      var savedShelfEntry = SavedShelfEntryRecord(
        accountId: accountId, itemId: itemId, savedAt: Date(timeIntervalSince1970: 1_700_000_000))
      try savedShelfEntry.insert(db)
    }
    let dao = SyncRunDAO(database: database)

    let first = try dao.inferDeletions(libraryId: libraryId, generation: 2)
    #expect(first.softDeletedCount == 1)
    #expect(first.hardDeletedCount == 0)
    #expect(first.tombstonedCount == 0)

    let second = try dao.inferDeletions(libraryId: libraryId, generation: 3)

    #expect(second.hardDeletedCount == 0)
    #expect(second.tombstonedCount == 1)
    let tombstone = try #require(
      try database.read { db in try ItemRecord.fetchOne(db, key: itemId) })
    #expect(tombstone.softDeleted)
    #expect(tombstone.title == "")
  }

  @Test func tombstonesAPodcastShowReferencedOnlyByUpNext() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, serverItemId) = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, mediaKind: "podcast")
    try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: itemId, serverEpisodeId: "episode-1",
        title: "Queued episode", lastSeenGeneration: 1)
      try episode.insert(db)
    }
    let queue = ListeningQueueStore(database: database, accountId: accountId)
    let identity = try #require(
      ListeningIdentity.podcastEpisode(itemID: serverItemId, episodeID: "episode-1"))
    try await queue.append(
      identity: identity)
    let dao = SyncRunDAO(database: database)

    _ = try dao.inferDeletions(libraryId: libraryId, generation: 2)
    let second = try dao.inferDeletions(libraryId: libraryId, generation: 3)

    #expect(second.hardDeletedCount == 0)
    #expect(second.tombstonedCount == 1)
    let tombstone = try #require(
      try database.read { db in try ItemRecord.fetchOne(db, key: itemId) })
    #expect(tombstone.softDeleted)
    #expect(await queue.fetchQueue().first?.isTombstone == true)
  }

  @Test func tombstonesAPodcastShowReferencedOnlyByASavedShelfEpisode() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.insertAccountAndLibrary(database)
    let (itemId, _) = try await Self.insertItem(
      database, accountId: accountId, libraryId: libraryId, mediaKind: "podcast")
    try await database.writeAsync { db in
      var episode = PodcastEpisodeRecord(
        accountId: accountId, itemId: itemId, serverEpisodeId: "episode-1",
        title: "Saved episode", lastSeenGeneration: 1)
      try episode.insert(db)

      var savedShelfEntry = SavedShelfEntryRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episode.id!,
        savedAt: Date(timeIntervalSince1970: 1_700_000_000))
      try savedShelfEntry.insert(db)
    }
    let dao = SyncRunDAO(database: database)

    let first = try dao.inferDeletions(libraryId: libraryId, generation: 2)
    #expect(first.softDeletedCount == 1)
    #expect(first.hardDeletedCount == 0)
    #expect(first.tombstonedCount == 0)

    let second = try dao.inferDeletions(libraryId: libraryId, generation: 3)

    #expect(second.hardDeletedCount == 0)
    #expect(second.tombstonedCount == 1)
    let tombstone = try #require(
      try database.read { db in try ItemRecord.fetchOne(db, key: itemId) })
    #expect(tombstone.softDeleted)
    #expect(tombstone.title == "")
  }

  @Test("sync and async next-generation wrappers produce the same result")
  func syncAndAsyncNextGenerationMatch() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, _) = try await Self.insertAccountAndLibrary(database)
    let dao = SyncRunDAO(database: database)

    let syncResult = try dao.nextGeneration(accountId: accountId)
    let asyncResult = try await dao.nextGenerationAsync(accountId: accountId)

    #expect(syncResult == asyncResult)
  }

  @Test("sync and async start-run wrappers produce the same result")
  func syncAndAsyncStartRunMatch() async throws {
    let syncDatabase = try AppDatabase.inMemory()
    let asyncDatabase = try AppDatabase.inMemory()
    let syncIDs = try await Self.insertAccountAndLibrary(syncDatabase)
    let asyncIDs = try await Self.insertAccountAndLibrary(asyncDatabase)
    let startedAt = Date(timeIntervalSince1970: 1_700_000_100)

    let syncResult = try SyncRunDAO(database: syncDatabase).startRun(
      accountId: syncIDs.accountId,
      libraryId: syncIDs.libraryId,
      reason: "manual",
      generation: 3,
      sortRequested: "mediaSequence",
      startedAt: startedAt)
    let asyncResult = try await SyncRunDAO(database: asyncDatabase).startRunAsync(
      accountId: asyncIDs.accountId,
      libraryId: asyncIDs.libraryId,
      reason: "manual",
      generation: 3,
      sortRequested: "mediaSequence",
      startedAt: startedAt)

    #expect(syncResult == asyncResult)
  }

  @Test("sync and async finish wrappers produce the same result")
  func syncAndAsyncFinishMatch() async throws {
    let syncDatabase = try AppDatabase.inMemory()
    let asyncDatabase = try AppDatabase.inMemory()
    let syncIDs = try await Self.insertAccountAndLibrary(syncDatabase)
    let asyncIDs = try await Self.insertAccountAndLibrary(asyncDatabase)
    let startedAt = Date(timeIntervalSince1970: 1_700_000_200)
    let completedAt = Date(timeIntervalSince1970: 1_700_000_220)

    let syncRun = try SyncRunDAO(database: syncDatabase).startRun(
      accountId: syncIDs.accountId,
      libraryId: syncIDs.libraryId,
      reason: "foreground",
      generation: 4,
      sortRequested: nil,
      startedAt: startedAt)
    let asyncRun = try await SyncRunDAO(database: asyncDatabase).startRunAsync(
      accountId: asyncIDs.accountId,
      libraryId: asyncIDs.libraryId,
      reason: "foreground",
      generation: 4,
      sortRequested: nil,
      startedAt: startedAt)
    try SyncRunDAO(database: syncDatabase).finish(
      runId: try #require(syncRun.id),
      state: .incomplete,
      completedAt: completedAt,
      errorCategory: "transport")
    try await SyncRunDAO(database: asyncDatabase).finishAsync(
      runId: try #require(asyncRun.id),
      state: .incomplete,
      completedAt: completedAt,
      errorCategory: "transport")

    let syncRunId = try #require(syncRun.id)
    let asyncRunId = try #require(asyncRun.id)
    let syncFetched = try SyncRunDAO(database: syncDatabase).fetch(runId: syncRunId)
    let asyncFetched = try SyncRunDAO(database: asyncDatabase).fetch(runId: asyncRunId)
    let syncResult = try #require(syncFetched)
    let asyncResult = try #require(asyncFetched)
    #expect(syncResult == asyncResult)
  }

  @Test("sync and async apply-page wrappers produce the same result")
  func syncAndAsyncApplyPageMatch() async throws {
    let syncDatabase = try AppDatabase.inMemory()
    let asyncDatabase = try AppDatabase.inMemory()
    let syncIDs = try await Self.insertAccountAndLibrary(syncDatabase)
    let asyncIDs = try await Self.insertAccountAndLibrary(asyncDatabase)
    let startedAt = Date(timeIntervalSince1970: 1_700_000_300)
    let fetchedAt = Date(timeIntervalSince1970: 1_700_000_320)
    let syncRun = try SyncRunDAO(database: syncDatabase).startRun(
      accountId: syncIDs.accountId,
      libraryId: syncIDs.libraryId,
      reason: "manual",
      generation: 5,
      sortRequested: "title",
      startedAt: startedAt)
    let asyncRun = try await SyncRunDAO(database: asyncDatabase).startRunAsync(
      accountId: asyncIDs.accountId,
      libraryId: asyncIDs.libraryId,
      reason: "manual",
      generation: 5,
      sortRequested: "title",
      startedAt: startedAt)
    let syncItem = ItemRecord(
      accountId: syncIDs.accountId,
      libraryId: syncIDs.libraryId,
      serverItemId: "same-item",
      mediaKind: "book",
      title: "Same item",
      sortTitle: "same item",
      ebookFileExt: ".EPUB")
    let asyncItem = ItemRecord(
      accountId: asyncIDs.accountId,
      libraryId: asyncIDs.libraryId,
      serverItemId: "same-item",
      mediaKind: "book",
      title: "Same item",
      sortTitle: "same item",
      ebookFileExt: ".EPUB")

    let syncResult = try SyncRunDAO(database: syncDatabase).applyPage(
      runId: try #require(syncRun.id),
      accountId: syncIDs.accountId,
      libraryId: syncIDs.libraryId,
      generation: 5,
      items: [syncItem],
      pageNumber: 0,
      fetchedAt: fetchedAt,
      resultCategory: nil)
    let asyncResult = try await SyncRunDAO(database: asyncDatabase).applyPageAsync(
      runId: try #require(asyncRun.id),
      accountId: asyncIDs.accountId,
      libraryId: asyncIDs.libraryId,
      generation: 5,
      items: [asyncItem],
      pageNumber: 0,
      fetchedAt: fetchedAt,
      resultCategory: nil)

    #expect(syncResult == asyncResult)
    let syncRunId = try #require(syncRun.id)
    let asyncRunId = try #require(asyncRun.id)
    let syncPages = try SyncRunDAO(database: syncDatabase).fetchPages(runId: syncRunId)
    let asyncPages = try SyncRunDAO(database: asyncDatabase).fetchPages(runId: asyncRunId)
    #expect(syncPages == asyncPages)
  }

  @Test("sync and async deletion-inference wrappers produce the same result")
  func syncAndAsyncInferDeletionsMatch() async throws {
    let syncDatabase = try AppDatabase.inMemory()
    let asyncDatabase = try AppDatabase.inMemory()
    let syncIDs = try await Self.insertAccountAndLibrary(syncDatabase)
    let asyncIDs = try await Self.insertAccountAndLibrary(asyncDatabase)
    _ = try await Self.insertItem(
      syncDatabase, accountId: syncIDs.accountId, libraryId: syncIDs.libraryId)
    _ = try await Self.insertItem(
      asyncDatabase, accountId: asyncIDs.accountId, libraryId: asyncIDs.libraryId)

    let syncResult = try SyncRunDAO(database: syncDatabase).inferDeletions(
      libraryId: syncIDs.libraryId, generation: 2)
    let asyncResult = try await SyncRunDAO(database: asyncDatabase).inferDeletionsAsync(
      libraryId: asyncIDs.libraryId, generation: 2)

    #expect(syncResult == asyncResult)
  }

  // MARK: - Helpers

  private static func insertAccountAndLibrary(_ database: AppDatabase) async throws -> (
    accountId: Int64, libraryId: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.35.1")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)

      return (account.id!, library.id!)
    }
  }

  private static func insertItem(
    _ database: AppDatabase,
    accountId: Int64,
    libraryId: Int64,
    mediaKind: String = "book"
  ) async throws -> (
    itemId: Int64, serverItemId: String
  ) {
    try await database.writeAsync { db in
      let serverItemId = "server-item-\(UUID().uuidString)"
      var item = PersistenceFixtures.item(
        accountId: accountId, libraryId: libraryId, serverItemId: serverItemId, mediaKind: mediaKind,
        title: "Title", sortTitle: "title")
      try item.insert(db)
      return (item.id!, serverItemId)
    }
  }
}
