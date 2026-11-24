import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite("Native feed recovery persistence")
struct RSSFeedRecoveryTests {
  @Test func recoveryProjectionTracksMarkerInsertionAndClear() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    var observations = store.observeRecoveryFeedIDs().makeAsyncIterator()
    #expect(await observations.next() == [])

    let feedID = try await store.subscribe(
      feedURL: URL(string: "https://example.test/observed.xml")!, title: "Observed",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date(),
      recoveryReason: .credentialStorageFailed)
    #expect(await observations.next() == [feedID])

    try await store.clearRecovery(feedId: feedID)
    #expect(await observations.next() == [])
  }

  @Test func markerContainsOnlyFixedRecoveryMetadataAndCascadesWithFeed() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let feedID = try await store.subscribe(
      feedURL: URL(string: "https://example.test/feed.xml")!, title: "Feed", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: createdAt,
      recoveryReason: .credentialStorageFailed)

    let columns = try database.read { db in try db.columns(in: "rssFeedRecovery").map(\.name) }
    let record = try await database.readAsync { db in
      try RSSFeedRecoveryRecord.fetchOne(db, key: feedID)
    }
    #expect(columns == ["feedId", "reason", "createdAt"])
    #expect(
      record
        == RSSFeedRecoveryRecord(
          feedId: feedID, reason: .credentialStorageFailed, createdAt: createdAt))
    #expect(throws: DatabaseError.self) {
      try database.write { db in
        try db.execute(
          sql: "UPDATE rssFeedRecovery SET reason = ? WHERE feedId = ?",
          arguments: ["unexpectedReason", feedID])
      }
    }

    try await store.unsubscribe(feedId: feedID)
    #expect(try await store.recoveryRequired(feedID: feedID) == false)
  }

  @Test func markerSurvivesReopenUntilAnIdempotentClear() async throws {
    try await withOnDiskDatabases { scope in
      let url = scope.url()
      let first = try scope.open(at: url)
      let feedID = try await RSSFeedStore(database: first).subscribe(
        feedURL: URL(string: "https://example.test/private.xml")!, title: "Private",
        author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date(),
        recoveryReason: .credentialStorageFailed)
      scope.close(first)

      let relaunched = try scope.open(at: url)
      let store = RSSFeedStore(database: relaunched)
      #expect(try await store.recoveryRequired(feedID: feedID))
      try await store.clearRecovery(feedId: feedID)
      try await store.clearRecovery(feedId: feedID)
      #expect(try await store.recoveryRequired(feedID: feedID) == false)
    }
  }

  @Test func markedFeedsStayVisibleButLeaveRefreshCandidatesUntilCleared() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let ordinary = try await store.subscribe(
      feedURL: URL(string: "https://example.test/ordinary.xml")!, title: "Ordinary",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let marked = try await store.subscribe(
      feedURL: URL(string: "https://example.test/marked.xml")!, title: "Marked",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date(),
      recoveryReason: .credentialStorageFailed)

    #expect(Set(try await store.fetchFeeds().compactMap(\.id)) == [ordinary, marked])
    #expect(try await store.fetchRefreshableFeedIDs() == [ordinary])

    try await store.clearRecovery(feedId: marked)
    #expect(try await store.fetchRefreshableFeedIDs() == [ordinary, marked])
  }

  /// A bounded pass takes a prefix of this list, so the order decides which feeds a pass reaches.
  /// Ordering by attempt rather than success is what moves a feed that always fails out of the way.
  @Test func refreshCandidatesStartFromTheLeastRecentlyAttemptedFeed() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    var ids: [Int64] = []
    for name in ["recent", "older", "never", "alsoNever", "tieStale", "tieFresh"] {
      ids.append(
        try await store.subscribe(
          feedURL: URL(string: "https://example.test/\(name).xml")!, title: name,
          author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date()))
    }
    let (recent, older, never, alsoNever) = (ids[0], ids[1], ids[2], ids[3])
    let (tieStale, tieFresh) = (ids[4], ids[5])
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    try await store.recordRefreshAttempt(feedID: recent, at: now)
    try await store.recordRefreshAttempt(feedID: older, at: now.addingTimeInterval(-3600))
    for feedID in [tieStale, tieFresh] {
      try await store.recordRefreshAttempt(feedID: feedID, at: now.addingTimeInterval(-1800))
    }
    try await database.writeAsync { db in
      // A newer success must not move a feed ahead of one attempted earlier; it only breaks ties.
      try db.execute(
        sql: "UPDATE rssFeed SET lastRefreshedAt = ? WHERE id = ?",
        arguments: [now.addingTimeInterval(-7200), recent])
      try db.execute(
        sql: "UPDATE rssFeed SET lastRefreshedAt = ? WHERE id = ?",
        arguments: [now.addingTimeInterval(-60), tieFresh])
      try db.execute(
        sql: "UPDATE rssFeed SET lastRefreshedAt = ? WHERE id = ?",
        arguments: [now.addingTimeInterval(-86_400), tieStale])
    }

    #expect(
      try await store.fetchRefreshableFeedIDs()
        == [never, alsoNever, older, tieStale, tieFresh, recent])
  }

  /// The attempt stamp orders candidates only. "Last episode check" and `refreshIfStale` keep
  /// reading the last success.
  @Test func recordingAnAttemptLeavesTheLastSuccessAlone() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let feedID = try await store.subscribe(
      feedURL: URL(string: "https://example.test/show.xml")!, title: "Show",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let refreshedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)
    try await store.applyChannelMetadata(
      feedId: feedID, title: "Show", author: nil, synopsis: nil, language: nil, artworkURL: nil,
      refreshedAt: refreshedAt)

    try await store.recordRefreshAttempt(feedID: feedID, at: refreshedAt.addingTimeInterval(3600))

    #expect(try await store.fetchFeed(feedId: feedID)?.lastRefreshedAt == refreshedAt)
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: feedID)?.itemId)
    var diagnostics = RSSPodcastReading(database: database)
      .observeShowDiagnostics(itemId: itemID).makeAsyncIterator()
    let first = try #require(await diagnostics.next())
    #expect(first?.lastEpisodeCheck == refreshedAt)
  }

  /// A feed is marked only when it is subscribed, so a cleared one has never been attempted and
  /// goes ahead of feeds that have.
  @Test func aClearedRecoveryFeedPrecedesAttemptedFeeds() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let ordinary = try await store.subscribe(
      feedURL: URL(string: "https://example.test/ordinary.xml")!, title: "Ordinary",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let marked = try await store.subscribe(
      feedURL: URL(string: "https://example.test/marked.xml")!, title: "Marked",
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date(),
      recoveryReason: .credentialStorageFailed)
    try await store.recordRefreshAttempt(feedID: ordinary, at: Date())

    try await store.clearRecovery(feedId: marked)

    #expect(try await store.fetchRefreshableFeedIDs() == [marked, ordinary])
  }
}
