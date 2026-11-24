import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct RSSEpisodeStoreTests {
  @Test func insertsAndUpdatesInPlaceWhilePreservingState() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedId = try await feedStore.subscribe(
      feedURL: URL(string: "https://example.com/feed.xml")!, title: "Feed", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let store = RSSEpisodeStore(database: database)
    let url = URL(string: "https://example.com/episode.mp3")!

    let firstGeneration = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "guid:one", alternateIdentityKey: "sha256:one", guid: "one",
          title: "Title", synopsis: "Synopsis", enclosureURL: url, declaredBytes: 42,
          durationSeconds: 12, seasonNumber: 1, episodeNumber: 2)
      ])
    #expect(firstGeneration == 1)
    let episodeId = try #require(try await episodeID(database, feedId: feedId, key: "guid:one"))
    try await database.writeAsync { db in
      try db.execute(
        sql: "INSERT INTO rssEpisodeState (episodeId, position, localSequence, updatedAt) VALUES (?, ?, ?, ?)",
        arguments: [episodeId, 3.5, 1, Date()])
    }

    let secondGeneration = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "guid:one", alternateIdentityKey: "sha256:one", guid: "one-new",
          title: "Updated", synopsis: nil, enclosureURL: url)
      ])
    #expect(secondGeneration == 2)
    let row = try #require(
      try await database.readAsync { db in
        try RSSEpisodeRecord.fetchOne(db, key: episodeId)
      })
    #expect(row.id == episodeId)
    #expect(row.title == "Updated")
    #expect(row.synopsis == nil)
    #expect(row.guid == "one-new")
    #expect(row.lastSeenGeneration == 2)
    #expect(
      try await database.readAsync { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssEpisodeState WHERE episodeId = ?", arguments: [episodeId])
      } == 1)
  }

  @Test func rekeysThroughAlternateIdentityAndDeduplicatesInput() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedId = try await feedStore.subscribe(
      feedURL: URL(string: "https://example.com/feed.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let store = RSSEpisodeStore(database: database)
    let url = URL(string: "https://example.com/e.mp3")!
    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "sha256:e", alternateIdentityKey: nil, enclosureURL: url)
      ])
    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "guid:e", alternateIdentityKey: "sha256:e", guid: "e", title: "first", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "guid:e", guid: "e", title: "second", enclosureURL: url),
      ])
    let rows = try await database.readAsync { db in
      try RSSEpisodeRecord.fetchAll(db, sql: "SELECT * FROM rssEpisode WHERE feedId = ?", arguments: [feedId])
    }
    #expect(rows.count == 1)
    #expect(rows[0].identityKey == "guid:e")
    #expect(rows[0].title == "first")
  }

  @Test func measuredDurationSurvivesRefreshAndNewRowsStartWithoutOne() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/measured.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let store = RSSEpisodeStore(database: database)
    let enclosureURL = URL(string: "https://example.com/episode.mp3")!

    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [RSSEpisodeUpsert(identityKey: "guid:existing", enclosureURL: enclosureURL)])
    let existingID = try #require(
      try await episodeID(database, feedId: feedId, key: "guid:existing"))
    try await store.recordMeasuredDuration(episodeId: existingID, seconds: 321.5)

    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "guid:existing", enclosureURL: enclosureURL),
        RSSEpisodeUpsert(identityKey: "guid:new", enclosureURL: enclosureURL),
      ])

    let rows = try await database.readAsync { db in
      try RSSEpisodeRecord.fetchAll(
        db, sql: "SELECT * FROM rssEpisode WHERE feedId = ? ORDER BY id", arguments: [feedId])
    }
    #expect(rows.count == 2)
    #expect(rows[0].id == existingID)
    #expect(rows[0].durationSeconds == nil)
    #expect(rows[0].measuredDurationSeconds == 321.5)
    #expect(rows[1].measuredDurationSeconds == nil)
  }

  @Test func measuredDurationRejectsInvalidAndUnknownValuesWithoutWriting() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/invalid-measured.xml")!, title: nil,
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let store = RSSEpisodeStore(database: database)
    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "guid:one", enclosureURL: URL(string: "https://example.com/one.mp3")!)
      ])
    let episodeID = try #require(
      try await episodeID(database, feedId: feedId, key: "guid:one"))

    for value in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
      try await store.recordMeasuredDuration(episodeId: episodeID, seconds: value)
    }
    try await store.recordMeasuredDuration(episodeId: 999_999, seconds: 12)

    let duration = try await store.fetchEpisode(episodeId: episodeID)?.measuredDurationSeconds
    #expect(duration == nil)
  }

  @Test func credentialBearingEnclosureIsRefusedAtPersistenceBoundary() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/credentialed.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let store = RSSEpisodeStore(database: database)
    let credentialedURL = URL(string: "https://user:password@example.com/episode.mp3")!

    await #expect(throws: RSSEpisodeStoreError.credentialedEnclosureURL) {
      try await store.applyRefresh(
        feedId: feedID,
        episodes: [RSSEpisodeUpsert(identityKey: "credentialed", enclosureURL: credentialedURL)])
    }

    #expect(try await store.fetchEpisode(feedId: feedID, identityKey: "credentialed") == nil)
    #expect(
      try await database.readAsync { db in
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM rssEpisode WHERE feedId = ?", arguments: [feedID])
      } == 0)
  }

  @Test func absorbsGUIDRemovalAndChangeAndKeepsAbsentEpisodes() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedId = try await feedStore.subscribe(
      feedURL: URL(string: "https://example.com/feed.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let store = RSSEpisodeStore(database: database)
    let url = URL(string: "https://example.com/e.mp3")!

    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "guid:old", alternateIdentityKey: "sha256:one", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "guid:gone", alternateIdentityKey: "sha256:two", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "sha256:three", enclosureURL: url),
      ])
    let changedId = try #require(try await episodeID(database, feedId: feedId, key: "guid:old"))
    let removedId = try #require(try await episodeID(database, feedId: feedId, key: "guid:gone"))
    let absentId = try #require(try await episodeID(database, feedId: feedId, key: "sha256:three"))

    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "guid:new", alternateIdentityKey: "sha256:one", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "sha256:two", enclosureURL: url),
      ])

    let rows = try await database.readAsync { db in
      try RSSEpisodeRecord.fetchAll(
        db, sql: "SELECT * FROM rssEpisode WHERE feedId = ? ORDER BY id", arguments: [feedId])
    }
    #expect(rows.count == 3)
    let changed = try #require(rows.first { $0.id == changedId })
    #expect(changed.identityKey == "guid:new")
    #expect(changed.lastSeenGeneration == 2)
    let unGuided = try #require(rows.first { $0.id == removedId })
    #expect(unGuided.identityKey == "sha256:two")
    #expect(unGuided.alternateIdentityKey == nil)
    #expect(unGuided.lastSeenGeneration == 2)
    let absent = try #require(rows.first { $0.id == absentId })
    #expect(absent.identityKey == "sha256:three")
    #expect(absent.lastSeenGeneration == 1)
  }

  @Test func unknownFeedThrowsAndFeedsAreIndependent() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let first = try await feedStore.subscribe(
      feedURL: URL(string: "https://example.com/one.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let second = try await feedStore.subscribe(
      feedURL: URL(string: "https://example.com/two.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let store = RSSEpisodeStore(database: database)
    let episode = RSSEpisodeUpsert(
      identityKey: "same", enclosureURL: URL(string: "https://example.com/e")!)
    _ = try await store.applyRefresh(feedId: first, episodes: [episode])
    _ = try await store.applyRefresh(feedId: second, episodes: [episode])
    await #expect(throws: RSSEpisodeStoreError.feedNotFound) {
      try await store.applyRefresh(feedId: 999, episodes: [])
    }
    #expect(
      try await database.readAsync { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssEpisode WHERE identityKey = ?", arguments: ["same"])
      } == 2)
  }

  @Test func sweepsDroppedEpisodesByHistoryAndKeepsCurrentEpisodes() async throws {
    let database = try AppDatabase.inMemory()
    let feedStore = RSSFeedStore(database: database)
    let feedId = try await feedStore.subscribe(
      feedURL: URL(string: "https://example.com/sweep.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let store = RSSEpisodeStore(database: database)
    let url = URL(string: "https://example.com/episode.mp3")!

    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "delete", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "zero", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "saved", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "bookmark", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "dismissed", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "position", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "finished", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "download", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "current", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "retained", enclosureURL: url),
      ])
    let ids = try await episodeIDs(database, feedId: feedId)
    try await database.writeAsync { db in
      try insertState(db, episodeId: ids["zero"]!, position: 0, finished: false)
      try RSSEpisodeStateRecord(
        episodeId: ids["dismissed"]!, position: 0, finished: false,
        hideFromContinueListening: true, localSequence: 1, updatedAt: Date()
      ).insert(db)
      _ = try RSSSavedShelfEntryRecord(rssEpisodeId: ids["saved"]!, savedAt: Date()).inserted(db)
      try db.execute(
        sql: "INSERT INTO rssPlaybackBookmark (id, episodeId, updatedAt) VALUES (0, ?, ?)",
        arguments: [ids["bookmark"]!, Date()])
      try insertState(db, episodeId: ids["position"]!, position: 1, finished: false)
      try insertState(db, episodeId: ids["finished"]!, position: 0, finished: true)
      try insertDownload(db, episodeID: ids["download"]!)
      try db.execute(
        sql: "UPDATE rssEpisode SET retained = 1 WHERE id = ?", arguments: [ids["retained"]!])
    }

    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [RSSEpisodeUpsert(identityKey: "current", enclosureURL: url)])
    let firstSweep = try await store.sweepDroppedEpisodes(feedId: feedId)
    #expect(firstSweep.deleted == 1)
    #expect(firstSweep.newlyRetained == 7)
    let firstCounts = try await database.readAsync { db in
      try [
        "delete": Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM rssEpisode WHERE identityKey = ?", arguments: ["delete"])!,
        "deleteState": Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM rssEpisodeState WHERE episodeId = ?", arguments: [ids["delete"]!])!,
        "positionState": Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM rssEpisodeState WHERE episodeId = ?", arguments: [ids["position"]!])!,
        "current": Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM rssEpisode WHERE identityKey = ?", arguments: ["current"])!,
      ]
    }
    #expect(firstCounts["delete"] == 0)
    #expect(firstCounts["deleteState"] == 0)
    #expect(firstCounts["positionState"] == 1)
    #expect(firstCounts["current"] == 1)

    let retainedKeys = try await database.readAsync { db in
      try String.fetchAll(db, sql: "SELECT identityKey FROM rssEpisode WHERE retained = 1 ORDER BY identityKey")
    }
    #expect(Set(retainedKeys).isSuperset(of: ["zero", "saved", "bookmark", "dismissed"]))

    let secondSweep = try await store.sweepDroppedEpisodes(feedId: feedId)
    #expect(secondSweep.deleted == 0)
    #expect(secondSweep.newlyRetained == 0)
    await #expect(throws: RSSEpisodeStoreError.feedNotFound) {
      try await store.sweepDroppedEpisodes(feedId: 999)
    }

    let untouchedDatabase = try AppDatabase.inMemory()
    let untouchedFeedId = try await RSSFeedStore(database: untouchedDatabase).subscribe(
      feedURL: URL(string: "https://example.com/unrefreshed.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let untouchedSweep = try await RSSEpisodeStore(database: untouchedDatabase)
      .sweepDroppedEpisodes(feedId: untouchedFeedId)
    #expect(untouchedSweep.deleted == 0)
    #expect(untouchedSweep.newlyRetained == 0)
  }

  @Test func episodeArtworkIsFeedOwnedAndRewrittenByEveryRefresh() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/feed.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let store = RSSEpisodeStore(database: database)
    let url = URL(string: "https://example.com/episode.mp3")!
    let first = URL(string: "https://example.com/art-one.jpg")!
    let second = URL(string: "https://example.com/art-two.jpg")!

    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "guid:one", enclosureURL: url, artworkURL: first)
      ])
    let episodeId = try #require(try await episodeID(database, feedId: feedId, key: "guid:one"))
    func storedArtwork() async throws -> String? {
      try await database.readAsync { db in
        try RSSEpisodeRecord.fetchOne(db, key: episodeId)?.artworkURL
      }
    }
    #expect(try await storedArtwork() == first.absoluteString)

    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "guid:one", enclosureURL: url, artworkURL: second)
      ])
    #expect(try await storedArtwork() == second.absoluteString)

    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "guid:one", enclosureURL: url)
      ])
    #expect(try await storedArtwork() == nil)
  }

  /// A copy the Watch is owed pins its episode row: the prune must retain it. A row
  /// the phone already removed holds nothing, so it is pruned with the rest.
  @Test func anEpisodeHeldForTheWatchIsRetainedByThePrune() async throws {
    let database = try AppDatabase.inMemory()
    let feedId = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/watch-feed.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let store = RSSEpisodeStore(database: database)
    let url = URL(string: "https://example.com/episode.mp3")!
    _ = try await store.applyRefresh(
      feedId: feedId,
      episodes: [
        RSSEpisodeUpsert(identityKey: "guid:held", enclosureURL: url),
        RSSEpisodeUpsert(identityKey: "guid:removed", enclosureURL: url),
      ])
    let ids = try await episodeIDs(database, feedId: feedId)
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO rssWatchCopy (episodeId, revision, state, removedBy, requestedAt, updatedAt)
          VALUES (?, 1, 'wanted', NULL, ?, ?), (?, 1, 'removed', 'phone', ?, ?)
          """,
        arguments: [
          ids["guid:held"]!, Date(), Date(),
          ids["guid:removed"]!, Date(), Date(),
        ])
    }

    _ = try await store.applyRefresh(feedId: feedId, episodes: [])
    let sweep = try await store.sweepDroppedEpisodes(feedId: feedId)

    #expect(sweep.deleted == 1)
    #expect(sweep.newlyRetained == 1)
    let remaining = try await database.readAsync { db in
      try String.fetchAll(db, sql: "SELECT identityKey FROM rssEpisode WHERE feedId = ?", arguments: [feedId])
    }
    #expect(remaining == ["guid:held"])
  }

  private func episodeIDs(_ database: AppDatabase, feedId: Int64) async throws -> [String: Int64] {
    try await database.readAsync { db in
      let rows = try Row.fetchAll(
        db, sql: "SELECT identityKey, id FROM rssEpisode WHERE feedId = ?", arguments: [feedId])
      return Dictionary(uniqueKeysWithValues: rows.map { ($0["identityKey"], $0["id"]) })
    }
  }

  private func insertState(
    _ db: Database, episodeId: Int64, position: Double, finished: Bool
  ) throws {
    try db.execute(
      sql:
        "INSERT INTO rssEpisodeState (episodeId, position, finished, localSequence, updatedAt) VALUES (?, ?, ?, ?, ?)",
      arguments: [episodeId, position, finished, 1, Date()])
  }

  private func insertDownload(_ db: Database, episodeID: Int64) throws {
    try db.execute(
      sql:
        "INSERT INTO rssDownload (episodeId, state, relativePath, origin, decidedStamp, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)",
      arguments: [episodeID, "pending", "RSS/file.mp3", "manual", Date(), Date(), Date()])
  }

  private func episodeID(_ database: AppDatabase, feedId: Int64, key: String) async throws -> Int64? {
    try await database.readAsync { db in
      try Int64.fetchOne(
        db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
        arguments: [feedId, key])
    }
  }
}
