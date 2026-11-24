import Foundation
import GRDB
import Testing

@testable import Persistence

/// The account-owned queue projects and mutates one dense order across ABS books,
/// ABS podcast episodes, and device-owned RSS episodes.
@Suite struct MixedSourceListeningQueueStoreTests {
  @Test("appending the same RSS identity is idempotent")
  func rssAppendIsIdempotent() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    let identity = try fixture.rssEpisode(0)
    #expect(try await store.append(identity: identity) == .appended)
    #expect(try await store.append(identity: identity) == .alreadyQueued)
    #expect(await store.fetchQueue().map(\.identity) == [identity])
  }

  @Test("an RSS queue row carries its episode's own artwork beside the show's; other rows carry none")
  func rssRowCarriesEpisodeArtwork() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssEpisode SET artworkURL = ? WHERE identityKey = ?",
        arguments: ["https://rss.example/episode-art.jpg", "native-1"])
    }
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    try await store.append(identity: try fixture.rssEpisode(0))
    try await store.append(identity: try fixture.rssEpisode(1))
    try await store.append(identity: fixture.book)
    try await store.append(identity: fixture.absEpisode)

    let rows = await store.fetchQueue()
    #expect(rows[0].episodeArtworkURL == URL(string: "https://rss.example/episode-art.jpg"))
    #expect(rows[0].artworkURL == URL(string: "https://rss.example/artwork.jpg"))
    #expect(rows[1].episodeArtworkURL == nil)
    #expect(rows[1].artworkURL == URL(string: "https://rss.example/artwork.jpg"))
    #expect(rows[2].episodeArtworkURL == nil)
    #expect(rows[3].episodeArtworkURL == nil)
  }

  @Test("insert, read, move, clear, and restore preserve one mixed-source order")
  func mixedSourceMutationRoundTrip() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)

    try await store.append(identity: fixture.book)
    try await store.append(identity: try fixture.rssEpisode(0))
    try await store.append(identity: fixture.absEpisode)
    try await store.insertNext(identity: try fixture.rssEpisode(1))
    try await store.move(identity: fixture.book, to: 2)

    let expected = [
      try fixture.rssEpisode(1), try fixture.rssEpisode(0), fixture.book, fixture.absEpisode,
    ]
    let rows = await store.fetchQueue()
    #expect(rows.map(\.identity) == expected)
    #expect(rows.map(\.position) == [0, 1, 2, 3])
    #expect(rows[0].primaryTitle == "Native Episode 2")
    #expect(rows[0].secondaryTitle == "Native Show")
    #expect(rows[0].category == .podcast)
    #expect(rows[0].artworkURL == URL(string: "https://rss.example/artwork.jpg"))
    #expect(rows[0].artworkFeedURL == URL(string: "https://rss.example/feed.xml"))

    let token = try await store.clear()
    #expect(await store.fetchQueue().isEmpty)
    try await store.restore(token: token)
    #expect(await store.fetchQueue().map(\.identity) == expected)
  }

  @Test("the live prefix leaves tombstones out before its limit and keeps durable positions")
  func livePrefixSkipsTombstonesBeforeTheLimit() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    try await store.append(identity: fixture.book)
    try await store.append(identity: try fixture.rssEpisode(0))
    try await store.append(identity: fixture.absEpisode)
    try await store.append(identity: try fixture.rssEpisode(1))
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = 1 WHERE serverItemId = ?", arguments: [fixture.book.itemID])
    }

    var iterator = store.observeLiveQueue(limit: 2).makeAsyncIterator()
    let rows = try #require(await iterator.next())

    #expect(rows.map(\.identity) == [try fixture.rssEpisode(0), fixture.absEpisode])
    #expect(rows.map(\.position) == [1, 2])
    #expect(await store.fetchQueue().count == 4)
  }

  @Test("an unknown RSS episode is rejected without changing the queue")
  func unknownRSSEpisodeIsRejected() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)

    await #expect(throws: ListeningQueueStoreError.episodeNotFound) {
      try await store.append(
        identity: try #require(
          ListeningIdentity.rssEpisode(feedID: fixture.feedID, episodeID: "missing")))
    }
    #expect(await store.fetchQueue().isEmpty)
  }

  @Test("a dropped queued RSS episode is retained and projected as a tombstone")
  func droppedQueuedRSSEpisodeBecomesATombstone() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    try await store.append(identity: try fixture.rssEpisode(0))
    try await store.append(identity: fixture.book)

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE rssFeed SET refreshGeneration = 2 WHERE id = ?",
        arguments: [fixture.feedID])
    }
    let sweep = try await RSSEpisodeStore(database: database).sweepDroppedEpisodes(
      feedId: fixture.feedID)

    #expect(sweep == (deleted: 1, newlyRetained: 1))
    let rows = await store.fetchQueue()
    #expect(rows.map(\.identity) == [try fixture.rssEpisode(0), fixture.book])
    #expect(rows[0].isTombstone)
    #expect(await store.peekNextLive()?.identity == fixture.book)
  }

  @Test("download candidates understand RSS rows without requesting an ABS identity")
  func downloadCandidatesIncludeOnlyRSSRowsWithoutRSSDownloads() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    try await store.append(identity: try fixture.rssEpisode(0))
    try await store.append(identity: try fixture.rssEpisode(1))

    try await database.writeAsync { db in
      let now = Date(timeIntervalSince1970: 1_700_000_000)
      try db.execute(
        sql: """
          INSERT INTO rssDownload
            (episodeId, state, relativePath, origin, decidedStamp, createdAt, updatedAt)
          VALUES (?, 'completed', 'RSS/episode.mp3', 'manual', ?, ?, ?)
          """,
        arguments: [fixture.rssEpisodeRowIDs[1], now, now, now])
    }

    #expect(
      try await store.fetchQueueIdentitiesWithoutDownloads() == [try fixture.rssEpisode(0)])
  }

  @Test("unsubscribing removes RSS rows and compacts the surviving mixed queue")
  func unsubscribeCompactsTheQueue() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    try await store.append(identity: fixture.book)
    try await store.append(identity: try fixture.rssEpisode(0))
    try await store.append(identity: fixture.absEpisode)

    try await RSSFeedStore(database: database).unsubscribe(feedId: fixture.feedID)

    let rows = await store.fetchQueue()
    #expect(rows.map(\.identity) == [fixture.book, fixture.absEpisode])
    #expect(rows.map(\.position) == [0, 1])
    try await store.insertNext(identity: fixture.absEpisode)
    #expect(await store.fetchQueue().map(\.position) == [0, 1])
  }

  private struct Fixture {
    let accountID: Int64
    let book: ListeningIdentity
    let absEpisode: ListeningIdentity
    let feedID: Int64
    let rssEpisodeIDs: [String]
    let rssEpisodeRowIDs: [Int64]

    func rssEpisode(_ index: Int) throws -> ListeningIdentity {
      try #require(
        ListeningIdentity.rssEpisode(feedID: feedID, episodeID: rssEpisodeIDs[index]))
    }
  }

  private static func seed(_ database: AppDatabase) async throws -> Fixture {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "mixed-source-client", serverBaseURL: "https://abs.example",
        serverUserId: "mixed-source-user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library", mediaType: "book", name: "Library")
      try library.insert(db)
      var book = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "book",
        mediaKind: "book", title: "Book", sortTitle: "book", author: "Author",
        numAudioFiles: 1)
      try book.insert(db)
      var show = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "abs-show",
        mediaKind: "podcast", title: "ABS Show", sortTitle: "abs show")
      try show.insert(db)
      var absEpisode = PodcastEpisodeRecord(
        accountId: account.id!, itemId: show.id!, serverEpisodeId: "abs-episode",
        title: "ABS Episode", lastSeenGeneration: 1)
      try absEpisode.insert(db)

      var feed = RSSFeedRecord(
        feedURL: "https://rss.example/feed.xml", title: "Native Show",
        artworkURL: "https://rss.example/artwork.jpg",
        subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), refreshGeneration: 1)
      try feed.insert(db)
      var rssEpisodeRowIDs: [Int64] = []
      let rssEpisodeIDs = ["native-1", "native-2"]
      for (index, identity) in rssEpisodeIDs.enumerated() {
        var episode = RSSEpisodeRecord(
          feedId: feed.id!, identityKey: identity, title: "Native Episode \(index + 1)",
          enclosureURL: "https://rss.example/\(identity).mp3", lastSeenGeneration: 1)
        try episode.insert(db)
        rssEpisodeRowIDs.append(episode.id!)
      }

      return Fixture(
        accountID: account.id!,
        book: try #require(ListeningIdentity.audiobook(itemID: book.serverItemId)),
        absEpisode: try #require(
          ListeningIdentity.podcastEpisode(
            itemID: show.serverItemId, episodeID: absEpisode.serverEpisodeId)),
        feedID: feed.id!,
        rssEpisodeIDs: rssEpisodeIDs, rssEpisodeRowIDs: rssEpisodeRowIDs)
    }
  }
}
