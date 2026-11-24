import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct PodcastCloudDirtyLogTests {
  private func entries(_ database: AppDatabase) async throws -> Set<PodcastCloudDirtyEntry> {
    Set(try await database.readAsync { db in try PodcastCloudDirtyLog.entries(in: db) })
  }

  private func clearAll(_ database: AppDatabase) async throws {
    try await database.writeAsync { db in try db.execute(sql: "DELETE FROM podcastCloudDirty") }
  }

  private func seedFeedAndEpisode(_ database: AppDatabase) async throws -> (feed: Int64, episode: Int64) {
    let feed = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/feed.xml")!, title: "Show", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date(timeIntervalSince1970: 100))
    let episode = try await database.writeAsync { db -> Int64 in
      try db.execute(
        sql: """
          INSERT INTO rssEpisode (feedId, identityKey, enclosureURL, lastSeenGeneration)
          VALUES (?, 'guid:1', 'https://example.com/1.mp3', 0)
          """, arguments: [feed])
      return db.lastInsertedRowID
    }
    return (feed, episode)
  }

  @Test func everySyncedTableMarksTheEntityItTouched() async throws {
    let database = try AppDatabase.inMemory()
    let (feed, episode) = try await seedFeedAndEpisode(database)
    #expect(
      try await entries(database)
        == [PodcastCloudDirtyEntry(kind: .subscription, key: "https://example.com/feed.xml")])
    try await clearAll(database)

    try await database.writeAsync { db in
      try db.execute(sql: "INSERT INTO rssFeedSettings (feedId) VALUES (?)", arguments: [feed])
      try db.execute(
        sql: "INSERT INTO rssEpisodeState (episodeId, position, localSequence, updatedAt) VALUES (?, 5, 1, 0)",
        arguments: [episode])
      try db.execute(
        sql: "INSERT INTO rssSavedShelfEntry (rssEpisodeId, savedAt) VALUES (?, 0)", arguments: [episode])
      try db.execute(
        sql: "INSERT INTO rssPlaybackBookmark (id, episodeId, updatedAt) VALUES (0, ?, 0)",
        arguments: [episode])
      try db.execute(sql: "UPDATE nativePodcastSettings SET keepLatestCount = 9")
      try db.execute(sql: "INSERT OR REPLACE INTO rssShowOrder (id, mode) VALUES (0, 'custom')")
    }
    #expect(
      try await entries(database) == [
        PodcastCloudDirtyEntry(kind: .feedSettings, key: "\(feed)"),
        PodcastCloudDirtyEntry(kind: .episodeState, key: "\(episode)"),
        PodcastCloudDirtyEntry(kind: .saved, key: "\(episode)"),
        PodcastCloudDirtyEntry(kind: .bookmark, key: ""),
        PodcastCloudDirtyEntry(kind: .globals, key: ""),
      ])
  }

  @Test func refreshMetadataIsNotIntentButCustomOrderIs() async throws {
    let database = try AppDatabase.inMemory()
    let (feed, _) = try await seedFeedAndEpisode(database)
    try await clearAll(database)

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE rssFeed SET title = 'Renamed', etag = 'x' WHERE id = ?", arguments: [feed])
    }
    #expect(try await entries(database).isEmpty)

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE rssFeed SET customSortIndex = 0 WHERE id = ?", arguments: [feed])
    }
    #expect(
      try await entries(database)
        == [PodcastCloudDirtyEntry(kind: .subscription, key: "https://example.com/feed.xml")])
  }

  @Test func repeatedEditsCollapseOntoOneEntry() async throws {
    let database = try AppDatabase.inMemory()
    let (_, episode) = try await seedFeedAndEpisode(database)
    try await clearAll(database)
    for position in 1...20 {
      try await database.writeAsync { db in
        try db.execute(
          sql: """
            INSERT INTO rssEpisodeState (episodeId, position, localSequence, updatedAt) VALUES (?, ?, 1, 0)
            ON CONFLICT(episodeId) DO UPDATE SET position = excluded.position
            """, arguments: [episode, position])
      }
    }
    #expect(try await entries(database) == [PodcastCloudDirtyEntry(kind: .episodeState, key: "\(episode)")])
  }

  @Test func unsubscribeMarksTheFollowButNotTheCascadedState() async throws {
    let database = try AppDatabase.inMemory()
    let (feed, episode) = try await seedFeedAndEpisode(database)
    try await database.writeAsync { db in
      try db.execute(
        sql: "INSERT INTO rssEpisodeState (episodeId, position, localSequence, updatedAt) VALUES (?, 5, 1, 0)",
        arguments: [episode])
      try db.execute(sql: "DELETE FROM podcastCloudDirty")
    }
    try await RSSFeedStore(database: database).unsubscribe(feedId: feed)
    #expect(
      try await entries(database)
        == [PodcastCloudDirtyEntry(kind: .subscription, key: "https://example.com/feed.xml")])
  }

  @Test func markAllCoversTheCatalogueAndRegistryFollows() async throws {
    let database = try AppDatabase.inMemory()
    let (feed, episode) = try await seedFeedAndEpisode(database)
    try await database.writeAsync { db in
      try db.execute(
        sql: "INSERT INTO rssEpisodeState (episodeId, position, localSequence, updatedAt) VALUES (?, 5, 1, 0)",
        arguments: [episode])
      try PodcastCloudRegistryStore.register(
        in: db,
        entry: PodcastCloudRegistryEntry(
          subscriptionUUID: "sub-gone", fingerprint: "fp-gone", normalizedURL: "https://gone.example/feed",
          canonicalizationVersion: 1, generationUUID: "gen", isFollowed: true,
          followStamp: PodcastCloudStampFields(
            physicalMilliseconds: 1, logicalCounter: 0, installationUUID: "i", mutationUUID: "m")))
      try db.execute(sql: "DELETE FROM podcastCloudDirty")
      try PodcastCloudDirtyLog.markAll(in: db)
    }
    #expect(
      try await entries(database) == [
        PodcastCloudDirtyEntry(kind: .subscription, key: "https://example.com/feed.xml"),
        PodcastCloudDirtyEntry(kind: .subscription, key: "https://gone.example/feed"),
        PodcastCloudDirtyEntry(kind: .episodeState, key: "\(episode)"),
        PodcastCloudDirtyEntry(kind: .globals, key: ""),
      ])
    _ = feed
  }
}
