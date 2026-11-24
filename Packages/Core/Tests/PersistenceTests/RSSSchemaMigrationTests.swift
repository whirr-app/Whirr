import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct RSSSchemaMigrationTests {

  @Test func existingV49FeedsMigrateThroughV51WithoutInventingRecovery() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v49")
    let feedID = try queue.write { db in try insertFeed(db, url: "https://existing.example/feed") }

    try SchemaV1.migrator().migrate(queue)

    let migrated = try queue.read { db in
      (
        migratedToHead: try SchemaV1.migrator().hasCompletedMigrations(db),
        hasRecoveryTable: try db.tableExists("rssFeedRecovery"),
        feedCount: try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM rssFeed WHERE id = ?", arguments: [feedID]),
        recoveryCount: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssFeedRecovery")
      )
    }
    // Asked as a question rather than pinned to an identifier: this test is about the tables
    // the RSS migrations create, and naming the newest migration would make every unrelated
    // migration that lands later fail it.
    #expect(migrated.migratedToHead)
    #expect(migrated.hasRecoveryTable)
    #expect(migrated.feedCount == 1)
    #expect(migrated.recoveryCount == 0)
  }

  @Test("v55 adds a null synopsis line to existing episodes and keeps their descriptions")
  func existingV54EpisodesMigrateThroughV55WithANullSynopsisLine() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v54")
    let episodeID = try queue.write { db -> Int64 in
      let feedID = try insertFeed(db, url: "https://existing.example/feed")
      try db.execute(
        sql: """
          INSERT INTO rssEpisode (feedId, identityKey, synopsis, enclosureURL, lastSeenGeneration)
          VALUES (?, 'guid:one', '<p>Kept &amp; whole</p>', 'https://existing.example/one.mp3', 1)
          """,
        arguments: [feedID])
      return db.lastInsertedRowID
    }

    try SchemaV1.migrator().migrate(queue)

    let migrated = try #require(
      try queue.read { db in
        try Row.fetchOne(
          db, sql: "SELECT synopsis, synopsisLine FROM rssEpisode WHERE id = ?",
          arguments: [episodeID])
      })
    #expect(migrated["synopsis"] as String? == "<p>Kept &amp; whole</p>")
    #expect(migrated["synopsisLine"] as String? == nil)
  }

  @Test("v62 adds RSS auto-download decisions and backfills automatic rows")
  func v62BackfillsAutomaticDownloadDecisions() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v61")

    let automaticStamp = Date(timeIntervalSince1970: 1_700_000_123)
    let ids = try queue.write { db -> (Int64, Int64) in
      let feedID = try insertFeed(db, url: "https://existing.example/auto-download-feed")
      let automaticEpisodeID = try insertEpisode(
        db, feedID: feedID, identityKey: "guid:automatic")
      let manualEpisodeID = try insertEpisode(db, feedID: feedID, identityKey: "guid:manual")
      try db.execute(
        sql: """
          INSERT INTO rssDownload
            (episodeId, state, relativePath, origin, decidedStamp, createdAt, updatedAt)
          VALUES (?, 'pending', 'RSS/automatic.mp3', 'automatic', ?, ?, ?),
                 (?, 'pending', 'RSS/manual.mp3', 'manual', ?, ?, ?)
          """,
        arguments: [
          automaticEpisodeID, automaticStamp, automaticStamp, automaticStamp,
          manualEpisodeID, automaticStamp, automaticStamp, automaticStamp,
        ])
      return (automaticEpisodeID, manualEpisodeID)
    }

    try SchemaV1.migrator().migrate(queue)

    try queue.read { db in
      let column = try #require(
        db.columns(in: "rssEpisode").first { $0.name == "autoDownloadDecidedAt" })
      #expect(column.type == "DATETIME")
      #expect(column.isNotNull == false)
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT id, autoDownloadDecidedAt FROM rssEpisode WHERE id IN (?, ?) ORDER BY id",
        arguments: [ids.0, ids.1])
      #expect(rows[0]["autoDownloadDecidedAt"] as Date? == automaticStamp)
      #expect(rows[1]["autoDownloadDecidedAt"] as Date? == nil)
    }
  }

  @Test func existingV47SettingsMigrateThroughV48WithoutLosingTheirValues() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v47")

    let feedID = try queue.write { db in
      #expect(try db.tableExists("rssNotificationFeedBaseline") == false)
      #expect(try db.tableExists("rssEpisodeNotificationLedger") == false)
      #expect(try db.columns(in: "rssFeedSettings").contains { $0.name == "notificationOverride" } == false)
      let feedID = try insertFeed(db, url: "https://existing.example/feed")
      try db.execute(
        sql: """
          INSERT INTO rssFeedSettings
            (feedId, autoDownload, keepLatest, deleteAfterPlayed, rateStep, includeInLatest)
          VALUES (?, 'enabled', 10, 1, 30, 0)
          """,
        arguments: [feedID])
      return feedID
    }

    try SchemaV1.migrator().migrate(queue)

    try queue.write { db in
      #expect(try SchemaV1.migrator().hasCompletedMigrations(db))
      #expect(try db.tableExists("rssNotificationFeedBaseline"))
      #expect(try db.tableExists("rssEpisodeNotificationLedger"))
      let settings = try #require(
        try Row.fetchOne(db, sql: "SELECT * FROM rssFeedSettings WHERE feedId = ?", arguments: [feedID]))
      #expect((settings["autoDownload"] as String) == "enabled")
      #expect((settings["keepLatest"] as Int) == 10)
      #expect((settings["deleteAfterPlayed"] as Bool) == true)
      #expect((settings["rateStep"] as Int) == 30)
      #expect((settings["includeInLatest"] as Bool) == false)
      #expect((settings["notificationOverride"] as String) == "inherit")

      let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
      try db.execute(
        sql: "INSERT INTO rssNotificationFeedBaseline (feedId, establishedAt) VALUES (?, ?)",
        arguments: [feedID, timestamp])
      try db.execute(
        sql: """
          INSERT INTO rssEpisodeNotificationLedger
            (feedId, identityKey, disposition, firstSeenAt)
          VALUES (?, 'guid:existing', 'pending', ?)
          """,
        arguments: [feedID, timestamp])
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssNotificationFeedBaseline") == 1)
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssEpisodeNotificationLedger") == 1)
    }
  }

  @Test func allRSSPersistenceTablesExist() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      for table in [
        "rssFeed", "rssEpisode", "rssEpisodeState", "rssFeedSettings", "rssDownload",
        "rssShowOrder", "rssPlaybackBookmark", "rssNotificationFeedBaseline",
        "rssEpisodeNotificationLedger",
        "rssFeedRecovery", "rssListeningQueueEntry", "rssSavedShelfEntry",
        "nativePodcastSettings", "nativeListeningQueueRevision", "rssWatchCopy",
        "rssWatchCopySet",
      ] {
        let exists = try db.tableExists(table)
        #expect(exists)
      }
    }
  }

  @Test func notificationLedgerHasNoEpisodeForeignKey() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let foreignKeys = try Row.fetchAll(
        db, sql: "PRAGMA foreign_key_list(rssEpisodeNotificationLedger)")
      #expect(foreignKeys.count == 1)
      #expect((foreignKeys[0]["table"] as String) == "rssFeed")
      #expect((foreignKeys[0]["on_delete"] as String).uppercased() == "CASCADE")
      #expect(try db.primaryKey("rssEpisodeNotificationLedger").columns == ["feedId", "identityKey"])
    }
  }

  @Test func measuredDurationColumnIsNullable() throws {
    let database = try AppDatabase.inMemory()
    try database.read { db in
      let column = try #require(
        db.columns(in: "rssEpisode").first { $0.name == "measuredDurationSeconds" })
      #expect(column.type == "DOUBLE")
      #expect(column.isNotNull == false)
    }
  }

  @Test func episodeIdentityIsUniquePerFeed() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      let feed1 = try insertFeed(db, url: "https://one.example/feed")
      let feed2 = try insertFeed(db, url: "https://two.example/feed")
      _ = try insertEpisode(db, feedID: feed1, identityKey: "guid:one")
      _ = try insertEpisode(db, feedID: feed2, identityKey: "guid:one")
      #expect(throws: DatabaseError.self) {
        try insertEpisode(db, feedID: feed1, identityKey: "guid:one")
      }
    }
  }

  @Test func feedURLIsUnique() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      let arguments: StatementArguments = ["https://example.com/feed", Date()]
      try db.execute(sql: "INSERT INTO rssFeed (feedURL, subscribedAt) VALUES (?, ?)", arguments: arguments)
      #expect(throws: DatabaseError.self) {
        try db.execute(sql: "INSERT INTO rssFeed (feedURL, subscribedAt) VALUES (?, ?)", arguments: arguments)
      }
    }
  }

  @Test func deletingFeedCascadesRSSRows() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      let feedID = try insertFeed(db, url: "https://example.com/feed")
      let episodeID = try insertEpisode(db, feedID: feedID, identityKey: "guid:one")
      try db.execute(
        sql: "INSERT INTO rssEpisodeState (episodeId, position, localSequence, updatedAt) VALUES (?, ?, ?, ?)",
        arguments: [episodeID, 1.0, 1, Date()])
      try db.execute(sql: "INSERT INTO rssFeedSettings (feedId) VALUES (?)", arguments: [feedID])
      try insertDownload(db, episodeID: episodeID)
      try db.execute(sql: "DELETE FROM rssFeed WHERE id = ?", arguments: [feedID])
      for table in [
        "rssFeed", "rssEpisode", "rssEpisodeState", "rssFeedSettings", "rssDownload",
        "rssNotificationFeedBaseline", "rssEpisodeNotificationLedger",
        "rssFeedRecovery", "rssListeningQueueEntry", "rssSavedShelfEntry",
      ] {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0)
      }
    }
  }

  @Test func rssChecksAcceptOnlyDeclaredValues() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      let feedID = try insertFeed(db, url: "https://example.com/feed")
      let otherFeedID = try insertFeed(db, url: "https://example.com/other")
      let episodeID = try insertEpisode(db, feedID: feedID, identityKey: "guid:one")
      let secondEpisodeID = try insertEpisode(db, feedID: feedID, identityKey: "guid:two")
      let thirdEpisodeID = try insertEpisode(db, feedID: feedID, identityKey: "guid:three")
      try db.execute(
        sql: "INSERT INTO rssFeedSettings (feedId, autoDownload) VALUES (?, ?)", arguments: [feedID, "enabled"])
      try insertDownload(db, episodeID: episodeID, state: "completed", origin: "automatic")
      // Rejected rows target rows that exist so the CHECK constraint is the only possible failure.
      #expect(throws: DatabaseError.self) {
        try db.execute(
          sql: "INSERT INTO rssFeedSettings (feedId, autoDownload) VALUES (?, ?)",
          arguments: [otherFeedID, "sometimes"])
      }
      #expect(throws: DatabaseError.self) { try insertDownload(db, episodeID: secondEpisodeID, state: "unknown") }
      #expect(throws: DatabaseError.self) { try insertDownload(db, episodeID: thirdEpisodeID, origin: "system") }
    }
  }

  @Test func episodeHasAtMostOneDownload() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      let feedID = try insertFeed(db, url: "https://example.com/feed")
      let episodeID = try insertEpisode(db, feedID: feedID, identityKey: "guid:one")
      try insertDownload(db, episodeID: episodeID)
      #expect(throws: DatabaseError.self) { try insertDownload(db, episodeID: episodeID) }
    }
  }

  @Test func rssTablesAreNotAccountOwned() throws {
    let database = try AppDatabase.inMemory()
    let owned = try AccountRemover(database: database).accountOwnedTables()
    for table in [
      "rssFeed", "rssEpisode", "rssEpisodeState", "rssFeedSettings", "rssDownload", "rssShowOrder",
      "rssPlaybackBookmark", "rssNotificationFeedBaseline", "rssEpisodeNotificationLedger",
      "rssFeedRecovery", "rssWatchCopy", "rssWatchCopySet",
    ] {
      #expect(!owned.contains(table))
    }
  }

  @Test func nativeShowOrderIsASingleDeviceOwnedRow() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      try db.execute(sql: "INSERT INTO rssShowOrder (id, mode) VALUES (0, 'custom')")
      #expect(throws: DatabaseError.self) {
        try db.execute(sql: "INSERT INTO rssShowOrder (id, mode) VALUES (1, 'alphabetical')")
      }
      #expect(throws: DatabaseError.self) {
        try db.execute(sql: "INSERT INTO rssShowOrder (id, mode) VALUES (0, 'mostRecent')")
      }
    }
  }

  /// The dismissal flag is additive, and an existing listening position predates it. Migrating a
  /// store that already has playback state must leave that state on the shelf, not off it.
  @Test func v54AddsTheDismissalFlagWithExistingProgressStillVisible() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v53")

    let episodeID = try queue.write { db -> Int64 in
      #expect(
        try db.columns(in: "rssEpisodeState")
          .contains { $0.name == "hideFromContinueListening" } == false)
      let feedID = try insertFeed(db, url: "https://existing.example/feed")
      let episodeID = try insertEpisode(db, feedID: feedID, identityKey: "guid:episode")
      try db.execute(
        sql: """
          INSERT INTO rssEpisodeState (episodeId, position, finished, localSequence, updatedAt)
          VALUES (?, ?, 0, 1, ?)
          """,
        arguments: [episodeID, 123.5, Date(timeIntervalSince1970: 100)])
      return episodeID
    }

    try SchemaV1.migrator().migrate(queue)

    try queue.read { db in
      let row = try #require(
        try Row.fetchOne(
          db, sql: "SELECT * FROM rssEpisodeState WHERE episodeId = ?", arguments: [episodeID]))
      #expect(row["position"] as Double? == 123.5)
      #expect(row["hideFromContinueListening"] as Bool? == false)
    }
  }

  /// v103: episodes gain their own artwork URL (null until a refresh), and every followed feed's
  /// validators are cleared so its next refresh is a full fetch that backfills it.
  @Test("v103 adds a null episode artwork URL and clears feed validators")
  func v103ClearsFeedValidatorsAndAddsEpisodeArtwork() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v102")
    let (feedID, episodeID) = try queue.write { db -> (Int64, Int64) in
      let feedID = try insertFeed(db, url: "https://existing.example/feed")
      try db.execute(
        sql: "UPDATE rssFeed SET etag = ?, lastModified = ? WHERE id = ?",
        arguments: ["\"etag-v103\"", "Mon, 01 Jun 2026 00:00:00 GMT", feedID])
      let episodeID = try insertEpisode(db, feedID: feedID, identityKey: "guid:one")
      return (feedID, episodeID)
    }

    try SchemaV1.migrator().migrate(queue)

    let migrated = try queue.read { db in
      (
        episode: try Row.fetchOne(
          db, sql: "SELECT artworkURL FROM rssEpisode WHERE id = ?", arguments: [episodeID]),
        feed: try Row.fetchOne(
          db, sql: "SELECT etag, lastModified FROM rssFeed WHERE id = ?", arguments: [feedID])
      )
    }
    let episode = try #require(migrated.episode)
    let feed = try #require(migrated.feed)
    #expect(episode["artworkURL"] as String? == nil)
    #expect(feed["etag"] as String? == nil)
    #expect(feed["lastModified"] as String? == nil)
  }

  private func insertEpisode(_ db: Database, feedID: Int64, identityKey: String) throws -> Int64 {
    try db.execute(
      sql: "INSERT INTO rssEpisode (feedId, identityKey, enclosureURL, lastSeenGeneration) VALUES (?, ?, ?, ?)",
      arguments: [feedID, identityKey, "https://example.com/audio.mp3", 1])
    return db.lastInsertedRowID
  }

  private func insertFeed(_ db: Database, url: String) throws -> Int64 {
    try db.execute(
      sql: "INSERT INTO rssFeed (feedURL, subscribedAt) VALUES (?, ?)",
      arguments: [url, Date()])
    return db.lastInsertedRowID
  }

  private func insertDownload(_ db: Database, episodeID: Int64, state: String = "pending", origin: String = "manual")
    throws
  {
    try db.execute(
      sql:
        "INSERT INTO rssDownload (episodeId, state, relativePath, origin, decidedStamp, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)",
      arguments: [episodeID, state, "RSS/file.mp3", origin, Date(), Date(), Date()])
  }
}
