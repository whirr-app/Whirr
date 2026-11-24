import Foundation
import GRDB
import Persistence
import Testing

@Suite("RSS Latest Episodes reading")
struct RSSLatestPodcastEpisodesReadingTests {
  @Test("projects only current included unfinished episodes in newest-first order")
  func projectionAndInclusion() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let firstFeed = try await feedStore.subscribe(
      feedURL: URL(string: "https://feeds.example/one.xml")!, title: "One", author: "Host",
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let secondFeed = try await feedStore.subscribe(
      feedURL: URL(string: "https://feeds.example/two.xml")!, title: "Two", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    try await Self.insertEpisode(
      database, feedID: firstFeed, key: "older", publishedAt: now.addingTimeInterval(-20),
      generation: 0)
    try await Self.insertEpisode(
      database, feedID: secondFeed, key: "newer", publishedAt: now.addingTimeInterval(-10),
      generation: 0)
    let reading = RSSLatestPodcastEpisodesReading(database: database)
    var iterator = reading.observeLatestPodcastEpisodes(
      cutoff: { now.addingTimeInterval(-100) }, limit: 10
    ).makeAsyncIterator()

    let initial = try #require(await iterator.next())
    #expect(initial.map(\.id) == ["rss:\(secondFeed)/newer", "rss:\(firstFeed)/older"])

    try await RSSFeedSettingsStore(database: database).updateSettings(
      feedId: secondFeed, autoDownload: .inherit, keepLatest: nil,
      deleteAfterPlayed: nil, rateStep: nil, includeInLatest: false)
    let excluded = try #require(await iterator.next())
    #expect(excluded.map(\.id) == ["rss:\(firstFeed)/older"])
  }

  @Test("floors playback position to the minute")
  func floorsPlaybackPosition() async throws {
    let database = try AppDatabase.inMemory()
    let feed = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://feeds.example/one.xml")!, title: "One", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let episodeID = try await Self.insertEpisode(
      database, feedID: feed, key: "playing", publishedAt: now.addingTimeInterval(-10),
      generation: 0)
    _ = try await RSSEpisodeStateStore(database: database).recordTick(
      episodeId: episodeID, position: 754.3, finished: false, capturedSequence: 0, now: now)

    var iterator = RSSLatestPodcastEpisodesReading(database: database).observeLatestPodcastEpisodes(
      cutoff: { now.addingTimeInterval(-100) }, limit: 10
    ).makeAsyncIterator()
    #expect(try #require(await iterator.next()).first?.progressSeconds == 720)
  }

  @discardableResult
  private static func insertEpisode(
    _ database: AppDatabase, feedID: Int64, key: String, publishedAt: Date,
    generation: Int, duration: Double? = 1_800
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var record = RSSEpisodeRecord(
        feedId: feedID, identityKey: key, title: key,
        enclosureURL: "https://audio.example/\(key).mp3", publishedAt: publishedAt,
        durationSeconds: duration, lastSeenGeneration: generation)
      try record.insert(db)
      return try #require(record.id)
    }
  }
}
