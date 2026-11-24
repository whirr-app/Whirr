import Foundation
import GRDB
import Testing

@testable import Persistence

/// v78 adds the attempt stamp that orders refresh candidates. Seeding it from the last success
/// keeps the first pass after upgrade in the pre-upgrade order; a feed that has never refreshed
/// stays unstamped and goes first.
@Suite struct RSSRefreshAttemptMigrationTests {
  @Test func v78SeedsTheAttemptStampFromTheLastSuccess() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v77")
    let subscribedAt = Date(timeIntervalSince1970: 1_750_000_000)
    let refreshedAt = subscribedAt.addingTimeInterval(3600)

    try queue.write { db in
      try db.execute(
        sql: """
          INSERT INTO rssFeed (id, feedURL, subscribedAt, lastRefreshedAt)
          VALUES (1, 'https://example.test/refreshed.xml', ?, ?),
                 (2, 'https://example.test/never.xml', ?, NULL)
          """,
        arguments: [subscribedAt, refreshedAt, subscribedAt])
    }

    try SchemaV1.migrator().migrate(queue)

    let stamps = try queue.read { db in
      try Dictionary(
        uniqueKeysWithValues: Row.fetchAll(
          db, sql: "SELECT id, lastRefreshAttemptAt, lastRefreshedAt FROM rssFeed"
        ).map {
          ($0["id"] as Int64, ($0["lastRefreshAttemptAt"] as Date?, $0["lastRefreshedAt"] as Date?))
        })
    }
    #expect(stamps[1]?.0 == refreshedAt)
    #expect(stamps[1]?.1 == refreshedAt)
    #expect(stamps[2].map { $0.0 == nil } == true)
    #expect(stamps[2].map { $0.1 == nil } == true)
  }
}
