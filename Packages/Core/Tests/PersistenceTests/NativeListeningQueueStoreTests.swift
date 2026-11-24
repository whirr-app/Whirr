import Foundation
import Testing

@testable import Persistence

/// Contract tests for the source split, through the public queue boundary. The fixture shape
/// matches MixedSourceListeningQueueStoreTests.
@Suite struct NativeListeningQueueStoreTests {
  @Test("standalone queue accepts RSS without an account and preserves dense order")
  func standaloneRSSQueue() async throws {
    let db = try AppDatabase.inMemory()
    let feedID = try await Self.seedRSS(db)
    let queue = ListeningQueueStore(database: db)
    let first = try #require(ListeningIdentity.rssEpisode(feedID: feedID, episodeID: "one"))
    let second = try #require(ListeningIdentity.rssEpisode(feedID: feedID, episodeID: "two"))
    try await queue.append(identity: first)
    try await queue.insertNext(identity: second)
    #expect(await queue.fetchQueue().map(\.identity) == [second, first])
    #expect(await queue.fetchQueue().map(\.position) == [0, 1])
  }

  @Test("account queue interleaves RSS and ABS identities through move and remove")
  func connectedInterleaving() async throws {
    let db = try AppDatabase.inMemory()
    let fixture = try await Self.seed(db)
    let queue = ListeningQueueStore(database: db, accountId: fixture.account)
    let rss = try #require(ListeningIdentity.rssEpisode(feedID: fixture.feed, episodeID: "one"))
    let book = try #require(ListeningIdentity.audiobook(itemID: "book"))
    try await queue.append(identity: book)
    try await queue.append(identity: rss)
    try await queue.move(identity: rss, to: 0)
    #expect(await queue.fetchQueue().map(\.identity) == [rss, book])
    try await queue.remove(identity: rss)
    #expect(await queue.fetchQueue().map(\.identity) == [book])
  }

  @Test("an ABS queue row carries its item's serverUpdatedAt; an RSS row carries none")
  func queueRowsCarryServerUpdatedAt() async throws {
    let db = try AppDatabase.inMemory()
    let fixture = try await Self.seed(db)
    try await db.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET serverUpdatedAt = ? WHERE serverItemId = 'book'",
        arguments: [Self.bookServerUpdatedAt])
    }
    let queue = ListeningQueueStore(database: db, accountId: fixture.account)
    try await queue.append(identity: try #require(ListeningIdentity.audiobook(itemID: "book")))
    try await queue.append(
      identity: try #require(ListeningIdentity.rssEpisode(feedID: fixture.feed, episodeID: "one")))

    #expect(await queue.fetchQueue().map(\.serverUpdatedAt) == [Self.bookServerUpdatedAt, nil])
  }

  private static let bookServerUpdatedAt = Date(timeIntervalSince1970: 1_790_000_000)

  private static func seedRSS(_ db: AppDatabase) async throws -> Int64 {
    try await db.writeAsync { db in
      var feed = RSSFeedRecord(feedURL: "https://test.invalid/feed", title: "Test", subscribedAt: Date())
      try feed.insert(db)
      for name in ["one", "two"] {
        var episode = RSSEpisodeRecord(
          feedId: feed.id!, identityKey: name, title: name, enclosureURL: "https://test.invalid/\(name).mp3",
          lastSeenGeneration: 1)
        try episode.insert(db)
      }
      return feed.id!
    }
  }

  private struct Fixture {
    let account: Int64
    let feed: Int64
  }
  private static func seed(_ db: AppDatabase) async throws -> Fixture {
    try await db.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "queue-test", serverBaseURL: "https://abs.invalid", serverUserId: "u", serverVersion: "1")
      try account.insert(db)
      var library = LibraryRecord(accountId: account.id!, serverLibraryId: "l", mediaType: "book", name: "Library")
      try library.insert(db)
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "book", mediaKind: "book", title: "Book",
        sortTitle: "book", numAudioFiles: 1)
      try item.insert(db)
      var feed = RSSFeedRecord(feedURL: "https://test.invalid/feed", title: "Test", subscribedAt: Date())
      try feed.insert(db)
      var episode = RSSEpisodeRecord(
        feedId: feed.id!, identityKey: "one", title: "One", enclosureURL: "https://test.invalid/one.mp3",
        lastSeenGeneration: 1)
      try episode.insert(db)
      return Fixture(account: account.id!, feed: feed.id!)
    }
  }
}
