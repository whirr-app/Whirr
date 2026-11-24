import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct NativeSavedShelfMigrationTests {
  @Test("v60 splits RSS saves and preserves identity, metadata, and timestamps")
  func populatedSplitPreservesRows() throws {
    let db = try Self.seededDatabase()
    try SchemaV1.migrator().migrate(db)
    try db.read { db throws -> Void in
      let abs = try Row.fetchOne(db, sql: "SELECT id, itemId, subjectTitle FROM savedShelfEntry")!
      #expect(abs["id"] as Int64 == 20)
      #expect(abs["itemId"] as Int64 == 1)
      #expect(abs["subjectTitle"] as String == "Book")
      let rss = try Row.fetchOne(
        db, sql: "SELECT id, rssEpisodeId, savedAt, subjectTitle, contextTitle FROM rssSavedShelfEntry")!
      #expect(rss["id"] as Int64 == 10)
      #expect(rss["rssEpisodeId"] as Int64 == 1)
      #expect(rss["savedAt"] as Date == Date(timeIntervalSince1970: 1_700_000_001))
      #expect(rss["subjectTitle"] as String == "Episode")
      #expect(rss["contextTitle"] as String == "Show")
      #expect(try db.columns(in: "savedShelfEntry").map(\.name).contains("rssEpisodeId") == false)
    }
  }

  @Test(
    "v60 rebuild checkpoints roll back the original populated table",
    arguments: [
      SchemaV1.RSSSavedShelfMigrationCheckpoint.afterCopy,
      SchemaV1.RSSSavedShelfMigrationCheckpoint.afterDrop,
      SchemaV1.RSSSavedShelfMigrationCheckpoint.afterSwap,
    ])
  func checkpointRollback(_ failure: SchemaV1.RSSSavedShelfMigrationCheckpoint) throws {
    struct Failure: Error {}
    let db = try Self.seededDatabase()
    #expect(throws: Failure.self) {
      try SchemaV1.migrator(rssSavedShelfMigrationCheckpoint: { point in
        if point == failure { throw Failure() }
      }).migrate(db)
    }
    try db.read { db throws -> Void in
      #expect((try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM savedShelfEntry")) == 2)
      #expect(try db.tableExists("rssSavedShelfEntry") == false)
      #expect(try db.tableExists("savedShelfEntry_v60") == false)
    }
  }

  static func seededDatabase() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let db = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(db, upTo: "v57")
    try db.write { db in
      try db.execute(
        sql:
          "INSERT INTO account (id, clientUUID, serverBaseURL, serverUserId, serverVersion) VALUES (1, 'client', 'https://abs.example', 'user', '2.0')"
      )
      try db.execute(
        sql:
          "INSERT INTO library (id, accountId, serverLibraryId, mediaType, name, lastSeenGeneration) VALUES (1, 1, 'lib', 'book', 'Library', 1)"
      )
      try db.execute(
        sql:
          "INSERT INTO item (id, accountId, libraryId, serverItemId, mediaKind, title, sortTitle, numAudioFiles, lastSeenGeneration, softDeleted) VALUES (1, 1, 1, 'book', 'book', 'Book', 'Book', 1, 1, 0), (2, 1, 1, 'show', 'podcast', 'Show', 'Show', 0, 1, 0)"
      )
      try db.execute(
        sql:
          "INSERT INTO podcastEpisode (id, accountId, itemId, serverEpisodeId, title, lastSeenGeneration, softDeleted) VALUES (1, 1, 2, 'episode', 'Episode', 1, 0)"
      )
      try db.execute(
        sql:
          "INSERT INTO rssFeed (id, feedURL, title, subscribedAt, refreshGeneration) VALUES (1, 'https://rss.example/feed.xml', 'Show', ?, 1)",
        arguments: [Date(timeIntervalSince1970: 1_700_000_000)])
      try db.execute(
        sql:
          "INSERT INTO rssEpisode (id, feedId, identityKey, title, enclosureURL, lastSeenGeneration) VALUES (1, 1, 'native', 'Episode', 'https://rss.example/e.mp3', 1)"
      )
      try db.execute(
        sql: "INSERT INTO savedShelfEntry (id, accountId, itemId, savedAt, subjectTitle) VALUES (20, 1, 1, ?, 'Book')",
        arguments: [Date(timeIntervalSince1970: 1_700_000_000)])
      try db.execute(
        sql:
          "INSERT INTO savedShelfEntry (id, accountId, rssEpisodeId, savedAt, subjectTitle, contextTitle) VALUES (10, 1, 1, ?, 'Episode', 'Show')",
        arguments: [Date(timeIntervalSince1970: 1_700_000_001)])
    }
    return db
  }
}
