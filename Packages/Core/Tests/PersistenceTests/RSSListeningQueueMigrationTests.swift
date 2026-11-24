import Foundation
import GRDB
import Testing

@testable import Persistence

/// v47 rebuilds the released ABS-only queue table for a third RSS identity without
/// losing an existing row, weakening account ownership, or accepting an ambiguous source shape.
@Suite struct RSSListeningQueueMigrationTests {
  @Test("v47 preserves every existing row id, identity, position, and account")
  func populatedQueueMigratesWithoutLoss() async throws {
    let queue = try Self.migratedThroughV46()
    let fixture = try await Self.seedPreV47Queue(queue)

    try SchemaV1.migrator().migrate(queue, upTo: "v47")

    try await queue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, accountId, itemId, podcastEpisodeId, rssEpisodeId, position
          FROM listeningQueueEntry
          ORDER BY position
          """)
      #expect(rows.count == 2)
      #expect(rows[0]["id"] as Int64 == fixture.bookQueueRowID)
      #expect(rows[0]["accountId"] as Int64 == fixture.accountID)
      #expect(rows[0]["itemId"] as Int64 == fixture.bookItemRowID)
      #expect(rows[0]["podcastEpisodeId"] as Int64? == nil)
      #expect(rows[0]["rssEpisodeId"] as Int64? == nil)
      #expect(rows[0]["position"] as Int == 0)
      #expect(rows[1]["id"] as Int64 == fixture.episodeQueueRowID)
      #expect(rows[1]["itemId"] as Int64 == fixture.showItemRowID)
      #expect(rows[1]["podcastEpisodeId"] as Int64 == fixture.absEpisodeRowID)
      #expect(rows[1]["rssEpisodeId"] as Int64? == nil)
      #expect(rows[1]["position"] as Int == 1)
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
  }

  @Test(
    "an injected failure at any rebuild checkpoint restores the complete v46 table",
    arguments: [
      SchemaV1.RSSListeningQueueMigrationCheckpoint.afterCopy,
      SchemaV1.RSSListeningQueueMigrationCheckpoint.afterDrop,
      SchemaV1.RSSListeningQueueMigrationCheckpoint.afterSwap,
    ])
  func injectedFailureRollsBack(
    checkpointToFail: SchemaV1.RSSListeningQueueMigrationCheckpoint
  ) async throws {
    struct InjectedFailure: Error {}
    let queue = try Self.migratedThroughV46()
    let fixture = try await Self.seedPreV47Queue(queue)

    #expect(throws: InjectedFailure.self) {
      try SchemaV1.migrator(
        rssListeningQueueMigrationCheckpoint: { checkpoint in
          if checkpoint == checkpointToFail { throw InjectedFailure() }
        }
      ).migrate(queue)
    }

    try await queue.read { db in
      #expect(
        Set(try db.columns(in: "listeningQueueEntry").map(\.name))
          == ["id", "accountId", "itemId", "podcastEpisodeId", "position"])
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, itemId, podcastEpisodeId, position
          FROM listeningQueueEntry
          ORDER BY position
          """)
      #expect(rows.count == 2)
      #expect(rows[0]["id"] as Int64 == fixture.bookQueueRowID)
      #expect(rows[1]["id"] as Int64 == fixture.episodeQueueRowID)
      #expect(try db.tableExists("listeningQueueEntry_v47") == false)
    }
  }

  @Test("the rebuilt table enforces all three identity shapes and their partial uniqueness")
  func rebuiltConstraintsRejectAmbiguityAndDuplicates() async throws {
    let queue = try Self.migratedThroughV46()
    let fixture = try await Self.seedPreV47Queue(queue)
    try SchemaV1.migrator().migrate(queue, upTo: "v47")

    try await queue.write { db in
      let rssEpisodeRowID = try Self.insertRSSEpisode(db)
      try db.execute(
        sql: """
          INSERT INTO listeningQueueEntry
            (accountId, itemId, podcastEpisodeId, rssEpisodeId, position)
          VALUES (?, NULL, NULL, ?, 2)
          """,
        arguments: [fixture.accountID, rssEpisodeRowID])

      #expect(throws: DatabaseError.self) {
        try db.execute(
          sql: """
            INSERT INTO listeningQueueEntry
              (accountId, itemId, podcastEpisodeId, rssEpisodeId, position)
            VALUES (?, NULL, NULL, NULL, 3)
            """,
          arguments: [fixture.accountID])
      }
      #expect(throws: DatabaseError.self) {
        try db.execute(
          sql: """
            INSERT INTO listeningQueueEntry
              (accountId, itemId, podcastEpisodeId, rssEpisodeId, position)
            VALUES (?, ?, NULL, ?, 3)
            """,
          arguments: [fixture.accountID, fixture.bookItemRowID, rssEpisodeRowID])
      }
      #expect(throws: DatabaseError.self) {
        try db.execute(
          sql: """
            INSERT INTO listeningQueueEntry
              (accountId, itemId, podcastEpisodeId, rssEpisodeId, position)
            VALUES (?, NULL, ?, NULL, 3)
            """,
          arguments: [fixture.accountID, fixture.absEpisodeRowID])
      }
      #expect(throws: DatabaseError.self) {
        try db.execute(
          sql: """
            INSERT INTO listeningQueueEntry
              (accountId, itemId, podcastEpisodeId, rssEpisodeId, position)
            VALUES (?, NULL, NULL, ?, 3)
            """,
          arguments: [fixture.accountID, rssEpisodeRowID])
      }
    }
  }

  @Test("account deletion clears an RSS queue row but leaves its device-owned episode")
  func accountCascadeClearsRSSQueueOnly() async throws {
    let queue = try Self.migratedThroughV46()
    let fixture = try await Self.seedPreV47Queue(queue)
    try SchemaV1.migrator().migrate(queue, upTo: "v47")

    let rssEpisodeRowID = try await queue.write { db in
      let rowID = try Self.insertRSSEpisode(db)
      try db.execute(
        sql: """
          INSERT INTO listeningQueueEntry
            (accountId, itemId, podcastEpisodeId, rssEpisodeId, position)
          VALUES (?, NULL, NULL, ?, 2)
          """,
        arguments: [fixture.accountID, rowID])
      try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [fixture.accountID])
      return rowID
    }

    try await queue.read { db in
      let queueCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningQueueEntry")
      let episodeCount = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM rssEpisode WHERE id = ?",
        arguments: [rssEpisodeRowID])
      #expect(queueCount == 0)
      #expect(episodeCount == 1)
    }
  }

  private struct Fixture {
    let accountID: Int64
    let bookItemRowID: Int64
    let showItemRowID: Int64
    let absEpisodeRowID: Int64
    let bookQueueRowID: Int64
    let episodeQueueRowID: Int64
  }

  private static func migratedThroughV46() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v46")
    return queue
  }

  private static func seedPreV47Queue(_ queue: DatabaseQueue) async throws -> Fixture {
    try await queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account (id, clientUUID, serverBaseURL, serverUserId, serverVersion)
          VALUES (1, 'client', 'https://abs.example', 'user', '2.35.1')
          """)
      try db.execute(
        sql: """
          INSERT INTO library
            (id, accountId, serverLibraryId, mediaType, name, lastSeenGeneration)
          VALUES (1, 1, 'library', 'book', 'Library', 1)
          """)
      try db.execute(
        sql: """
          INSERT INTO item
            (id, accountId, libraryId, serverItemId, mediaKind, title, sortTitle,
             numAudioFiles, lastSeenGeneration, softDeleted)
          VALUES
            (1, 1, 1, 'book', 'book', 'Book', 'book', 1, 1, 0),
            (2, 1, 1, 'show', 'podcast', 'Show', 'show', 0, 1, 0)
          """)
      try db.execute(
        sql: """
          INSERT INTO podcastEpisode
            (id, accountId, itemId, serverEpisodeId, title, lastSeenGeneration, softDeleted)
          VALUES (1, 1, 2, 'episode', 'Episode', 1, 0)
          """)
      try db.execute(
        sql: """
          INSERT INTO listeningQueueEntry
            (id, accountId, itemId, podcastEpisodeId, position)
          VALUES (20, 1, 1, NULL, 0), (10, 1, 2, 1, 1)
          """)
      return Fixture(
        accountID: 1, bookItemRowID: 1, showItemRowID: 2, absEpisodeRowID: 1,
        bookQueueRowID: 20, episodeQueueRowID: 10)
    }
  }

  private static func insertRSSEpisode(_ db: Database) throws -> Int64 {
    try db.execute(
      sql: """
        INSERT INTO rssFeed (feedURL, title, subscribedAt, refreshGeneration)
        VALUES ('https://rss.example/feed.xml', 'Native Show', ?, 1)
        """,
      arguments: [Date(timeIntervalSince1970: 1_700_000_000)])
    let feedID = db.lastInsertedRowID
    try db.execute(
      sql: """
        INSERT INTO rssEpisode
          (feedId, identityKey, title, enclosureURL, lastSeenGeneration)
        VALUES (?, 'native-episode', 'Native Episode', 'https://rss.example/episode.mp3', 1)
        """,
      arguments: [feedID])
    return db.lastInsertedRowID
  }
}
