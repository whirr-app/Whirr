import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct PodcastFeedIdentityMigrationTests {
  @Test("v57 backfills valid RSS identities, leaves invalid rows nil, and indexes both tables")
  func backfillsRSSOnlyAndCreatesExactIndexes() throws {
    let queue = try migrationQueue()
    try SchemaV1.migrator().migrate(queue, upTo: "v56")

    let feedIDs = try queue.write { db -> [Int64] in
      let values = [
        "HTTPS://EXAMPLE.COM:443/Feed/",
        "https://example.com/Feed",
        "ftp://example.com/feed",
        "https://user:password@example.com/feed",
        "",
      ]
      return try values.map { value in
        try db.execute(
          sql: "INSERT INTO rssFeed (feedURL, subscribedAt) VALUES (?, ?)",
          arguments: [value, Date()])
        return db.lastInsertedRowID
      }
    }

    try SchemaV1.migrator().migrate(queue)
    try SchemaV1.migrator().migrate(queue)

    try queue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: "SELECT id, podcastFeedFingerprint FROM rssFeed ORDER BY id")
      let expected = PodcastFeedIdentity.fingerprint("https://example.com/Feed")
      #expect(rows.map { $0["id"] as Int64 } == feedIDs)
      #expect(rows.map { $0["podcastFeedFingerprint"] as String? } == [expected, expected, nil, nil, nil])

      let rssIndex = try #require(
        db.indexes(on: "rssFeed").first { $0.name == "index_rssFeed_on_podcastFeedFingerprint" })
      #expect(rssIndex.columns == ["podcastFeedFingerprint"])
      #expect(rssIndex.isUnique == false)

      let itemIndex = try #require(
        db.indexes(on: "item").first { $0.name == "index_item_on_account_podcastFeedFingerprint" })
      #expect(itemIndex.columns == ["accountId", "podcastFeedFingerprint"])
      #expect(itemIndex.isUnique == false)
      #expect(try db.columns(in: "rssFeed").contains { $0.name == "podcastFeedFingerprint" })
      #expect(try db.columns(in: "item").contains { $0.name == "podcastFeedFingerprint" })
    }
  }

  @Test("v57 leaves existing server item identities nil because the raw URL was never stored")
  func doesNotGuessServerItemIdentity() throws {
    let queue = try migrationQueue()
    try SchemaV1.migrator().migrate(queue, upTo: "v56")
    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account (clientUUID, serverBaseURL, serverUserId, serverVersion)
          VALUES ('migration-client', 'https://server.example', 'migration-user', '2.36.0')
          """)
      let accountID = db.lastInsertedRowID
      var library = LibraryRecord(
        accountId: accountID, serverLibraryId: "podcasts", mediaType: "podcast", name: "Podcasts")
      try library.insert(db)
      try db.execute(
        sql: """
          INSERT INTO item
            (accountId, libraryId, serverItemId, mediaKind, title, sortTitle, lastSeenGeneration)
          VALUES (?, ?, ?, 'podcast', 'Show', 'show', 1)
          """,
        arguments: [accountID, library.id!, "server-show"])
    }

    try SchemaV1.migrator().migrate(queue)
    try queue.read { db in
      let fingerprint = try String.fetchOne(
        db,
        sql: "SELECT podcastFeedFingerprint FROM item WHERE serverItemId = 'server-show'")
      #expect(fingerprint == nil)
    }
  }

  private func migrationQueue() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    return try DatabaseQueue(configuration: configuration)
  }
}
