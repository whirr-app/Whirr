import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct RSSFeedStoreTests {
  @Test func subscribeStripsFeedURLUserinfoBeforePersistence() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let credentialedURL = URL(string: "https://feed-user:feed-password@example.com/feed.xml")!

    let feedID = try await store.subscribe(
      feedURL: credentialedURL, title: nil, author: nil, synopsis: nil, artworkURL: nil,
      subscribedAt: Date())
    let storedFeed = try #require(try await store.fetchFeed(feedURL: credentialedURL))

    #expect(storedFeed.id == feedID)
    #expect(storedFeed.feedURL == "https://example.com/feed.xml")
    #expect(
      storedFeed.podcastFeedFingerprint
        == PodcastFeedIdentity.fingerprint("https://example.com/feed.xml"))
    #expect(storedFeed.feedURL.contains("feed-user") == false)
    #expect(storedFeed.feedURL.contains("feed-password") == false)
  }

  @Test func subscribeAndFetchRoundTripsEveryField() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let subscribedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let feedURL = URL(string: "https://example.com/a%2Fb.xml")!
    let artworkURL = URL(string: "https://example.com/artwork.png")!

    let id = try await store.subscribe(
      feedURL: feedURL, title: "Title", author: "Author", synopsis: "Synopsis",
      artworkURL: artworkURL, subscribedAt: subscribedAt)
    let feed = try #require(try await store.fetchFeed(feedId: id))

    #expect(feed.id == id)
    #expect(feed.feedURL == feedURL.absoluteString)
    #expect(feed.title == "Title")
    #expect(feed.author == "Author")
    #expect(feed.synopsis == "Synopsis")
    #expect(feed.artworkURL == artworkURL.absoluteString)
    #expect(feed.etag == nil)
    #expect(feed.lastModified == nil)
    #expect(feed.subscribedAt == subscribedAt)
    #expect(feed.lastRefreshedAt == nil)
    #expect(feed.refreshGeneration == 0)
    #expect(feed.customSortIndex == nil)
    #expect(feed.podcastFeedFingerprint == PodcastFeedIdentity.fingerprint(feedURL))
    #expect(try await store.fetchFeed(feedURL: feedURL) == feed)
  }

  @Test func duplicateURLReportsTheOriginalID() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let url = URL(string: "https://example.com/feed.xml")!
    let id = try await store.subscribe(
      feedURL: url, title: nil, author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())

    await #expect(throws: RSSFeedStoreError.duplicateFeed(existingFeedId: id)) {
      try await store.subscribe(
        feedURL: url, title: "Different", author: nil, synopsis: nil, artworkURL: nil,
        subscribedAt: Date())
    }
  }

  @Test func unsubscribeCascadesChildren() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let feedId = try await store.subscribe(
      feedURL: URL(string: "https://example.com/feed.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())

    try await database.writeAsync { db in
      try db.execute(
        sql: "INSERT INTO rssEpisode (feedId, identityKey, enclosureURL, lastSeenGeneration) VALUES (?, ?, ?, ?)",
        arguments: [feedId, "episode", "https://example.com/episode.mp3", 0])
      try db.execute(
        sql: "INSERT INTO rssFeedSettings (feedId) VALUES (?)", arguments: [feedId])
    }
    try await store.unsubscribe(feedId: feedId)

    #expect(try await store.fetchFeed(feedId: feedId) == nil)
    let counts = try database.read { db in
      try ["rssEpisode", "rssFeedSettings"].map {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0) WHERE feedId = ?", arguments: [feedId])
      }
    }
    #expect(counts == [0, 0])
  }

  @Test func unknownUnsubscribeReportsNotFound() async throws {
    let store = RSSFeedStore(database: try AppDatabase.inMemory())
    await #expect(throws: RSSFeedStoreError.feedNotFound) {
      try await store.unsubscribe(feedId: 999)
    }
  }

  @Test func unsubscribeCompactsIndexedFeedsAndLeavesNullIndexesUntouched() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let ids = try await subscribeFeeds(store, names: ["A", "B", "C", "Null"])
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE rssFeed SET customSortIndex = ? WHERE id = ?", arguments: [0, ids[0]])
      try db.execute(sql: "UPDATE rssFeed SET customSortIndex = ? WHERE id = ?", arguments: [1, ids[1]])
      try db.execute(sql: "UPDATE rssFeed SET customSortIndex = ? WHERE id = ?", arguments: [2, ids[2]])
    }
    try await store.unsubscribe(feedId: ids[1])

    let rows = try await store.fetchFeeds()
    #expect(rows.map(\.id) == [ids[0], ids[2], ids[3]])
    #expect(rows.map(\.customSortIndex) == [0, 1, nil])
  }

  @Test func invalidCustomOrderLeavesPreviousIndexesAndModeUntouched() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let ids = try await subscribeFeeds(store, names: ["A", "B", "C"])
    try await store.replaceCustomOrder(feedIds: [ids[2], ids[0], ids[1]])
    try await store.setSortMode(.alphabetical)

    let expectedIndexes = try await store.fetchFeeds().map(\.customSortIndex)
    await #expect(throws: RSSFeedStoreError.duplicateSortFeed(feedId: ids[0])) {
      try await store.replaceCustomOrder(feedIds: [ids[0], ids[0], ids[1]])
    }
    await #expect(throws: RSSFeedStoreError.unknownSortFeed(feedId: 999)) {
      try await store.replaceCustomOrder(feedIds: [ids[0], ids[1], 999])
    }
    await #expect(throws: RSSFeedStoreError.incompleteSortFeedIds(missingFeedIds: [ids[2]])) {
      try await store.replaceCustomOrder(feedIds: [ids[0], ids[1]])
    }
    #expect(try await store.fetchFeeds().map(\.customSortIndex) == expectedIndexes)
    #expect(try await store.sortMode() == .alphabetical)
  }

  @Test func replacingAndResettingCustomOrderCommitsModeAndDenseIndexes() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let ids = try await subscribeFeeds(store, names: ["A", "B", "C"])

    try await store.replaceCustomOrder(feedIds: [ids[2], ids[0], ids[1]])
    #expect(try await store.sortMode() == .custom)
    #expect(try await store.fetchFeeds().map(\.id) == [ids[2], ids[0], ids[1]])
    #expect(try await store.fetchFeeds().map(\.customSortIndex) == [0, 1, 2])

    try await store.unsubscribe(feedId: ids[2])
    #expect(try await store.fetchFeeds().map(\.customSortIndex) == [0, 1])

    try await store.resetToAlphabetical()
    #expect(try await store.fetchFeeds().map(\.customSortIndex) == [nil, nil])
    #expect(try await store.sortMode() == .alphabetical)
  }

  @Test func fetchFeedsOrdersIndexesThenTitlesCaseInsensitively() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let indexed = try await subscribeFeeds(store, names: ["z-index", "a-index"])
    let nulls = try await subscribeFeeds(store, names: ["beta", "Alpha"])
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE rssFeed SET customSortIndex = 1 WHERE id = ?", arguments: [indexed[0]])
      try db.execute(sql: "UPDATE rssFeed SET customSortIndex = 0 WHERE id = ?", arguments: [indexed[1]])
    }

    #expect(try await store.fetchFeeds().map(\.id) == [indexed[1], indexed[0], nulls[1], nulls[0]])
  }

  @Test func sortModeDefaultsFailsClosedAndRoundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)

    #expect(try await store.sortMode() == .alphabetical)
    try await database.writeAsync { db in
      try db.execute(sql: "INSERT INTO rssShowOrder (id, mode) VALUES (0, 'future')")
    }
    #expect(try await store.sortMode() == .alphabetical)

    try await store.setSortMode(.mostRecent)
    #expect(try await store.sortMode() == .mostRecent)
    try await store.setSortMode(.custom)
    #expect(try await store.sortMode() == .custom)
  }

  @Test func observesInitialFeedsAndSubsequentSubscription() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    _ = try await subscribeFeeds(store, names: ["B", "A"])
    var iterator = store.observeFeeds().makeAsyncIterator()

    #expect(await iterator.next() == (try await store.fetchFeeds()))

    let newFeedURL = URL(string: "https://example.com/C.xml")!
    let newFeedID = try await store.subscribe(
      feedURL: newFeedURL, title: "C", author: nil, synopsis: nil, artworkURL: nil,
      subscribedAt: Date())
    let observed = try #require(await iterator.next())
    #expect(observed == (try await store.fetchFeeds()))
    #expect(observed.contains { $0.id == newFeedID })
  }

  @Test func validatorsRoundTripVerbatimAndCanBeCleared() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let feedURL = URL(string: "https://example.com/feed.xml")!
    _ = try await store.subscribe(
      feedURL: feedURL, title: nil, author: nil, synopsis: nil, artworkURL: nil,
      subscribedAt: Date())
    let etag = " W/\"opaque\" "
    let lastModified = "  Wed, 21 Oct 2015 07:28:00 GMT  "

    try await store.storeValidators(etag: etag, lastModified: lastModified, feedURL: feedURL)
    #expect(try await store.validators(feedURL: feedURL)?.etag == etag)
    #expect(try await store.validators(feedURL: feedURL)?.lastModified == lastModified)

    try await store.storeValidators(etag: nil, lastModified: nil, feedURL: feedURL)
    #expect(try await store.validators(feedURL: feedURL)?.etag == nil)
    #expect(try await store.validators(feedURL: feedURL)?.lastModified == nil)
  }

  @Test func validatorsReturnNilForUnknownURLAndStoreReportsNotFound() async throws {
    let store = RSSFeedStore(database: try AppDatabase.inMemory())
    let feedURL = URL(string: "https://example.com/missing.xml")!

    #expect(try await store.validators(feedURL: feedURL) == nil)
    await #expect(throws: RSSFeedStoreError.feedNotFound) {
      try await store.storeValidators(etag: "etag", lastModified: nil, feedURL: feedURL)
    }
  }

  @Test func applyChannelMetadataOverwritesFieldsAndPreservesUnrelatedState() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let feedURL = URL(string: "https://example.com/feed.xml")!
    let artworkURL = URL(string: "https://example.com/artwork.png")!
    let subscribedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let refreshedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let feedID = try await store.subscribe(
      feedURL: feedURL, title: "Original", author: "Author", synopsis: "Synopsis",
      artworkURL: artworkURL, subscribedAt: subscribedAt)
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE rssFeed
          SET customSortIndex = 3, refreshGeneration = 7, etag = ?, lastModified = ?
          WHERE id = ?
          """,
        arguments: ["etag", "last-modified", feedID])
    }

    try await store.applyChannelMetadata(
      feedId: feedID, title: nil, author: nil, synopsis: nil, language: nil, artworkURL: nil,
      refreshedAt: refreshedAt)
    let feed = try #require(try await store.fetchFeed(feedId: feedID))
    #expect(feed.title == nil)
    #expect(feed.author == nil)
    #expect(feed.synopsis == nil)
    #expect(feed.artworkURL == nil)
    #expect(feed.lastRefreshedAt == refreshedAt)
    #expect(feed.feedURL == feedURL.absoluteString)
    #expect(feed.subscribedAt == subscribedAt)
    #expect(feed.refreshGeneration == 7)
    #expect(feed.customSortIndex == 3)
    #expect(feed.etag == "etag")
    #expect(feed.lastModified == "last-modified")
  }

  @Test func applyChannelMetadataWritesAndClearsTheShowLanguage() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let feedID = try await store.subscribe(
      feedURL: URL(string: "https://example.com/language.xml")!, title: "Show", author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())
    #expect(try await store.fetchFeed(feedId: feedID)?.language == nil)

    try await store.applyChannelMetadata(
      feedId: feedID, title: "Show", author: nil, synopsis: nil, language: "en-GB", artworkURL: nil,
      refreshedAt: Date())
    #expect(try await store.fetchFeed(feedId: feedID)?.language == "en-GB")

    try await store.applyChannelMetadata(
      feedId: feedID, title: "Show", author: nil, synopsis: nil, language: nil, artworkURL: nil,
      refreshedAt: Date())
    #expect(try await store.fetchFeed(feedId: feedID)?.language == nil)
  }

  @Test func applyChannelMetadataUnknownIDReportsNotFound() async throws {
    let store = RSSFeedStore(database: try AppDatabase.inMemory())
    await #expect(throws: RSSFeedStoreError.feedNotFound) {
      try await store.applyChannelMetadata(
        feedId: 999, title: nil, author: nil, synopsis: nil, language: nil, artworkURL: nil, refreshedAt: Date())
    }
  }

  @Test func applyChannelMetadataDoesNotPersistCredentialBearingArtwork() async throws {
    let database = try AppDatabase.inMemory()
    let store = RSSFeedStore(database: database)
    let feedID = try await store.subscribe(
      feedURL: URL(string: "https://example.com/artwork-boundary.xml")!, title: nil, author: nil,
      synopsis: nil, artworkURL: nil, subscribedAt: Date())

    try await store.applyChannelMetadata(
      feedId: feedID, title: "Show", author: nil, synopsis: nil, language: nil,
      artworkURL: URL(string: "https://user:password@example.com/artwork.jpg"), refreshedAt: Date())

    #expect(try await store.fetchFeed(feedId: feedID)?.artworkURL == nil)
  }

  private func subscribeFeeds(_ store: RSSFeedStore, names: [String]) async throws -> [Int64] {
    var ids: [Int64] = []
    for name in names {
      ids.append(
        try await store.subscribe(
          feedURL: URL(string: "https://example.com/\(name).xml")!, title: name, author: nil,
          synopsis: nil, artworkURL: nil, subscribedAt: Date()))
    }
    return ids
  }
}
