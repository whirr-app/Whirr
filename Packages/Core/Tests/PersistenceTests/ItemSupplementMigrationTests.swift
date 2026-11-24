import Foundation
import GRDB
import Testing

@testable import Persistence

/// v76 adds the supplement set, but a book whose expanded metadata was fetched earlier is served
/// from that stored copy and would never gain its set. v77 clears the coverage marker on books
/// with audio so the ordinary backfill fetches them once. It starts from v76 because a
/// pre-release build may already have run that step.
@Suite struct ItemSupplementMigrationTests {
  @Test func v77SendsEveryFetchedAudiobookBackThroughTheBackfill() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v76")
    let fetchedAt = Date(timeIntervalSince1970: 1_750_000_000)

    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO account (id, clientUUID, serverBaseURL, serverUserId, serverVersion)
          VALUES (1, 'client', 'https://example.com', 'user', '2.35.1')
          """)
      try db.execute(
        sql: "INSERT INTO library (id, accountId, serverLibraryId, mediaType, name) VALUES (1, 1, 'lib', 'book', 'L')")
      let rows: [(String, String, Int?, Bool)] = [
        ("audiobook", "book", 12, false),
        ("unknown-audio", "book", nil, false),
        ("ebook-only", "book", 0, false),
        ("podcast", "podcast", nil, false),
        ("deleted", "book", 3, true),
      ]
      for (id, kind, audioFiles, deleted) in rows {
        try db.execute(
          sql: """
            INSERT INTO item (accountId, libraryId, serverItemId, mediaKind, title, sortTitle,
              numAudioFiles, softDeleted, expandedMetadataFetchedAt)
            VALUES (1, 1, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [id, kind, id, id, audioFiles, deleted, fetchedAt])
      }
    }

    try SchemaV1.migrator().migrate(queue)

    let markers = try queue.read { db in
      try Dictionary(
        uniqueKeysWithValues: Row.fetchAll(
          db, sql: "SELECT serverItemId, expandedMetadataFetchedAt FROM item"
        ).map { ($0["serverItemId"] as String, $0["expandedMetadataFetchedAt"] as Date?) })
    }
    #expect(markers["audiobook"] == .some(nil))
    #expect(markers["unknown-audio"] == .some(nil))
    #expect(markers["ebook-only"] == fetchedAt)
    #expect(markers["podcast"] == fetchedAt)
    #expect(markers["deleted"] == fetchedAt)
  }
}
