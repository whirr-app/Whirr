import Foundation
import GRDB
import Testing

@testable import Persistence

/// `v83`: the episode index indexed each description's HTML, so an
/// index built before the migration answers `href`. The migration swaps the triggers and rebuilds
/// the index from the descriptions' plain text, on a store that already holds episodes.
@Suite struct EpisodeSearchIndexMigrationTests {
  private static let description =
    "<p>Interview with <a href=\"https://linkhost.example/div\">Mara Quill</a> &amp; friends.</p>"

  private static func queue() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    return try DatabaseQueue(configuration: configuration)
  }

  private static func seedEpisode(_ db: Database) throws -> Int64 {
    // Raw SQL: the seed runs against schemas migrated part way, before later account columns.
    try db.execute(
      sql: """
        INSERT INTO account (clientUUID, serverBaseURL, serverUserId, serverVersion)
        VALUES (?, 'https://example.com', 'user-1', '2.35.1')
        """,
      arguments: [UUID().uuidString])
    let accountId = db.lastInsertedRowID
    var library = LibraryRecord(
      accountId: accountId, serverLibraryId: "lib-1", mediaType: "podcast", name: "Podcasts")
    try library.insert(db)
    var show = ItemRecord(
      accountId: accountId, libraryId: library.id!, serverItemId: "show-1", mediaKind: "podcast",
      title: "A Show", sortTitle: "a show")
    try show.insert(db)
    var episode = PodcastEpisodeRecord(
      accountId: accountId, itemId: show.id!, serverEpisodeId: "ep-1", title: "Unrelated",
      episodeDescription: description, lastSeenGeneration: 1)
    try episode.insert(db)
    return episode.id!
  }

  /// Rows the FTS index itself answers for `term`, read outside any `#expect` so the throwing
  /// read is not folded into the macro's expression.
  private static func indexedRowIDs(_ queue: DatabaseQueue, matching term: String) throws -> [Int64] {
    try queue.read { db in
      try Int64.fetchAll(
        db, sql: "SELECT rowid FROM episodeSearch WHERE episodeSearch MATCH ?", arguments: [term])
    }
  }

  @Test func v83RebuildsAnIndexThatHeldMarkupAsPlainText() throws {
    let queue = try Self.queue()
    try SchemaV1.migrator().migrate(queue, upTo: "v82")
    let episodeId = try queue.write { db in try Self.seedEpisode(db) }

    // The pre-v83 triggers indexed the markup: this is the defect, pinned so the rebuild below
    // demonstrably changes something.
    #expect(try Self.indexedRowIDs(queue, matching: "href") == [episodeId])

    try SchemaV1.migrator().migrate(queue)

    #expect(try Self.indexedRowIDs(queue, matching: "href").isEmpty)
    #expect(try Self.indexedRowIDs(queue, matching: "linkhost").isEmpty)
    #expect(try Self.indexedRowIDs(queue, matching: "quill") == [episodeId])
    #expect(try Self.indexedRowIDs(queue, matching: "friends") == [episodeId])
  }

  /// The delete and update triggers must fold the same text the insert folded, or the
  /// external-content `'delete'` command fails as index corruption. Updating and then deleting
  /// after the rebuild must succeed and leave the index answering only what remains.
  @Test func v83TriggersKeepTheIndexConsistentThroughUpdateAndDelete() throws {
    let queue = try Self.queue()
    try SchemaV1.migrator().migrate(queue)
    let episodeId = try queue.write { db in try Self.seedEpisode(db) }

    try queue.write { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET episodeDescription = ? WHERE id = ?",
        arguments: ["<p>New guest: <em>Ola Vance</em></p>", episodeId])
    }
    #expect(try Self.indexedRowIDs(queue, matching: "vance") == [episodeId])
    #expect(try Self.indexedRowIDs(queue, matching: "quill").isEmpty)
    #expect(try Self.indexedRowIDs(queue, matching: "em").isEmpty)

    try queue.write { db in
      try db.execute(sql: "DELETE FROM podcastEpisode WHERE id = ?", arguments: [episodeId])
    }
    #expect(try Self.indexedRowIDs(queue, matching: "vance").isEmpty)
  }
}
