import Foundation
import GRDB
import Testing

@testable import Persistence

/// v105: v104 can be on a device from a build that still had the phone transfer an episode's file,
/// so a store may hold rows in the two states ADR 0020 retired. The enum no longer decodes them, so
/// the migration rewrites each to `wanted` and moves the generation on for the publisher.
@Suite struct RSSWatchCopyLegacyStateMigrationTests {
  @Test func legacyTransferStatesBecomeWantedAndMoveTheGenerationOn() throws {
    let queue = try storeMigratedThroughV104()
    let requestedAt = Date(timeIntervalSince1970: 1_750_000_000)

    try queue.write { db in
      try db.execute(
        sql: "INSERT INTO rssFeed (id, feedURL, subscribedAt) VALUES (1, ?, ?)",
        arguments: ["https://feeds.example.test/watch.xml", requestedAt])
      for (offset, state) in ["waitingForDownload", "delivering", "sending"].enumerated() {
        let episodeId = Int64(offset + 1)
        try db.execute(
          sql: """
            INSERT INTO rssEpisode (id, feedId, identityKey, enclosureURL, lastSeenGeneration)
            VALUES (?, 1, ?, ?, 0)
            """,
          arguments: [episodeId, "episode-\(episodeId)", "https://cdn.example.test/1.mp3"])
        try db.execute(
          sql: """
            INSERT INTO rssWatchCopy
              (episodeId, revision, state, sourceBytes, requestedAt, updatedAt)
            VALUES (?, 1, ?, 4242, ?, ?)
            """,
          arguments: [episodeId, state, requestedAt, requestedAt])
      }
      try db.execute(
        sql: "UPDATE rssWatchCopySet SET generation = 5, acknowledgedGeneration = 5")
    }

    try SchemaV1.migrator().migrate(queue)

    try queue.read { db in
      let copies = try RSSWatchCopy.fetchAll(db).sorted { $0.episodeId < $1.episodeId }
      #expect(copies.map(\.state) == [.wanted, .wanted, .sending])
      #expect(copies.prefix(2).allSatisfy { $0.sourceBytes == nil })

      let set = try #require(
        try RSSWatchCopySetRecord.fetchOne(db, key: RSSWatchCopySetRecord.singletonID))
      #expect(set.generation == 6)
      #expect(set.acknowledgedGeneration == 5)
    }
  }

  @Test func aStoreWithNoLegacyRowsKeepsItsGeneration() throws {
    let queue = try storeMigratedThroughV104()
    try queue.write { db in
      try db.execute(sql: "UPDATE rssWatchCopySet SET generation = 5")
    }

    try SchemaV1.migrator().migrate(queue)

    try queue.read { db in
      let set = try #require(
        try RSSWatchCopySetRecord.fetchOne(db, key: RSSWatchCopySetRecord.singletonID))
      #expect(set.generation == 5)
    }
  }

  /// The v104 store as it exists on a device: migrated through the frozen table creation, with no
  /// later migration applied yet.
  private func storeMigratedThroughV104() throws -> DatabaseQueue {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v104")
    return queue
  }
}
