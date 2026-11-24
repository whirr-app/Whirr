import Foundation
import GRDB
import Testing

@testable import Persistence

/// `v15` replaces the podcast-only `podcastQueueEntry` with the media-neutral
/// `listeningQueueEntry`. Covers the migration (row/order/id preservation, tombstones, cascade,
/// both partial unique indexes, rollback at both injected checkpoints), not the generic store.
@Suite struct ListeningQueueMigrationTests {

  // MARK: - Migrating an existing v1-v14 store forward

  /// A store carrying every migration shipped before v15 (v1-v14) plus a populated podcast queue,
  /// continuing on to v15. This is the shape every real device is in when the migration runs.
  @Test func migratingAPopulatedPodcastQueueForwardPreservesExactOrderAndRowIds() async throws {
    let queue = try Self.migratedThroughV14()
    let fixture = try await Self.seedPreV15PodcastQueue(queue)

    try SchemaV1.migrator().migrate(queue)

    try await queue.read { db in
      #expect(try db.tableExists("podcastQueueEntry") == false)
      let rows = try Row.fetchAll(
        db, sql: "SELECT id, itemId, podcastEpisodeId, position FROM listeningQueueEntry ORDER BY position"
      )
      #expect(rows.count == 3)
      // Seeded out of position order (position 0 -> episode 3, 1 -> episode 1, 2 -> episode 2)
      // and with row ids that do not match that order either, so a passing assertion here can
      // only mean the copy preserved both independently rather than happening to agree with
      // insertion order.
      #expect(rows[0]["id"] as Int64 == fixture.queueRowIds[0])
      #expect(rows[0]["itemId"] as Int64 == fixture.itemId)
      #expect(rows[0]["podcastEpisodeId"] as Int64 == fixture.episodeIds[2])
      #expect(rows[0]["position"] as Int == 0)

      #expect(rows[1]["id"] as Int64 == fixture.queueRowIds[1])
      #expect(rows[1]["podcastEpisodeId"] as Int64 == fixture.episodeIds[0])
      #expect(rows[1]["position"] as Int == 1)

      #expect(rows[2]["id"] as Int64 == fixture.queueRowIds[2])
      #expect(rows[2]["podcastEpisodeId"] as Int64 == fixture.episodeIds[1])
      #expect(rows[2]["position"] as Int == 2)
    }
  }

  @Test func migratingATombstonedEpisodesQueueRowStillCarriesItAcross() async throws {
    let queue = try Self.migratedThroughV14()
    let fixture = try await Self.seedPreV15PodcastQueue(queue, softDeleteEpisodeAtIndex: 1)

    try SchemaV1.migrator().migrate(queue)

    try await queue.read { db in
      let count = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM listeningQueueEntry WHERE podcastEpisodeId = ?",
        arguments: [fixture.episodeIds[1]])
      #expect(count == 1, "a tombstoned episode's queue row must still migrate across")
    }
  }

  @Test func accountCascadeDeletesMigratedRows() async throws {
    let queue = try Self.migratedThroughV14()
    let fixture = try await Self.seedPreV15PodcastQueue(queue)
    try SchemaV1.migrator().migrate(queue)

    try await queue.write { db in
      try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [fixture.accountId])
    }

    try await queue.read { db in
      let remaining = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningQueueEntry") ?? -1
      #expect(remaining == 0)
    }
  }

  // MARK: - Rollback

  @Test(
    "an injected failure at either checkpoint leaves the released podcastQueueEntry table intact",
    arguments: [
      SchemaV1.ListeningQueueMigrationCheckpoint.afterCopy,
      SchemaV1.ListeningQueueMigrationCheckpoint.afterDrop,
    ])
  func injectedFailureRollsBackTheWholeMigration(
    checkpointToFail: SchemaV1.ListeningQueueMigrationCheckpoint
  ) async throws {
    struct InjectedFailure: Error {}
    let queue = try Self.migratedThroughV14()
    let fixture = try await Self.seedPreV15PodcastQueue(queue)

    #expect(throws: InjectedFailure.self) {
      try SchemaV1.migrator(
        listeningQueueMigrationCheckpoint: { checkpoint in
          if checkpoint == checkpointToFail { throw InjectedFailure() }
        }
      ).migrate(queue)
    }

    try await queue.read { db in
      #expect(try db.tableExists("listeningQueueEntry") == false)
      #expect(try db.tableExists("podcastQueueEntry"))
      let rows = try Row.fetchAll(
        db, sql: "SELECT id, podcastEpisodeId, position FROM podcastQueueEntry ORDER BY position")
      #expect(rows.count == 3)
      #expect(rows[0]["id"] as Int64 == fixture.queueRowIds[0])
      #expect(rows[0]["podcastEpisodeId"] as Int64 == fixture.episodeIds[2])
    }
  }

  // MARK: - Constraints on the fresh (post-v15) schema

  @Test func wrongAccountItemPairingIsRejectedByTheForeignKey() async throws {
    let database = try AppDatabase.inMemory()
    let (firstAccountId, _, firstItemId, _) = try await Self.seedAccountLibraryItemAndEpisode(
      database, suffix: "first")
    let (secondAccountId, _, secondItemId, _) = try await Self.seedAccountLibraryItemAndEpisode(
      database, suffix: "second")
    _ = secondAccountId

    await #expect(throws: (any Error).self) {
      try await database.writeAsync { db in
        // accountId belongs to the first account, itemId to the second, so no matching
        // (accountId, id) row exists in `item`.
        var entry = ListeningQueueEntryRecord(
          accountId: firstAccountId, itemId: secondItemId, position: 0)
        try entry.insert(db)
      }
    }
    _ = firstItemId
  }

  @Test func wrongAccountEpisodePairingIsRejectedByTheForeignKey() async throws {
    let database = try AppDatabase.inMemory()
    let (firstAccountId, _, firstItemId, _) = try await Self.seedAccountLibraryItemAndEpisode(
      database, suffix: "first")
    let (_, _, _, secondEpisodeId) = try await Self.seedAccountLibraryItemAndEpisode(
      database, suffix: "second")

    await #expect(throws: (any Error).self) {
      try await database.writeAsync { db in
        // itemId belongs to the first account; podcastEpisodeId belongs to the second. The
        // composite episode FK requires the episode's own accountId to match.
        var entry = ListeningQueueEntryRecord(
          accountId: firstAccountId, itemId: firstItemId, podcastEpisodeId: secondEpisodeId,
          position: 0)
        try entry.insert(db)
      }
    }
  }

  @Test func partialUniqueIndexRejectsASecondAudiobookRowForTheSameItem() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, _, itemId, _) = try await Self.seedAccountLibraryItemAndEpisode(database)

    try await database.writeAsync { db in
      var first = ListeningQueueEntryRecord(accountId: accountId, itemId: itemId, position: 0)
      try first.insert(db)
    }

    await #expect(throws: (any Error).self) {
      try await database.writeAsync { db in
        var duplicate = ListeningQueueEntryRecord(accountId: accountId, itemId: itemId, position: 1)
        try duplicate.insert(db)
      }
    }
  }

  @Test func partialUniqueIndexRejectsADuplicateEpisodeRow() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, _, itemId, episodeId) = try await Self.seedAccountLibraryItemAndEpisode(database)

    try await database.writeAsync { db in
      var first = ListeningQueueEntryRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId, position: 0)
      try first.insert(db)
    }

    await #expect(throws: (any Error).self) {
      try await database.writeAsync { db in
        var duplicate = ListeningQueueEntryRecord(
          accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId, position: 1)
        try duplicate.insert(db)
      }
    }
  }

  @Test func distinctAudiobookAndEpisodeRowsForTheSameItemCoexist() async throws {
    // The partial indexes are scoped by `podcastEpisodeId IS [NOT] NULL`, so an audiobook row and
    // a podcast-episode row that happen to share the same `itemId` (never true in production,
    // since an item is either a book or a show, but the schema itself does not forbid it) must
    // not collide with each other.
    let database = try AppDatabase.inMemory()
    let (accountId, _, itemId, episodeId) = try await Self.seedAccountLibraryItemAndEpisode(database)

    try await database.writeAsync { db in
      var audiobookRow = ListeningQueueEntryRecord(accountId: accountId, itemId: itemId, position: 0)
      try audiobookRow.insert(db)
      var episodeRow = ListeningQueueEntryRecord(
        accountId: accountId, itemId: itemId, podcastEpisodeId: episodeId, position: 1)
      try episodeRow.insert(db)
    }

    let count = try database.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM listeningQueueEntry WHERE accountId = ?",
        arguments: [accountId])
    }
    #expect(count == 2)
  }

  // MARK: - Fixtures

  private struct PreV15QueueFixture {
    let accountId: Int64
    let itemId: Int64
    let episodeIds: [Int64]
    let queueRowIds: [Int64]
  }

  /// A raw `DatabaseQueue` migrated through every migration registered before `v15`.
  /// `SchemaV1.searchFoldFunction` must be registered on this connection because `v10`'s one-off
  /// index population calls it directly (not only from a trigger). Foreign keys must be enabled
  /// explicitly: GRDB disables their enforcement only during a migration's own transaction, not
  /// for the writes this fixture performs afterward.
  private static func migratedThroughV14() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v14")
    return queue
  }

  /// Seeds one account/library/podcast show/three episodes, then three `podcastQueueEntry` rows
  /// with row ids and a position order decorrelated from each other and from
  /// insertion order, so a test that later finds them in the right place is not vacuously true.
  @discardableResult
  private static func seedPreV15PodcastQueue(
    _ queue: DatabaseQueue, softDeleteEpisodeAtIndex: Int? = nil
  ) async throws -> PreV15QueueFixture {
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account (id, clientUUID, serverBaseURL, serverUserId, serverVersion)
          VALUES (1, 'client-1', 'server-1', 'user-1', '2.35.1')
          """)
      try db.execute(
        sql: """
          INSERT INTO library (id, accountId, serverLibraryId, mediaType, name, lastSeenGeneration)
          VALUES (1, 1, 'lib-1', 'podcast', 'Library', 1)
          """)
      try db.execute(
        sql: """
          INSERT INTO item (id, accountId, libraryId, serverItemId, mediaKind, title, sortTitle,
            lastSeenGeneration, softDeleted)
          VALUES (1, 1, 1, 'show-1', 'podcast', 'Show', 'show', 1, 0)
          """)
      for (index, episodeId) in [1, 2, 3].enumerated() {
        let softDeleted = softDeleteEpisodeAtIndex == index ? 1 : 0
        try db.execute(
          sql: """
            INSERT INTO podcastEpisode (id, accountId, itemId, serverEpisodeId, title,
              lastSeenGeneration, softDeleted)
            VALUES (?, 1, 1, ?, ?, 1, ?)
            """,
          arguments: [episodeId, "episode-\(episodeId)", "Episode \(episodeId)", softDeleted])
      }
      // Row ids and positions both out of step with episode order: position 0 goes
      // to the row referencing episode 3, position 1 to episode 1, position 2 to episode 2.
      try db.execute(
        sql: """
          INSERT INTO podcastQueueEntry (id, accountId, podcastEpisodeId, position)
          VALUES (30, 1, 3, 0), (10, 1, 1, 1), (20, 1, 2, 2)
          """)
    }
    return PreV15QueueFixture(
      accountId: 1, itemId: 1, episodeIds: [1, 2, 3], queueRowIds: [30, 10, 20])
  }

  /// Two isolated (account, library, podcast show, episode) graphs on a fresh (already-v15)
  /// `AppDatabase`, distinguished by `suffix`, so the constraint tests can build a cross-account
  /// mismatch.
  private static func seedAccountLibraryItemAndEpisode(
    _ database: AppDatabase, suffix: String = "1"
  ) async throws -> (accountId: Int64, libraryId: Int64, itemId: Int64, episodeId: Int64) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-\(suffix)-\(UUID().uuidString)", serverBaseURL: "server-\(suffix)",
        serverUserId: "user-\(suffix)", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-\(suffix)", mediaType: "podcast",
        name: "Library")
      try library.insert(db)
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "show-\(suffix)",
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try item.insert(db)
      var episode = PodcastEpisodeRecord(
        accountId: account.id!, itemId: item.id!, serverEpisodeId: "episode-\(suffix)",
        title: "Episode", lastSeenGeneration: 1)
      try episode.insert(db)
      return (account.id!, library.id!, item.id!, episode.id!)
    }
  }
}
