import Foundation
import GRDB
import Persistence
import Testing

/// The device-owned half of Home's Downloads shelf: a feed belongs there under the rule the ABS
/// projection applies to an item: at least one live download row, none still in flight.
@Suite("RSS Downloads shelf reading", .timeLimit(.minutes(1)))
struct RSSDownloadedShelfReadingTests {
  @Test
  func projectsAFeedWhoseEveryLiveDownloadIsCompleted() async throws {
    let database = try AppDatabase.inMemory()
    let feedURL = URL(string: "https://feeds.example/show.xml")!
    let artworkURL = URL(string: "https://images.example/show.jpg")!
    let subscribedAt = Date(timeIntervalSince1970: 1)
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: feedURL, title: "Show", author: "Host", synopsis: nil, artworkURL: artworkURL,
      subscribedAt: subscribedAt)
    let episodes = try await Self.insertEpisodes(database, feedID: feedID, keys: ["episode"])
    try await Self.insertDownload(
      database, episodeID: try #require(episodes["episode"]), state: "completed")

    let rows = try #require(
      await Self.first(RSSContinueListeningReading(database: database).observeDownloaded(limit: 10)))
    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.serverItemId == PodcastSourceIdentity.rss(feedId: feedID)?.itemId)
    #expect(row.title == "Show")
    #expect(row.author == "Host")
    #expect(row.category == .podcast)
    #expect(row.isDownloaded)
    #expect(row.audioDownloaded)
    #expect(row.episodeID == nil, "the shelf opens the show, not one episode")
    #expect(row.artworkURL == artworkURL)
    #expect(row.artworkFeedURL == feedURL)
    #expect(row.addedAt == subscribedAt)
  }

  @Test
  func excludesFeedsInFlightDeletingOrWithoutDownloads() async throws {
    let database = try AppDatabase.inMemory()
    let inFlight = try await Self.subscribe(database, title: "In Flight")
    let inFlightEpisodes = try await Self.insertEpisodes(
      database, feedID: inFlight, keys: ["done", "going"])
    try await Self.insertDownload(
      database, episodeID: try #require(inFlightEpisodes["done"]), state: "completed")
    try await Self.insertDownload(
      database, episodeID: try #require(inFlightEpisodes["going"]), state: "downloading")

    let deleting = try await Self.subscribe(database, title: "Deleting")
    let deletingEpisodes = try await Self.insertEpisodes(database, feedID: deleting, keys: ["gone"])
    try await Self.insertDownload(
      database, episodeID: try #require(deletingEpisodes["gone"]), state: "deleting")

    let bare = try await Self.subscribe(database, title: "Bare")
    _ = try await Self.insertEpisodes(database, feedID: bare, keys: ["never"])

    let ready = try await Self.subscribe(database, title: "Ready")
    let readyEpisodes = try await Self.insertEpisodes(
      database, feedID: ready, keys: ["kept", "removing"])
    try await Self.insertDownload(
      database, episodeID: try #require(readyEpisodes["kept"]), state: "completed")
    try await Self.insertDownload(
      database, episodeID: try #require(readyEpisodes["removing"]), state: "deleting")

    let rows = try #require(
      await Self.first(RSSContinueListeningReading(database: database).observeDownloaded(limit: 10)))
    #expect(rows.map(\.serverItemId) == [PodcastSourceIdentity.rss(feedId: ready)!.itemId])
  }

  @Test
  func ordersByTitleCaseInsensitivelyAndAppliesTheLimit() async throws {
    let database = try AppDatabase.inMemory()
    var feedIDs: [String: Int64] = [:]
    for title in ["beta", "Alpha", "gamma"] {
      let feedID = try await Self.subscribe(database, title: title)
      feedIDs[title] = feedID
      let episodes = try await Self.insertEpisodes(database, feedID: feedID, keys: ["episode"])
      try await Self.insertDownload(
        database, episodeID: try #require(episodes["episode"]), state: "completed")
    }

    let rows = try #require(
      await Self.first(RSSContinueListeningReading(database: database).observeDownloaded(limit: 2)))
    #expect(rows.map(\.title) == ["Alpha", "beta"])
  }

  @Test
  func reemitsWhenADownloadCompletes() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await Self.subscribe(database, title: "Show")
    let episodes = try await Self.insertEpisodes(database, feedID: feedID, keys: ["episode"])
    let episodeID = try #require(episodes["episode"])
    try await Self.insertDownload(database, episodeID: episodeID, state: "downloading")

    var iterator = RSSContinueListeningReading(database: database)
      .observeDownloaded(limit: 10).makeAsyncIterator()
    let initial = try #require(await iterator.next())
    #expect(initial.isEmpty)

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssDownload SET state = 'completed' WHERE episodeId = ?",
        arguments: [episodeID])
    }
    let completed = try #require(await iterator.next())
    #expect(completed.map(\.serverItemId) == [PodcastSourceIdentity.rss(feedId: feedID)!.itemId])
  }

  private static func subscribe(_ database: AppDatabase, title: String) async throws -> Int64 {
    try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://feeds.example/\(UUID().uuidString).xml")!,
      title: title, author: "Host", synopsis: nil, artworkURL: nil, subscribedAt: Date())
  }

  private static func insertEpisodes(
    _ database: AppDatabase, feedID: Int64, keys: [String]
  ) async throws -> [String: Int64] {
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedID,
      episodes: keys.map { key in
        RSSEpisodeUpsert(
          identityKey: key, title: key,
          enclosureURL: URL(string: "https://audio.example/\(key).mp3")!,
          durationSeconds: 1_800)
      })
    return try await database.readAsync { db in
      let rows = try RSSEpisodeRecord.fetchAll(
        db, sql: "SELECT * FROM rssEpisode WHERE feedId = ? ORDER BY id", arguments: [feedID])
      return try Dictionary(
        uniqueKeysWithValues: rows.map { row in
          (row.identityKey, try #require(row.id))
        })
    }
  }

  private static func insertDownload(
    _ database: AppDatabase, episodeID: Int64, state: String
  ) async throws {
    let now = Date()
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO rssDownload
            (episodeId, state, relativePath, origin, decidedStamp, createdAt, updatedAt)
          VALUES (?, ?, 'episode.mp3', 'manual', ?, ?, ?)
          """,
        arguments: [episodeID, state, now, now, now])
    }
  }

  private static func first(_ stream: AsyncStream<[HomeItem]>) async -> [HomeItem]? {
    for await value in stream { return value }
    return nil
  }
}
