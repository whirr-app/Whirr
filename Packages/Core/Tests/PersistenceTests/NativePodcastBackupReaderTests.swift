import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct NativePodcastBackupReaderTests {
  @Test func emptyDatabaseReadsDefaultsAndNothingElse() async throws {
    let contents = try await NativePodcastBackupReader(database: AppDatabase.inMemory()).contents()
    #expect(contents.globalSettings == NativePodcastSettingsRecord())
    #expect(contents.showOrderMode == NativePodcastShowSortMode.alphabetical.rawValue)
    #expect(contents.feeds.isEmpty)
    #expect(contents.episodes.isEmpty)
    #expect(contents.bookmark == nil)
    #expect(contents.followedGenerations.isEmpty)
  }

  @Test func readsFeedsSettingsAndOrder() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      let plain = try Self.insertFeed(db, url: "https://example.com/a", title: "A", order: 1)
      let tuned = try Self.insertFeed(db, url: "https://example.com/b", title: nil, order: nil)
      _ = plain
      try db.execute(
        sql: """
          INSERT INTO rssFeedSettings
            (feedId, autoDownload, keepLatest, deleteAfterPlayed, rateStep, includeInLatest, notificationOverride)
          VALUES (?, 'enabled', 5, 1, NULL, 0, 'disabled')
          """, arguments: [tuned])
      try db.execute(sql: "INSERT INTO rssShowOrder (id, mode) VALUES (0, 'mostRecent')")
      try NativePodcastSettingsRecord(autoDownloadEnabled: true, keepLatestCount: 7).save(db)
    }

    let contents = try await NativePodcastBackupReader(database: database).contents()
    #expect(contents.showOrderMode == "mostRecent")
    #expect(contents.globalSettings.autoDownloadEnabled && contents.globalSettings.keepLatestCount == 7)
    #expect(contents.feeds.map(\.feedURL) == ["https://example.com/a", "https://example.com/b"])
    #expect(contents.feeds[0].title == "A" && contents.feeds[0].customSortIndex == 1)
    #expect(contents.feeds[0].settings == nil)
    #expect(
      contents.feeds[1].settings
        == NativePodcastBackupContents.FeedSettings(
          autoDownload: "enabled", keepLatest: 5, deleteAfterPlayed: true, rateStep: nil, includeInLatest: false,
          notificationOverride: "disabled"))
  }

  /// State rows are sparse: absent, present at zero, and dismissal-only must stay distinct, and an
  /// untouched catalogue episode is not part of a backup at all.
  @Test func readsOnlyInteractedEpisodesAndKeepsSparseStateDistinct() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      let feed = try Self.insertFeed(db, url: "https://example.com/a", title: "A", order: nil)
      let untouched = try Self.insertEpisode(db, feed: feed, key: "untouched")
      let zero = try Self.insertEpisode(db, feed: feed, key: "zero")
      let dismissed = try Self.insertEpisode(db, feed: feed, key: "dismissed")
      let saved = try Self.insertEpisode(db, feed: feed, key: "saved")
      let bookmarked = try Self.insertEpisode(db, feed: feed, key: "bookmarked")
      _ = untouched
      try Self.insertState(db, episode: zero, position: 0, finished: false, dismissed: false)
      try Self.insertState(db, episode: dismissed, position: 0, finished: false, dismissed: true)
      try db.execute(
        sql: "INSERT INTO rssSavedShelfEntry (rssEpisodeId, savedAt) VALUES (?, ?)",
        arguments: [saved, Date(timeIntervalSince1970: 300)])
      try db.execute(
        sql: "INSERT INTO rssPlaybackBookmark (id, episodeId, updatedAt) VALUES (0, ?, ?)",
        arguments: [bookmarked, Date(timeIntervalSince1970: 400)])
    }

    let contents = try await NativePodcastBackupReader(database: database).contents()
    let byKey = Dictionary(uniqueKeysWithValues: contents.episodes.map { ($0.identityKey, $0) })
    #expect(Set(byKey.keys) == ["zero", "dismissed", "saved", "bookmarked"])
    #expect(byKey["zero"]?.state?.position == 0 && byKey["zero"]?.state?.dismissed == false)
    #expect(byKey["dismissed"]?.state?.dismissed == true)
    #expect(byKey["saved"]?.state == nil && byKey["saved"]?.savedAt == Date(timeIntervalSince1970: 300))
    #expect(byKey["bookmarked"]?.state == nil && byKey["bookmarked"]?.savedAt == nil)
    #expect(
      contents.bookmark
        == NativePodcastBackupContents.Bookmark(
          feedURL: "https://example.com/a", identityKey: "bookmarked", updatedAt: Date(timeIntervalSince1970: 400)))
  }

  @Test func readsOnlyFollowedRegistryGenerations() async throws {
    let database = try AppDatabase.inMemory()
    try await database.writeAsync { db in
      for (uuid, followed) in [
        ("AAAAAAAA-0000-8000-8000-000000000001", 1), ("aaaaaaaa-0000-8000-8000-000000000002", 0),
      ] {
        try db.execute(
          sql: """
            INSERT INTO podcastCloudSubscriptionRegistry
              (subscriptionUUID, fingerprint, normalizedURL, canonicalizationVersion, generationUUID, isFollowed,
               followPhysicalMilliseconds, followLogicalCounter, followInstallationUUID, followMutationUUID)
            VALUES (?, ?, 'https://example.com', 1, 'gen-\(followed)', ?, 0, 0, 'i', 'm')
            """, arguments: [uuid, uuid, followed])
      }
    }
    let contents = try await NativePodcastBackupReader(database: database).contents()
    #expect(contents.followedGenerations == ["aaaaaaaa-0000-8000-8000-000000000001": "gen-1"])
  }

  static func insertFeed(_ db: Database, url: String, title: String?, order: Int?) throws -> Int64 {
    try db.execute(
      sql: "INSERT INTO rssFeed (feedURL, title, subscribedAt, customSortIndex) VALUES (?, ?, ?, ?)",
      arguments: [url, title, Date(timeIntervalSince1970: 100), order])
    return db.lastInsertedRowID
  }

  static func insertEpisode(_ db: Database, feed: Int64, key: String) throws -> Int64 {
    try db.execute(
      sql: """
        INSERT INTO rssEpisode (feedId, identityKey, title, enclosureURL, lastSeenGeneration)
        VALUES (?, ?, ?, ?, 0)
        """, arguments: [feed, key, key, "https://example.com/\(key).mp3"])
    return db.lastInsertedRowID
  }

  static func insertState(_ db: Database, episode: Int64, position: Double, finished: Bool, dismissed: Bool) throws {
    try db.execute(
      sql: """
        INSERT INTO rssEpisodeState (episodeId, position, finished, hideFromContinueListening, localSequence, updatedAt)
        VALUES (?, ?, ?, ?, 1, ?)
        """, arguments: [episode, position, finished, dismissed, Date(timeIntervalSince1970: 200)])
  }
}
