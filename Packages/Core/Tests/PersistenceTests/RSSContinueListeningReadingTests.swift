import Foundation
import GRDB
import Persistence
import Testing

@Suite("RSS Continue Listening reading", .timeLimit(.minutes(1)))
struct RSSContinueListeningReadingTests {
  @Test
  func projectsOneCurrentUnfinishedEpisodePerFeed() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await Self.subscribe(database, title: "Show", artworkURL: nil)
    let episodeIDs = try await Self.insertEpisodes(
      database, feedID: feedID, keys: ["older", "newer"], durations: [1_800, 1_800])
    try await Self.writeState(
      database, episodeID: episodeIDs["older"]!, position: 120,
      finished: false, updatedAt: Date(timeIntervalSince1970: 10))
    try await Self.writeState(
      database, episodeID: episodeIDs["newer"]!, position: 240,
      finished: false, updatedAt: Date(timeIntervalSince1970: 20))

    let rows = try #require(
      await Self.first(
        RSSContinueListeningReading(database: database).observeContinueListening(limit: 10)))
    #expect(rows.count == 1)
    #expect(rows.first?.episodeID == "newer")
    #expect(rows.first?.progressRecency == Date(timeIntervalSince1970: 20))
  }

  @Test
  func ordersFeedsByStateRecency() async throws {
    let database = try AppDatabase.inMemory()
    let olderFeed = try await Self.subscribe(database, title: "Older", artworkURL: nil)
    let newerFeed = try await Self.subscribe(database, title: "Newer", artworkURL: nil)
    let olderEpisodes = try await Self.insertEpisodes(
      database, feedID: olderFeed, keys: ["older"], durations: [1_800])
    let newerEpisodes = try await Self.insertEpisodes(
      database, feedID: newerFeed, keys: ["newer"], durations: [1_800])
    let olderEpisode = try #require(olderEpisodes["older"])
    let newerEpisode = try #require(newerEpisodes["newer"])
    try await Self.writeState(
      database, episodeID: olderEpisode, position: 120,
      finished: false, updatedAt: Date(timeIntervalSince1970: 10))
    try await Self.writeState(
      database, episodeID: newerEpisode, position: 120,
      finished: false, updatedAt: Date(timeIntervalSince1970: 20))

    let rows = try #require(
      await Self.first(
        RSSContinueListeningReading(database: database).observeContinueListening(limit: 10)))
    #expect(
      rows.map(\.serverItemId) == [
        PodcastSourceIdentity.rss(feedId: newerFeed)!.itemId,
        PodcastSourceIdentity.rss(feedId: olderFeed)!.itemId,
      ])
  }

  @Test
  func mapsCanonicalRSSIdentityAndFeedArtwork() async throws {
    let database = try AppDatabase.inMemory()
    let feedURL = URL(string: "https://feeds.example/show.xml")!
    let artworkURL = URL(string: "https://images.example/show.jpg")!
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: feedURL, title: "Show", author: "Host", synopsis: nil,
      artworkURL: artworkURL, subscribedAt: Date(timeIntervalSince1970: 1))
    let episodes = try await Self.insertEpisodes(
      database, feedID: feedID, keys: ["episode"], durations: [1_800])
    let episodeID = try #require(episodes["episode"])
    try await Self.writeState(
      database, episodeID: episodeID, position: 120,
      finished: false, updatedAt: Date(timeIntervalSince1970: 20))

    let values = try #require(
      await Self.first(
        RSSContinueListeningReading(database: database).observeContinueListening(limit: 10)))
    let row = values.first
    #expect(row?.serverItemId == PodcastSourceIdentity.rss(feedId: feedID)?.itemId)
    #expect(row?.artworkURL == artworkURL)
    #expect(row?.artworkFeedURL == feedURL)
  }

  @Test
  func usesMeasuredDurationWhenDeclaredDurationIsMissing() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await Self.subscribe(database, title: "Show", artworkURL: nil)
    let episodes = try await Self.insertEpisodes(
      database, feedID: feedID, keys: ["episode"], durations: [nil])
    let episodeID = try #require(episodes["episode"])
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssEpisode SET measuredDurationSeconds = ? WHERE id = ?",
        arguments: [600, episodeID])
    }
    try await Self.writeState(
      database, episodeID: episodeID, position: 120,
      finished: false, updatedAt: Date(timeIntervalSince1970: 20))

    let values = try #require(
      await Self.first(
        RSSContinueListeningReading(database: database).observeContinueListening(limit: 10)))
    let row = values.first
    #expect(row?.durationSeconds == 600)
  }

  @Test
  func excludesFinishedZeroPositionAndFinalMinuteRows() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await Self.subscribe(database, title: "Show", artworkURL: nil)
    let episodeIDs = try await Self.insertEpisodes(
      database, feedID: feedID, keys: ["finished", "zero", "final-minute"], durations: [1_800, 1_800, 100])
    try await Self.writeState(
      database, episodeID: episodeIDs["finished"]!, position: 120,
      finished: true, updatedAt: Date(timeIntervalSince1970: 10))
    try await Self.writeState(
      database, episodeID: episodeIDs["zero"]!, position: 0,
      finished: false, updatedAt: Date(timeIntervalSince1970: 20))
    try await Self.writeState(
      database, episodeID: episodeIDs["final-minute"]!, position: 50,
      finished: false, updatedAt: Date(timeIntervalSince1970: 30))

    let rows = try #require(
      await Self.first(
        RSSContinueListeningReading(database: database).observeContinueListening(limit: 10)))
    #expect(rows.isEmpty)
  }

  @Test
  func includesRetainedDroppedEpisodeOnlyWhenDownloadCompleted() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await Self.subscribe(database, title: "Show", artworkURL: nil)
    let episodes = try await Self.insertEpisodes(
      database, feedID: feedID, keys: ["dropped"], durations: [1_800])
    let episodeID = try #require(episodes["dropped"])
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssEpisode SET lastSeenGeneration = 0, retained = 1 WHERE id = ?",
        arguments: [episodeID])
    }
    try await Self.writeState(
      database, episodeID: episodeID, position: 120,
      finished: false, updatedAt: Date(timeIntervalSince1970: 20))

    let reading = RSSContinueListeningReading(database: database)
    #expect(
      try #require(await Self.first(reading.observeContinueListening(limit: 10))).isEmpty)

    let now = Date(timeIntervalSince1970: 30)
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO rssDownload
            (episodeId, state, relativePath, origin, decidedStamp, createdAt, updatedAt)
          VALUES (?, 'completed', 'episode.mp3', 'manual', ?, ?, ?)
          """,
        arguments: [episodeID, now, now, now])
    }
    let rows = try #require(await Self.first(reading.observeContinueListening(limit: 10)))
    #expect(rows.map(\.episodeID) == ["dropped"])
  }

  @Test
  func appliesLimitAfterPerFeedSelection() async throws {
    let database = try AppDatabase.inMemory()
    let firstFeed = try await Self.subscribe(database, title: "First", artworkURL: nil)
    let secondFeed = try await Self.subscribe(database, title: "Second", artworkURL: nil)
    let thirdFeed = try await Self.subscribe(database, title: "Third", artworkURL: nil)
    let firstEpisodes = try await Self.insertEpisodes(
      database, feedID: firstFeed, keys: ["first-old", "first-new"], durations: [1_800, 1_800])
    let secondEpisodes = try await Self.insertEpisodes(
      database, feedID: secondFeed, keys: ["second"], durations: [1_800])
    let thirdEpisodes = try await Self.insertEpisodes(
      database, feedID: thirdFeed, keys: ["third"], durations: [1_800])
    let secondEpisode = try #require(secondEpisodes["second"])
    let thirdEpisode = try #require(thirdEpisodes["third"])
    try await Self.writeState(
      database, episodeID: firstEpisodes["first-old"]!, position: 120,
      finished: false, updatedAt: Date(timeIntervalSince1970: 299))
    try await Self.writeState(
      database, episodeID: firstEpisodes["first-new"]!, position: 120,
      finished: false, updatedAt: Date(timeIntervalSince1970: 300))
    try await Self.writeState(
      database, episodeID: secondEpisode, position: 120,
      finished: false, updatedAt: Date(timeIntervalSince1970: 200))
    try await Self.writeState(
      database, episodeID: thirdEpisode, position: 120,
      finished: false, updatedAt: Date(timeIntervalSince1970: 100))

    let rows = try #require(
      await Self.first(
        RSSContinueListeningReading(database: database).observeContinueListening(limit: 2)))
    #expect(
      rows.map(\.serverItemId) == [
        PodcastSourceIdentity.rss(feedId: firstFeed)!.itemId,
        PodcastSourceIdentity.rss(feedId: secondFeed)!.itemId,
      ])
    #expect(rows.map(\.episodeID) == ["first-new", "second"])
  }

  /// The position is floored for the list; the recency the cross-source merge orders by is not.
  @Test
  func floorsPositionToTheMinuteAndKeepsRecencyExact() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await Self.subscribe(database, title: "Show", artworkURL: nil)
    let episodes = try await Self.insertEpisodes(
      database, feedID: feedID, keys: ["episode"], durations: [1_800])
    let updatedAt = Date(timeIntervalSince1970: 10.25)
    try await Self.writeState(
      database, episodeID: try #require(episodes["episode"]), position: 754.3, finished: false,
      updatedAt: updatedAt)

    var iterator = RSSContinueListeningReading(database: database)
      .observeContinueListening(limit: 10).makeAsyncIterator()
    let row = try #require(await iterator.next()).first
    #expect(row?.progressSeconds == 720)
    #expect(row?.progressRecency == updatedAt)
  }

  @Test
  func reemitsWhenEpisodeStateChanges() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await Self.subscribe(database, title: "Show", artworkURL: nil)
    let episodes = try await Self.insertEpisodes(
      database, feedID: feedID, keys: ["episode"], durations: [1_800])
    let episodeID = try #require(episodes["episode"])
    let firstDate = Date(timeIntervalSince1970: 10)
    try await Self.writeState(
      database, episodeID: episodeID, position: 120, finished: false, updatedAt: firstDate)

    var iterator = RSSContinueListeningReading(database: database)
      .observeContinueListening(limit: 10).makeAsyncIterator()
    let first = try #require(await iterator.next()).first
    #expect(first?.progressSeconds == 120)
    #expect(first?.progressRecency == firstDate)

    let secondDate = Date(timeIntervalSince1970: 20)
    try await Self.writeState(
      database, episodeID: episodeID, position: 240, finished: false, updatedAt: secondDate,
      capturedSequence: 1)
    let second = try #require(await iterator.next()).first
    #expect(second?.progressSeconds == 240)
    #expect(second?.progressRecency == secondDate)
  }

  /// The shelf judges "nearly finished" against the file the listener is playing. With a
  /// downloaded file 104 s shorter than the feed declares, 1_740 s in is 6 s from the file's end but
  /// 110 s from the feed's, and 1_500 s in is still well short of both.
  @Test
  func judgesRemainingTimeAgainstTheDownloadedFile() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await Self.subscribe(database, title: "Show", artworkURL: nil)
    let otherFeedID = try await Self.subscribe(database, title: "Other", artworkURL: nil)
    let nearlyDone = try #require(
      try await Self.insertEpisodes(
        database, feedID: feedID, keys: ["nearly-done"], durations: [1_850])["nearly-done"])
    let midway = try #require(
      try await Self.insertEpisodes(
        database, feedID: otherFeedID, keys: ["midway"], durations: [1_850])["midway"])
    for episode in [nearlyDone, midway] {
      try await RSSDownloadDurationStoreTests.downloadAndMeasure(
        database, episodeID: episode, seconds: 1_746)
    }
    try await Self.writeState(
      database, episodeID: nearlyDone, position: 1_740, finished: false,
      updatedAt: Date(timeIntervalSince1970: 20))
    try await Self.writeState(
      database, episodeID: midway, position: 1_500, finished: false,
      updatedAt: Date(timeIntervalSince1970: 10))

    let rows = try #require(
      await Self.first(
        RSSContinueListeningReading(database: database).observeContinueListening(limit: 10)))
    #expect(rows.map(\.episodeID) == ["midway"])
    #expect(rows.first?.durationSeconds == 1_746)
  }

  /// Once the file is gone the feed's length is the only one there is, so the same position is no
  /// longer nearly finished.
  @Test
  func fallsBackToTheFeedLengthOnceTheDownloadIsDeleted() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await Self.subscribe(database, title: "Show", artworkURL: nil)
    let episode = try #require(
      try await Self.insertEpisodes(
        database, feedID: feedID, keys: ["episode"], durations: [1_850])["episode"])
    let downloadID = try await RSSDownloadDurationStoreTests.downloadAndMeasure(
      database, episodeID: episode, seconds: 1_746)
    try await Self.writeState(
      database, episodeID: episode, position: 1_740, finished: false,
      updatedAt: Date(timeIntervalSince1970: 20))

    try await RSSDownloadDurationStoreTests.deleteDownload(database, downloadID: downloadID)

    let rows = try #require(
      await Self.first(
        RSSContinueListeningReading(database: database).observeContinueListening(limit: 10)))
    #expect(rows.map(\.episodeID) == ["episode"])
    #expect(rows.first?.durationSeconds == 1_850)
  }

  private static func subscribe(
    _ database: AppDatabase, title: String?, artworkURL: URL?
  ) async throws -> Int64 {
    try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://feeds.example/\(UUID().uuidString).xml")!,
      title: title, author: "Host", synopsis: nil, artworkURL: artworkURL, subscribedAt: Date())
  }

  private static func insertEpisodes(
    _ database: AppDatabase, feedID: Int64, keys: [String], durations: [Double?]
  ) async throws -> [String: Int64] {
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedID,
      episodes: zip(keys, durations).map { key, duration in
        RSSEpisodeUpsert(
          identityKey: key, title: key,
          enclosureURL: URL(string: "https://audio.example/\(key).mp3")!,
          durationSeconds: duration)
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

  @Test
  func excludesEpisodesDismissedFromContinueListening() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await Self.subscribe(database, title: "Show", artworkURL: nil)
    let episodeIDs = try await Self.insertEpisodes(
      database, feedID: feedID, keys: ["dismissed", "kept"], durations: [1_800, 1_800])
    let dismissed = try #require(episodeIDs["dismissed"])
    let kept = try #require(episodeIDs["kept"])
    // The dismissed episode is the more recent of the two, so it would head the shelf if the
    // flag were ignored rather than merely losing the per-feed tie-break.
    try await Self.writeState(
      database, episodeID: kept, position: 120, finished: false,
      updatedAt: Date(timeIntervalSince1970: 10))
    try await Self.writeState(
      database, episodeID: dismissed, position: 240, finished: false,
      updatedAt: Date(timeIntervalSince1970: 20))
    _ = try await RSSEpisodeStateStore(database: database).setHiddenFromContinueListening(
      episodeId: dismissed, isHidden: true, now: Date(timeIntervalSince1970: 30))

    let rows = try #require(
      await Self.first(
        RSSContinueListeningReading(database: database).observeContinueListening(limit: 10)))
    #expect(rows.map(\.episodeID) == ["kept"])
  }

  /// Resuming a dismissed episode is the only way back onto the shelf, and it has to work without
  /// the listener knowing they ever dismissed it.
  @Test
  func resumingADismissedEpisodeRestoresItToTheShelf() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await Self.subscribe(database, title: "Show", artworkURL: nil)
    let episodeIDs = try await Self.insertEpisodes(
      database, feedID: feedID, keys: ["dismissed"], durations: [1_800])
    let dismissed = try #require(episodeIDs["dismissed"])
    try await Self.writeState(
      database, episodeID: dismissed, position: 120, finished: false,
      updatedAt: Date(timeIntervalSince1970: 10))
    _ = try await RSSEpisodeStateStore(database: database).setHiddenFromContinueListening(
      episodeId: dismissed, isHidden: true, now: Date(timeIntervalSince1970: 20))

    try await Self.writeState(
      database, episodeID: dismissed, position: 180, finished: false,
      updatedAt: Date(timeIntervalSince1970: 30), capturedSequence: .max)

    let rows = try #require(
      await Self.first(
        RSSContinueListeningReading(database: database).observeContinueListening(limit: 10)))
    #expect(rows.map(\.episodeID) == ["dismissed"])
  }

  private static func writeState(
    _ database: AppDatabase,
    episodeID: Int64,
    position: Double,
    finished: Bool,
    updatedAt: Date,
    capturedSequence: Int64 = 0
  ) async throws {
    _ = try await RSSEpisodeStateStore(database: database).recordTick(
      episodeId: episodeID, position: position, finished: finished,
      capturedSequence: capturedSequence, now: updatedAt)
  }

  private static func first<T: Sendable>(_ stream: AsyncStream<T>) async -> T? {
    for await value in stream { return value }
    return nil
  }
}
