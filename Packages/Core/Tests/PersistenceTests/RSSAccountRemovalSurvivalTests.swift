import Foundation
import GRDB
import Testing

@testable import Persistence

/// Device-owned RSS subscriptions and their downloaded state survive removal of an account.
@Suite struct RSSAccountRemovalSurvivalTests {

  private static let rssTables = [
    "rssFeed", "rssEpisode", "rssEpisodeState", "rssFeedSettings", "rssDownload",
    "rssShowOrder", "rssPlaybackBookmark", "rssNotificationFeedBaseline",
    "rssEpisodeNotificationLedger",
    "rssFeedRecovery",
    "rssListeningQueueEntry",
    "rssWatchCopy",
    "rssWatchCopySet",
  ]

  @Test func removingAnAccountLeavesRSSRowsIntact() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await populateAccountAndRSSRows(database)
    let remover = AccountRemover(database: database)

    let before = try rowCounts(database)
    try remover.removeAccount(accountId: accountId)

    // The account row being gone proves the sweep ran; unchanged RSS counts prove it skipped them.
    let remainingAccounts = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM account WHERE id = ?", arguments: [accountId])
    }
    #expect(remainingAccounts == 0)
    #expect(try rowCounts(database) == before)
    let remainingQueueRows = try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssListeningQueueEntry")
    }
    #expect(remainingQueueRows == 1, "native RSS queue survives account removal")
  }

  @Test func rssTablesAreNotAccountOwned() throws {
    let database = try AppDatabase.inMemory()
    let remover = AccountRemover(database: database)

    #expect(try remover.accountOwnedTables().isDisjoint(with: Self.rssTables))
  }

  private func populateAccountAndRSSRows(_ database: AppDatabase) async throws -> Int64 {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "rss-removal-client", serverBaseURL: "https://example.com",
        serverUserId: "rss-user", serverVersion: "2.35.1")
      try account.insert(db)
      let accountId = try #require(account.id)
      let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

      try db.execute(
        sql: """
          INSERT INTO rssFeed
            (feedURL, title, subscribedAt, refreshGeneration)
          VALUES (?, ?, ?, ?)
          """,
        arguments: ["https://example.com/feed.xml", "Example Feed", timestamp, 1])
      let feedId = try #require(
        try Int64.fetchOne(
          db, sql: "SELECT id FROM rssFeed WHERE feedURL = ?",
          arguments: ["https://example.com/feed.xml"]))

      try db.execute(
        sql: """
          INSERT INTO rssEpisode
            (feedId, identityKey, enclosureURL, lastSeenGeneration)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [feedId, "episode-1", "https://example.com/episode.mp3", 1])
      let episodeId = try #require(
        try Int64.fetchOne(
          db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
          arguments: [feedId, "episode-1"]))

      try db.execute(
        sql: """
          INSERT INTO rssEpisodeState (episodeId, position, localSequence, updatedAt)
          VALUES (?, ?, ?, ?)
          """,
        arguments: [episodeId, 12.5, 1, timestamp])
      try db.execute(
        sql: """
          INSERT INTO rssFeedSettings (feedId, autoDownload, includeInLatest)
          VALUES (?, ?, ?)
          """,
        arguments: [feedId, "enabled", true])
      try db.execute(
        sql: """
          INSERT INTO rssDownload
            (episodeId, state, relativePath, origin, decidedStamp, createdAt, updatedAt)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          """,
        arguments: [
          episodeId, "completed", "episode-1.mp3", "manual", timestamp, timestamp, timestamp,
        ])
      try db.execute(sql: "INSERT INTO rssShowOrder (id, mode) VALUES (0, 'custom')")
      try db.execute(
        sql: "INSERT INTO rssPlaybackBookmark (id, episodeId, updatedAt) VALUES (0, ?, ?)",
        arguments: [episodeId, timestamp])
      try db.execute(
        sql: "INSERT INTO rssNotificationFeedBaseline (feedId, establishedAt) VALUES (?, ?)",
        arguments: [feedId, timestamp])
      try db.execute(
        sql: """
          INSERT INTO rssEpisodeNotificationLedger
            (feedId, identityKey, disposition, firstSeenAt, scheduledRequestID)
          VALUES (?, ?, 'scheduled', ?, ?)
          """,
        arguments: [feedId, "episode-1", timestamp, "rss-feed-\(feedId)-episode-1"])
      try db.execute(
        sql: "INSERT INTO rssFeedRecovery (feedId, reason, createdAt) VALUES (?, ?, ?)",
        arguments: [feedId, "credentialStorageFailed", timestamp])
      try db.execute(
        sql: """
          INSERT INTO rssListeningQueueEntry (rssEpisodeId, position)
          VALUES (?, 0)
          """,
        arguments: [episodeId])
      try db.execute(
        sql: """
          INSERT INTO rssWatchCopy (episodeId, revision, state, requestedAt, updatedAt)
          VALUES (?, 1, 'wanted', ?, ?)
          """,
        arguments: [episodeId, timestamp, timestamp])

      return accountId
    }
  }

  private func rowCounts(_ database: AppDatabase) throws -> [String: Int] {
    try database.read { db in
      var counts: [String: Int] = [:]
      for table in Self.rssTables {
        counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
      }
      return counts
    }
  }
}
