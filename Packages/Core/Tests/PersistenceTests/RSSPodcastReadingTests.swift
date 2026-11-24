import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite(.timeLimit(.minutes(1))) struct RSSPodcastReadingTests {
  @Test func mapsOrdersAndTracksRSSEpisodes() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: "Show", author: "Author")
    let store = RSSEpisodeStore(database: database)
    let url = URL(string: "https://example.com/e.mp3")!
    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "new", title: "New", synopsis: "<p>Synopsis</p>", synopsisLine: "Synopsis",
          enclosureURL: url,
          declaredBytes: 1234, publishedAt: Date(timeIntervalSince1970: 30), durationSeconds: 99,
          seasonNumber: 2, episodeNumber: 3),
        RSSEpisodeUpsert(
          identityKey: "old", title: "Old", enclosureURL: url, publishedAt: Date(timeIntervalSince1970: 20)),
        RSSEpisodeUpsert(identityKey: "undated", title: nil, enclosureURL: url),
      ])
    let episodeID = try #require(try await id(database, feedId: feedId, key: "new"))
    _ = try await RSSEpisodeStateStore(database: database).recordTick(
      episodeId: episodeID, position: 42, finished: false, capturedSequence: 0, now: Date())
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO rssDownload
            (episodeId, state, relativePath, expectedBytes, actualBytes, origin, decidedStamp, createdAt, updatedAt)
          VALUES (?, 'completed', 'e.mp3', ?, ?, 'manual', ?, ?, ?)
          """,
        arguments: [episodeID, 1234, 1234, Date(), Date(), Date()])
    }

    let reading = RSSPodcastReading(database: database)
    let summaries = try #require(await first(reading.observeEpisodes(itemId: "rss:\(feedId)")))
    #expect(summaries.map(\.id) == ["new", "old", "undated"])
    let mapped = try #require(summaries.first)
    #expect(mapped.title == "New")
    #expect(mapped.subtitle == nil)
    #expect(mapped.episodeDescription == nil)
    #expect(mapped.synopsisLine == "Synopsis")
    #expect(mapped.seasonNumber == "2")
    #expect(mapped.episodeNumber == "3")
    #expect(mapped.episodeType == nil)
    #expect(mapped.durationSeconds == 99)
    #expect(mapped.sizeBytes == 1234)
    #expect(mapped.progressSeconds == 42)
    #expect(mapped.isPlayed)
    #expect(!mapped.isFinished)
    #expect(mapped.downloadStatus == .completed)
    #expect(mapped.isAvailableOnServer)
    #expect(try #require(summaries.last).title == "")

    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [RSSEpisodeUpsert(identityKey: "new", enclosureURL: url)])
    let afterRefresh = try #require(await first(reading.observeEpisodes(itemId: "rss:\(feedId)")))
    #expect(afterRefresh.first(where: { $0.id == "new" })?.isAvailableOnServer == true)
    #expect(afterRefresh.first(where: { $0.id == "old" })?.isAvailableOnServer == false)
  }

  @Test func episodePrefixMatchesTheObservationBaseline() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: "Show", author: nil)
    let url = URL(string: "https://example.com/e.mp3")!
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "newest", title: "Newest", enclosureURL: url,
          publishedAt: Date(timeIntervalSince1970: 40)),
        RSSEpisodeUpsert(
          identityKey: "newer", title: "Newer", enclosureURL: url,
          publishedAt: Date(timeIntervalSince1970: 30)),
        RSSEpisodeUpsert(
          identityKey: "older", title: "Older", enclosureURL: url,
          publishedAt: Date(timeIntervalSince1970: 20)),
      ])
    let reading = RSSPodcastReading(database: database)
    let itemId = "rss:\(feedId)"

    let observed = try #require(await first(reading.observeEpisodes(itemId: itemId)))
    #expect(observed.map(\.id) == ["newest", "newer", "older"])
    #expect(
      reading.episodePrefix(itemId: itemId, limit: 2)
        == .init(episodes: Array(observed.prefix(2)), isComplete: false))
    #expect(reading.episodePrefix(itemId: itemId, limit: 3) == .init(episodes: observed, isComplete: true))
    #expect(reading.episodePrefix(itemId: itemId, limit: 10) == .init(episodes: observed, isComplete: true))
    for other in ["abs-item-1", "rss:", "rss:abc"] {
      #expect(reading.episodePrefix(itemId: other, limit: 2) == .init(episodes: [], isComplete: true))
    }
  }

  @Test func resolvesOnlyEpisodesBelongingToTheFeed() async throws {
    let database = try AppDatabase.inMemory()
    let firstFeed = try await subscribe(database, title: "First", author: "A")
    let secondFeed = try await subscribe(database, title: "Second", author: "B")
    let store = RSSEpisodeStore(database: database)
    let url = URL(string: "https://example.com/e.mp3")!
    _ = try await store.applyRefresh(
      feedId: firstFeed, episodes: [RSSEpisodeUpsert(identityKey: "same", title: "One", enclosureURL: url)])
    _ = try await store.applyRefresh(
      feedId: secondFeed, episodes: [RSSEpisodeUpsert(identityKey: "same", title: "Two", enclosureURL: url)])
    let reading = RSSPodcastReading(database: database)
    let context = try #require(await reading.episode(itemID: "rss:\(firstFeed)", episodeID: "same"))
    #expect(context.showTitle == "First")
    #expect(context.showAuthor == "A")
    #expect(context.episode.title == "One")
    #expect(try await reading.episode(itemID: "rss:\(firstFeed)", episodeID: "missing") == nil)
    #expect(try await reading.episode(itemID: "rss:\(secondFeed)", episodeID: "same") != nil)
    try await RSSFeedStore(database: database).unsubscribe(feedId: firstFeed)
    #expect(try await reading.episode(itemID: "rss:\(firstFeed)", episodeID: "same") == nil)
  }

  @Test func recentEpisodeDescriptionsAreFeedScopedNewestFirstAndSkipMissingText() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: "Show", author: nil)
    let otherFeed = try await subscribe(database, title: "Other", author: nil)
    let store = RSSEpisodeStore(database: database)
    let url = URL(string: "https://example.com/e.mp3")!
    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "old", synopsis: "old", enclosureURL: url,
          publishedAt: Date(timeIntervalSince1970: 10)),
        RSSEpisodeUpsert(identityKey: "undated", synopsis: "undated", enclosureURL: url),
        RSSEpisodeUpsert(
          identityKey: "new", synopsis: "new", enclosureURL: url,
          publishedAt: Date(timeIntervalSince1970: 30)),
        RSSEpisodeUpsert(
          identityKey: "silent", enclosureURL: url, publishedAt: Date(timeIntervalSince1970: 20)),
      ])
    _ = try await store.applyRefresh(
      feedId: otherFeed, episodes: [RSSEpisodeUpsert(identityKey: "x", synopsis: "other", enclosureURL: url)])
    let reading = RSSPodcastReading(database: database)

    #expect(
      try await reading.recentEpisodeDescriptions(itemId: "rss:\(feedId)", limit: 20)
        == ["new", "old", "undated"])
    #expect(try await reading.recentEpisodeDescriptions(itemId: "rss:\(feedId)", limit: 2) == ["new", "old"])
    #expect(try await reading.recentEpisodeDescriptions(itemId: "rss:999", limit: 20) == [])
    #expect(try await reading.recentEpisodeDescriptions(itemId: "li_abc", limit: 20) == [])
  }

  @Test func episodeContextCarriesDeclaredFeedArtwork() async throws {
    let database = try AppDatabase.inMemory()
    let feedURL = URL(string: "https://example.com/show.xml")!
    let artworkURL = URL(string: "https://images.example.com/show.jpg")!
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: feedURL,
      title: "Show",
      author: "Author",
      synopsis: nil,
      artworkURL: artworkURL,
      subscribedAt: Date(timeIntervalSince1970: 1))
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "episode", title: "Episode",
          enclosureURL: URL(string: "https://example.com/episode.mp3")!)
      ])

    let context = try #require(
      await RSSPodcastReading(database: database).episode(
        itemID: "rss:\(feedID)", episodeID: "episode"))

    #expect(context.artworkURL == artworkURL)
    #expect(context.artworkFeedURL == feedURL)
  }

  @Test func episodeContextCarriesTheEpisodesOwnArtworkBesideTheShowsArt() async throws {
    let database = try AppDatabase.inMemory()
    let showArtURL = URL(string: "https://images.example.com/show.jpg")!
    let episodeArtURL = URL(string: "https://images.example.com/episode.jpg")!
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/show.xml")!,
      title: "Show", author: "Author", synopsis: nil, artworkURL: showArtURL,
      subscribedAt: Date(timeIntervalSince1970: 1))
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "with-art", title: "With art",
          enclosureURL: URL(string: "https://example.com/with.mp3")!,
          artworkURL: episodeArtURL),
        RSSEpisodeUpsert(
          identityKey: "without-art", title: "Without art",
          enclosureURL: URL(string: "https://example.com/without.mp3")!),
      ])
    let reading = RSSPodcastReading(database: database)

    let withArt = try #require(
      await reading.episode(itemID: "rss:\(feedID)", episodeID: "with-art"))
    #expect(withArt.episodeArtworkURL == episodeArtURL)
    #expect(withArt.artworkURL == showArtURL)

    let withoutArt = try #require(
      await reading.episode(itemID: "rss:\(feedID)", episodeID: "without-art"))
    #expect(withoutArt.episodeArtworkURL == nil)
    #expect(withoutArt.artworkURL == showArtURL)
  }

  @Test func episodeContextPrefersTheCompletedDownloadsMeasuredLength() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: "Show", author: "Author")
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "episode", title: "Episode",
          enclosureURL: URL(string: "https://example.com/e.mp3")!, durationSeconds: 2_150)
      ])
    let episodeID = try #require(try await id(database, feedId: feedId, key: "episode"))
    let reading = RSSPodcastReading(database: database)
    func duration() async throws -> Double? {
      try await reading.episode(itemID: "rss:\(feedId)", episodeID: "episode")?.episode.durationSeconds
    }

    #expect(try await duration() == 2_150)

    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO rssDownload
            (episodeId, state, relativePath, measuredDurationSeconds, origin, decidedStamp, createdAt, updatedAt)
          VALUES (?, 'completed', 'e.mp3', 2185, 'manual', ?, ?, ?)
          """,
        arguments: [episodeID, Date(), Date(), Date()])
    }
    #expect(try await duration() == 2_185)

    // A download that is going away no longer describes a file the listener will hear.
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE rssDownload SET state = 'deleting' WHERE episodeId = ?", arguments: [episodeID])
    }
    #expect(try await duration() == 2_150)
  }

  @Test func handlesDownloadStatesAndInvalidItemIds() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: nil, author: nil)
    let url = URL(string: "https://example.com/e.mp3")!
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "downloading", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "failed", enclosureURL: url),
      ])
    let ids = try await database.readAsync { db in
      try RSSEpisodeRecord.fetchAll(db, sql: "SELECT * FROM rssEpisode ORDER BY id")
        .map { (identityKey: $0.identityKey, id: try #require($0.id)) }
    }
    try await database.writeAsync { db in
      for episode in ids {
        let state = episode.identityKey == "downloading" ? "downloading" : "failed"
        try db.execute(
          sql:
            "INSERT INTO rssDownload (episodeId, state, relativePath, expectedBytes, actualBytes, origin, decidedStamp, errorCode, createdAt, updatedAt) VALUES (?, ?, 'x', ?, ?, 'manual', ?, ?, ?, ?)",
          arguments: [
            episode.id, state, state == "downloading" ? 1000 : 0, state == "downloading" ? 260 : 0, Date(),
            state == "failed" ? DownloadErrorCategory.lowDisk.rawValue : nil, Date(), Date(),
          ])
      }
    }
    let reading = RSSPodcastReading(database: database)
    let rows = try #require(await first(reading.observeEpisodes(itemId: "rss:\(feedId)")))
    // The list carries no byte progress; the fraction lives in the progress projection.
    #expect(rows.first?.downloadStatus == .downloading(progressFraction: 0))
    #expect(rows.last?.downloadStatus == .failed(category: .lowDisk))
    #expect(
      try #require(await first(reading.observeEpisodeDownloadProgress(itemId: "rss:\(feedId)")))
        == ["downloading": 0.26])
    for itemId in ["abs-item-1", "rss:", "rss:0", "rss:abc"] {
      #expect(try #require(await first(reading.observeEpisodes(itemId: itemId))).isEmpty)
      #expect(try await reading.episode(itemID: itemId, episodeID: "downloading") == nil)
      #expect(try #require(await first(reading.observeShowDiagnostics(itemId: itemId))) == nil)
    }
    let diagnosticsValue = try #require(await first(reading.observeShowDiagnostics(itemId: "rss:\(feedId)")))
    let diagnostics = try #require(diagnosticsValue)
    #expect(diagnostics.autoDownloadEpisodes == nil)
    #expect(diagnostics.lastEpisodeCheck == nil)
  }

  @Test func downloadingRowsCarryDeclaredSizeDeterminacySeparatelyFromProgress() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: "Show", author: nil)
    let url = URL(string: "https://example.com/e.mp3")!
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "known", enclosureURL: url, declaredBytes: 1_000),
        RSSEpisodeUpsert(identityKey: "unknown", enclosureURL: url),
      ])
    let ids = try await database.readAsync { db in
      try RSSEpisodeRecord.fetchAll(db, sql: "SELECT * FROM rssEpisode ORDER BY id")
        .map { (identityKey: $0.identityKey, id: try #require($0.id)) }
    }
    try await database.writeAsync { db in
      for episode in ids {
        try db.execute(
          sql:
            "INSERT INTO rssDownload (episodeId, state, relativePath, expectedBytes, actualBytes, origin, decidedStamp, createdAt, updatedAt) VALUES (?, 'downloading', 'x', ?, 0, 'manual', ?, ?, ?)",
          arguments: [
            episode.id, episode.identityKey == "known" ? 1_000 : nil, Date(), Date(), Date(),
          ])
      }
    }

    let rows = try #require(
      await first(RSSPodcastReading(database: database).observeEpisodes(itemId: "rss:\(feedId)")))
    let known = try #require(rows.first { $0.id == "known" })
    let unknown = try #require(rows.first { $0.id == "unknown" })
    #expect(known.downloadStatus == .downloading(progressFraction: 0))
    #expect(known.isDownloadSizeKnown)
    #expect(unknown.downloadStatus == .downloading(progressFraction: 0))
    #expect(unknown.isDownloadSizeKnown == false)
  }

  @Test("the episode list never re-emits on byte writes; the progress projection steps by quantum")
  func theEpisodeListNeverReEmitsOnByteWrites() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: "Show", author: nil)
    let downloadId = try await insertDownloadingEpisode(database, feedId: feedId, key: "quantum")
    let reading = RSSPodcastReading(database: database)
    let observations = PersistenceObservationCollector(
      reading.observeEpisodes(itemId: "rss:\(feedId)"))
    let progress = PersistenceObservationCollector(
      reading.observeEpisodeDownloadProgress(itemId: "rss:\(feedId)"))

    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    #expect(observations.values.first?.first?.downloadStatus == .downloading(progressFraction: 0))
    #expect(await TestSupport.waitUntil { progress.values.isEmpty == false })
    #expect(progress.values.first == ["quantum": 0])
    let listCount = observations.values.count
    let progressCount = progress.values.count

    // These stay inside the initial 2% bucket, so `removeDuplicates` suppresses them and the list
    // must not see them. Do not await a stream value here.
    try await updateDownloadBytes(database, id: downloadId, actualBytes: 1)
    try await updateDownloadBytes(database, id: downloadId, actualBytes: 2)
    try await updateDownloadBytes(database, id: downloadId, actualBytes: 41)

    #expect(await TestSupport.waitUntil { progress.contains { $0["quantum"] == 0.04 } })
    #expect(progress.values.count == progressCount + 1)
    #expect(observations.values.count == listCount)
    #expect(observations.values.last?.first?.downloadStatus == .downloading(progressFraction: 0))
  }

  @Test("the episode list floors playback position to the minute; the lookup keeps it exact")
  func theEpisodeListFloorsPlaybackPosition() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: "Show", author: nil)
    let url = URL(string: "https://example.com/e.mp3")!
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId, episodes: [RSSEpisodeUpsert(identityKey: "playing", enclosureURL: url)])
    let episodeID = try #require(try await id(database, feedId: feedId, key: "playing"))
    _ = try await RSSEpisodeStateStore(database: database).recordTick(
      episodeId: episodeID, position: 754.3, finished: false, capturedSequence: 0, now: Date())
    let reading = RSSPodcastReading(database: database)

    let listed = try #require(await first(reading.observeEpisodes(itemId: "rss:\(feedId)")))
    #expect(listed.first?.progressSeconds == 720)
    let prefix = try #require(reading.episodePrefix(itemId: "rss:\(feedId)", limit: 10))
    #expect(prefix.episodes.first?.progressSeconds == 720)
    let context = try #require(try await reading.episode(itemID: "rss:\(feedId)", episodeID: "playing"))
    #expect(context.episode.progressSeconds == 754.3)
  }

  @Test("a checkpoint inside the listed minute does not re-emit the episode list")
  func aCheckpointInsideTheListedMinuteDoesNotReEmit() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: "Show", author: nil)
    let url = URL(string: "https://example.com/e.mp3")!
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId, episodes: [RSSEpisodeUpsert(identityKey: "playing", enclosureURL: url)])
    let episodeID = try #require(try await id(database, feedId: feedId, key: "playing"))
    let state = RSSEpisodeStateStore(database: database)
    _ = try await state.recordTick(
      episodeId: episodeID, position: 600, finished: false, capturedSequence: 0, now: Date())
    let observations = PersistenceObservationCollector(
      RSSPodcastReading(database: database).observeEpisodes(itemId: "rss:\(feedId)"))
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let countAfterInitial = observations.values.count

    // Three 15 s checkpoints inside the same listed minute, then one past it, which proves the
    // earlier writes were dropped rather than merely not yet delivered.
    for (sequence, position) in [615.0, 630, 645, 660].enumerated() {
      _ = try await state.recordTick(
        episodeId: episodeID, position: position, finished: false,
        capturedSequence: Int64(sequence + 1), now: Date())
    }

    #expect(await TestSupport.waitUntil { observations.values.last?.first?.progressSeconds == 660 })
    #expect(observations.values.count == countAfterInitial + 1)
  }

  @Test("the progress projection only carries downloading rows with a known total")
  func theProgressProjectionOnlyCarriesDownloadingRowsWithAKnownTotal() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: "Show", author: nil)
    let url = URL(string: "https://example.com/e.mp3")!
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "known", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "unknown", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "completed", enclosureURL: url),
      ])
    let rows: [(key: String, state: String, expected: Int64?, actual: Int64)] = [
      ("known", "downloading", 1_000, 500),
      ("unknown", "downloading", nil, 500),
      ("completed", "completed", 1_000, 1_000),
    ]
    for row in rows {
      let episodeId = try #require(try await id(database, feedId: feedId, key: row.key))
      try await database.writeAsync { db in
        try db.execute(
          sql: """
            INSERT INTO rssDownload
              (episodeId, state, relativePath, expectedBytes, actualBytes, origin, decidedStamp, createdAt, updatedAt)
            VALUES (?, ?, 'e.mp3', ?, ?, 'manual', ?, ?, ?)
            """,
          arguments: [episodeId, row.state, row.expected, row.actual, Date(), Date(), Date()])
      }
    }

    let progress = try #require(
      await first(RSSPodcastReading(database: database).observeEpisodeDownloadProgress(itemId: "rss:\(feedId)")))

    #expect(progress == ["known": 0.5])
    #expect(
      try #require(await first(RSSPodcastReading(database: database).observeEpisodeDownloadProgress(itemId: "rss:abc")))
        .isEmpty)
  }

  @Test("an unrelated write to a tracked table does not re-emit an unchanged list")
  func anUnrelatedWriteDoesNotReEmitAnUnchangedList() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: "Show", author: nil)
    let otherFeedId = try await subscribe(database, title: "Other", author: nil)
    let url = URL(string: "https://example.com/e.mp3")!
    let store = RSSEpisodeStore(database: database)
    _ = try await store.applyRefresh(
      feedId: feedId, episodes: [RSSEpisodeUpsert(identityKey: "mine", enclosureURL: url)])
    let observations = PersistenceObservationCollector(
      RSSPodcastReading(database: database).observeEpisodes(itemId: "rss:\(feedId)"))
    #expect(await TestSupport.waitUntil { observations.values.isEmpty == false })
    let countAfterInitial = observations.values.count

    // Another feed's refresh touches `rssEpisode` and `rssFeed`, both tracked by this query.
    _ = try await store.applyRefresh(
      feedId: otherFeedId, episodes: [RSSEpisodeUpsert(identityKey: "theirs", enclosureURL: url)])
    // A change this list does show, to prove the earlier write was skipped rather than not yet
    // delivered.
    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "mine", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "newer", enclosureURL: url),
      ])

    #expect(await TestSupport.waitUntil { observations.values.last?.count == 2 })
    #expect(observations.values.count == countAfterInitial + 1)
  }

  @Test("the explicit episode lookup keeps exact download progress")
  func theExplicitEpisodeLookupKeepsExactProgress() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: "Show", author: nil)
    let downloadId = try await insertDownloadingEpisode(database, feedId: feedId, key: "exact")
    try await updateDownloadBytes(database, id: downloadId, actualBytes: 37)
    let reading = RSSPodcastReading(database: database)

    let context = try #require(try await reading.episode(itemID: "rss:\(feedId)", episodeID: "exact"))
    #expect(context.episode.downloadStatus == .downloading(progressFraction: 0.037))
    let listed = try #require(await first(reading.observeEpisodes(itemId: "rss:\(feedId)")))
    #expect(listed.first?.downloadStatus == .downloading(progressFraction: 0))
    let progress = try #require(await first(reading.observeEpisodeDownloadProgress(itemId: "rss:\(feedId)")))
    #expect(progress == ["exact": 0.02])
  }

  @Test("the list ships the stored line and never the description; the lookup ships both")
  func theListShipsTheStoredLineAndTheLookupShipsBoth() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: "Show", author: nil)
    let url = URL(string: "https://example.com/e.mp3")!
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "lined", synopsis: "<p>Full &amp; long</p>", synopsisLine: "Full & long",
          enclosureURL: url),
        // A row written before v55, or by a refresh that found no description.
        RSSEpisodeUpsert(identityKey: "unlined", synopsis: "<p>Not yet</p>", enclosureURL: url),
      ])
    let reading = RSSPodcastReading(database: database)

    let listed = try #require(await first(reading.observeEpisodes(itemId: "rss:\(feedId)")))
    #expect(listed.map(\.id) == ["lined", "unlined"])
    #expect(listed.map(\.episodeDescription) == [nil, nil])
    #expect(listed.map(\.synopsisLine) == ["Full & long", nil])

    let looked = try #require(
      try await reading.episode(itemID: "rss:\(feedId)", episodeID: "lined"))
    #expect(looked.episode.episodeDescription == "<p>Full &amp; long</p>")
    #expect(looked.episode.synopsisLine == "Full & long")
  }

  @Test func equalPublicationDatesBreakByRowIdAscending() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: nil, author: nil)
    let url = URL(string: "https://example.com/e.mp3")!
    let sameDate = Date(timeIntervalSince1970: 50)
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "a", enclosureURL: url, publishedAt: sameDate),
        RSSEpisodeUpsert(identityKey: "b", enclosureURL: url, publishedAt: sameDate),
      ])
    // applyRefresh inserts in input order, so "a" holds the lower row id.
    let reading = RSSPodcastReading(database: database)
    let summaries = try #require(await first(reading.observeEpisodes(itemId: "rss:\(feedId)")))
    #expect(summaries.map(\.id) == ["a", "b"])
  }

  @Test func theEpisodeObservationTracksLaterRefreshes() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await subscribe(database, title: "Live", author: nil)
    let url = URL(string: "https://example.com/e.mp3")!
    let reading = RSSPodcastReading(database: database)
    var iterator = reading.observeEpisodes(itemId: "rss:\(feedId)").makeAsyncIterator()
    #expect(await iterator.next() == [])
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId, episodes: [RSSEpisodeUpsert(identityKey: "fresh", enclosureURL: url)])
    let next = try #require(await iterator.next())
    #expect(next.map(\.id) == ["fresh"])
  }

  @Test func mapsRSSShowsIncludingSparseFields() async throws {
    let database = try AppDatabase.inMemory()
    let subscribedAt = Date(timeIntervalSince1970: 10)
    let firstID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/first.xml")!, title: "First", author: "Author",
      synopsis: "Synopsis", artworkURL: URL(string: "https://images.example.com/first.jpg"),
      subscribedAt: subscribedAt)
    let secondID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/second.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date(timeIntervalSince1970: 20))

    let rows = try #require(await first(RSSPodcastReading(database: database).observeShows())).shows
    let full = try #require(rows.first(where: { $0.serverItemId == "rss:\(firstID)" }))
    #expect(full.serverItemId == "rss:\(firstID)")
    #expect(full.mediaKind == "podcast")
    #expect(full.title == "First")
    #expect(full.author == "Author")
    #expect(full.durationSeconds == nil)
    #expect(full.progressSeconds == 0)
    #expect(full.category == .podcast)
    #expect(!full.hasReadableEbook)
    #expect(full.addedAt == subscribedAt)
    #expect(full.seriesName == nil)
    #expect(full.narratorName == nil)
    #expect(full.expandedMetadataFetchedAt == nil)
    #expect(full.itemDescription == "Synopsis")
    #expect(full.artworkURL == URL(string: "https://images.example.com/first.jpg"))
    #expect(full.artworkFeedURL == URL(string: "https://example.com/first.xml"))
    let sparse = try #require(rows.first(where: { $0.serverItemId == "rss:\(secondID)" }))
    #expect(sparse.title == "")
    #expect(sparse.author == nil)
    #expect(sparse.itemDescription == nil)
  }

  @Test func singleShowObservationMatchesListProjectionAndTracksMetadata() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let feedID = try await store.subscribe(
      feedURL: URL(string: "https://example.com/live.xml")!, title: "Before", author: "Author",
      synopsis: "Old synopsis", artworkURL: URL(string: "https://images.example.com/before.jpg"),
      subscribedAt: Date(timeIntervalSince1970: 10))
    let reading = RSSPodcastReading(database: database)
    let itemID = "rss:\(feedID)"

    let listSnapshot = try #require(await first(reading.observeShows()))
    let listSummary = try #require(listSnapshot.shows.first)
    let singleSummary = try #require(await first(reading.observeShow(itemId: itemID)) ?? nil)
    #expect(singleSummary == listSummary)

    var iterator = reading.observeShow(itemId: itemID).makeAsyncIterator()
    _ = try #require(await iterator.next())
    try await store.applyChannelMetadata(
      feedId: feedID, title: "After", author: "New Author", synopsis: "New synopsis", language: nil,
      artworkURL: URL(string: "https://images.example.com/after.jpg"),
      refreshedAt: Date(timeIntervalSince1970: 20))

    let updated = try #require(await iterator.next() ?? nil)
    let updatedListSnapshot = try #require(await first(reading.observeShows()))
    let updatedList = try #require(updatedListSnapshot.shows.first)
    #expect(updated == updatedList)
    #expect(updated.title == "After")
    #expect(updated.author == "New Author")
    #expect(updated.artworkURL == URL(string: "https://images.example.com/after.jpg"))
  }

  @Test func ordersRSSShowsBySelectedMode() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let firstID = try await store.subscribe(
      feedURL: URL(string: "https://example.com/one.xml")!, title: "alpha", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let second = try await store.subscribe(
      feedURL: URL(string: "https://example.com/two.xml")!, title: "Alpha", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let third = try await store.subscribe(
      feedURL: URL(string: "https://example.com/three.xml")!, title: "zulu", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let fourth = try await store.subscribe(
      feedURL: URL(string: "https://example.com/four.xml")!, title: "No Episodes", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let url = URL(string: "https://example.com/episode.mp3")!
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: firstID,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "first", enclosureURL: url,
          publishedAt: Date(timeIntervalSince1970: 100))
      ])
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: second,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "second", enclosureURL: url,
          publishedAt: Date(timeIntervalSince1970: 100))
      ])
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: third,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "third", enclosureURL: url,
          publishedAt: Date(timeIntervalSince1970: 50))
      ])

    let reading = RSSPodcastReading(database: database)
    let alphabetical = try #require(await first(reading.observeShows()))
    #expect(alphabetical.mode == .alphabetical)
    #expect(
      alphabetical.shows.map(\.serverItemId)
        == ["rss:\(firstID)", "rss:\(second)", "rss:\(fourth)", "rss:\(third)"])

    try await store.setSortMode(.mostRecent)
    let mostRecent = try #require(await first(reading.observeShows()))
    #expect(mostRecent.mode == .mostRecent)
    #expect(
      mostRecent.shows.map(\.serverItemId)
        == ["rss:\(firstID)", "rss:\(second)", "rss:\(third)", "rss:\(fourth)"])

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE rssFeed SET customSortIndex = 1 WHERE id = ?", arguments: [firstID])
      try db.execute(sql: "UPDATE rssFeed SET customSortIndex = 0 WHERE id = ?", arguments: [third])
    }
    try await store.setSortMode(.custom)
    let custom = try #require(await first(reading.observeShows()))
    #expect(custom.mode == .custom)
    #expect(
      custom.shows.map(\.serverItemId)
        == ["rss:\(third)", "rss:\(firstID)", "rss:\(second)", "rss:\(fourth)"])
  }

  @Test func observesRSSShowSubscribeAndUnsubscribe() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let reading = RSSPodcastReading(database: database)
    var iterator = reading.observeShows().makeAsyncIterator()
    #expect(await iterator.next()?.shows == [])
    let feedID = try await store.subscribe(
      feedURL: URL(string: "https://example.com/live.xml")!, title: "Live", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    #expect((try #require(await iterator.next())).shows.map(\.serverItemId) == ["rss:\(feedID)"])
    try await store.unsubscribe(feedId: feedID)
    #expect((try #require(await iterator.next())).shows.isEmpty)
  }

  @Test func readsRSSShowDiagnosticsAndSettingsOverrides() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await subscribe(database, title: "Show", author: nil)
    let refreshedAt = Date(timeIntervalSince1970: 100)
    try await RSSFeedStore(database: database).applyChannelMetadata(
      feedId: feedID, title: "Show", author: nil, synopsis: nil, language: nil, artworkURL: nil,
      refreshedAt: refreshedAt)
    let reading = RSSPodcastReading(database: database)
    let initialDiagnostics = try #require(await first(reading.observeShowDiagnostics(itemId: "rss:\(feedID)")))
    var diagnostics = try #require(initialDiagnostics)
    #expect(diagnostics.autoDownloadEpisodes == nil)
    #expect(diagnostics.autoDownloadSchedule == nil)
    #expect(diagnostics.lastEpisodeCheck == refreshedAt)
    #expect(diagnostics.maxEpisodesToKeep == nil)
    #expect(diagnostics.maxNewEpisodesToDownload == nil)

    let settings = RSSFeedSettingsStore(database: database)
    try await settings.updateSettings(
      feedId: feedID, autoDownload: .enabled, keepLatest: 0, deleteAfterPlayed: nil,
      rateStep: nil, includeInLatest: true)
    let enabledDiagnostics = try #require(await first(reading.observeShowDiagnostics(itemId: "rss:\(feedID)")))
    diagnostics = try #require(enabledDiagnostics)
    #expect(diagnostics.autoDownloadEpisodes == true)
    #expect(diagnostics.maxEpisodesToKeep == 0)
    try await settings.updateSettings(
      feedId: feedID, autoDownload: .disabled, keepLatest: nil, deleteAfterPlayed: nil,
      rateStep: nil, includeInLatest: true)
    let disabledDiagnostics = try #require(await first(reading.observeShowDiagnostics(itemId: "rss:\(feedID)")))
    #expect(try #require(disabledDiagnostics).autoDownloadEpisodes == false)
    try await settings.updateSettings(
      feedId: feedID, autoDownload: .inherit, keepLatest: nil, deleteAfterPlayed: nil,
      rateStep: nil, includeInLatest: true)
    let inheritedDiagnostics = try #require(await first(reading.observeShowDiagnostics(itemId: "rss:\(feedID)")))
    #expect(try #require(inheritedDiagnostics).autoDownloadEpisodes == nil)
  }

  @Test func observesRSSDiagnosticsRefreshesAndRejectsUnknownIds() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await subscribe(database, title: "Show", author: nil)
    let reading = RSSPodcastReading(database: database)
    for itemID in ["abs-item-1", "rss:", "rss:0", "rss:abc", "rss:999999"] {
      #expect(try #require(await first(reading.observeShowDiagnostics(itemId: itemID))) == nil)
    }
    var iterator = reading.observeShowDiagnostics(itemId: "rss:\(feedID)").makeAsyncIterator()
    let initialDiagnostics = try #require(await iterator.next())
    #expect(try #require(initialDiagnostics).lastEpisodeCheck == nil)
    let refreshedAt = Date(timeIntervalSince1970: 200)
    try await RSSFeedStore(database: database).applyChannelMetadata(
      feedId: feedID, title: "Show", author: nil, synopsis: nil, language: nil, artworkURL: nil,
      refreshedAt: refreshedAt)
    let refreshedDiagnostics = try #require(await iterator.next())
    #expect(try #require(refreshedDiagnostics).lastEpisodeCheck == refreshedAt)
  }

  private func subscribe(_ database: AppDatabase, title: String?, author: String?) async throws -> Int64 {
    try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/\(UUID().uuidString).xml")!, title: title,
      author: author, synopsis: nil, artworkURL: nil, subscribedAt: Date())
  }

  /// One episode with a `downloading` row of 1,000 expected bytes and nothing received yet.
  private func insertDownloadingEpisode(
    _ database: AppDatabase, feedId: Int64, key: String
  ) async throws -> Int64 {
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: key, enclosureURL: URL(string: "https://example.com/e.mp3")!)
      ])
    let episodeId = try #require(try await id(database, feedId: feedId, key: key))
    return try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO rssDownload
            (episodeId, state, relativePath, expectedBytes, actualBytes, origin, decidedStamp, createdAt, updatedAt)
          VALUES (?, 'downloading', 'e.mp3', 1000, 0, 'manual', ?, ?, ?)
          """,
        arguments: [episodeId, Date(), Date(), Date()])
      return db.lastInsertedRowID
    }
  }

  private func updateDownloadBytes(_ database: AppDatabase, id: Int64, actualBytes: Int64) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssDownload SET actualBytes = ?, updatedAt = ? WHERE id = ?",
        arguments: [actualBytes, Date(), id])
    }
  }

  private func id(_ database: AppDatabase, feedId: Int64, key: String) async throws -> Int64? {
    try await database.readAsync { db in
      try Int64.fetchOne(
        db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
        arguments: [feedId, key])
    }
  }

  private func first<T: Sendable>(_ stream: AsyncStream<T>) async -> T? {
    for await value in stream { return value }
    return nil
  }
}
