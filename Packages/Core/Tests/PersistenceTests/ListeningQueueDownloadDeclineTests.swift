import Foundation
import GRDB
import Testing

@testable import Persistence

/// An Up Next entry whose download the listener removed by hand is flagged, so Download Up Next
/// leaves it alone until it leaves the queue or is downloaded again by hand.
@Suite struct ListeningQueueDownloadDeclineTests {
  private static let declinedAt = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("a declined entry is not a download candidate, server or native")
  func declinedEntriesAreNotCandidates() async throws {
    let (database, fixture) = try await Self.queuedEverything()
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    #expect(try await store.fetchQueueIdentitiesWithoutDownloads() == fixture.everything)

    try await store.declineDownloads(itemID: "book-1", episodeID: nil, at: Self.declinedAt)
    try await store.declineDownloads(itemID: "show", episodeID: "abs-1", at: Self.declinedAt)
    try await store.declineDownloads(
      itemID: fixture.feedItemID, episodeID: "native-1", at: Self.declinedAt)

    #expect(
      try await store.fetchQueueIdentitiesWithoutDownloads() == [
        fixture.book(2), fixture.absEpisode(2), fixture.rssEpisode(2),
      ])
    #expect(try await store.isDownloadDeclined(fixture.book(1)))
    #expect(try await store.isDownloadDeclined(fixture.absEpisode(1)))
    #expect(try await store.isDownloadDeclined(fixture.rssEpisode(1)))
    #expect(try await store.isDownloadDeclined(fixture.book(2)) == false)
  }

  @Test("an item decline covers a server show's episodes or a native feed's, and nothing else")
  func itemDeclinesCoverTheShow() async throws {
    let (database, fixture) = try await Self.queuedEverything()
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)

    try await store.declineDownloads(itemID: "show", episodeID: nil, at: Self.declinedAt)
    #expect(
      try await store.fetchQueueIdentitiesWithoutDownloads() == [
        fixture.book(1), fixture.book(2), fixture.rssEpisode(1), fixture.rssEpisode(2),
      ])

    try await store.declineDownloads(itemID: fixture.feedItemID, episodeID: nil, at: Self.declinedAt)
    #expect(
      try await store.fetchQueueIdentitiesWithoutDownloads() == [fixture.book(1), fixture.book(2)])
  }

  @Test("declining everything flags every entry but leaves another account's queue alone")
  func declineAllStaysInTheAccount() async throws {
    let (database, fixture) = try await Self.queuedEverything()
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    let other = ListeningQueueStore(database: database, accountId: fixture.otherAccountID)
    try await other.append(identity: fixture.otherBook)

    try await store.declineDownloads(itemID: nil, episodeID: nil, at: Self.declinedAt)

    #expect(try await store.fetchQueueIdentitiesWithoutDownloads().isEmpty)
    #expect(try await other.isDownloadDeclined(fixture.otherBook) == false)
  }

  @Test("an item with the same server id in another account is not declined")
  func declineMatchesOnlyThisAccountsItem() async throws {
    let (database, fixture) = try await Self.queuedEverything()
    let other = ListeningQueueStore(database: database, accountId: fixture.otherAccountID)
    try await other.append(identity: fixture.otherBook)

    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    try await store.declineDownloads(
      itemID: fixture.otherBook.itemID, episodeID: nil, at: Self.declinedAt)

    #expect(try await other.isDownloadDeclined(fixture.otherBook) == false)
  }

  @Test("declining does not move the queue revision, so a pending Undo still restores")
  func declineKeepsAClearTokenValid() async throws {
    let (database, fixture) = try await Self.queuedEverything()
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    try await store.declineDownloads(itemID: "book-1", episodeID: nil, at: Self.declinedAt)

    let token = try await store.clear()
    try await store.declineDownloads(itemID: nil, episodeID: nil, at: Self.declinedAt)
    try await store.restore(token: token)

    #expect(await store.fetchQueue().map(\.identity) == fixture.everything)
  }

  @Test("Clear then Undo keeps each entry's decline")
  func clearAndUndoKeepTheDecline() async throws {
    let (database, fixture) = try await Self.queuedEverything()
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    try await store.declineDownloads(itemID: "book-1", episodeID: nil, at: Self.declinedAt)
    try await store.declineDownloads(
      itemID: fixture.feedItemID, episodeID: "native-2", at: Self.declinedAt)

    let token = try await store.clear()
    try await store.restore(token: token)

    #expect(
      try await store.fetchQueueIdentitiesWithoutDownloads() == [
        fixture.book(2), fixture.absEpisode(1), fixture.absEpisode(2), fixture.rssEpisode(1),
      ])
  }

  @Test("moving, Play Next and a chapter change keep the decline")
  func reorderingKeepsTheDecline() async throws {
    let (database, fixture) = try await Self.queuedEverything()
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    try await store.declineDownloads(itemID: nil, episodeID: nil, at: Self.declinedAt)

    try await store.move(identity: fixture.book(2), to: 0)
    try await store.insertNext(identity: fixture.rssEpisode(2))
    try await store.insertNext(identities: [fixture.absEpisode(2), fixture.book(1)])
    let chapter = ListeningQueueChapter(start: 0, end: 60, title: "One")
    #expect(try await store.append(identity: fixture.book(1), chapter: chapter) == .replaced)

    #expect(try await store.fetchQueueIdentitiesWithoutDownloads().isEmpty)
  }

  @Test("removing an entry and adding it again makes a new entry with no decline")
  func reAddingStartsAfresh() async throws {
    let (database, fixture) = try await Self.queuedEverything()
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    try await store.declineDownloads(itemID: nil, episodeID: nil, at: Self.declinedAt)

    try await store.remove(identity: fixture.book(1))
    try await store.append(identity: fixture.book(1))
    try await store.remove(identity: fixture.rssEpisode(1))
    try await store.append(identity: fixture.rssEpisode(1))

    #expect(
      try await store.fetchQueueIdentitiesWithoutDownloads() == [
        fixture.book(1), fixture.rssEpisode(1),
      ])
  }

  @Test("clearing with no episode clears the audiobook and never a show's episodes")
  func clearingWithNoEpisodeClearsOnlyTheAudiobook() async throws {
    let (database, fixture) = try await Self.queuedEverything()
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    try await store.declineDownloads(itemID: nil, episodeID: nil, at: Self.declinedAt)

    try await store.clearDownloadDecline(itemID: "book-1", episodeID: nil)
    try await store.clearDownloadDecline(itemID: "show", episodeID: nil)
    try await store.clearDownloadDecline(itemID: fixture.feedItemID, episodeID: nil)
    #expect(try await store.fetchQueueIdentitiesWithoutDownloads() == [fixture.book(1)])

    try await store.clearDownloadDecline(itemID: "show", episodeID: "abs-2")
    try await store.clearDownloadDecline(itemID: fixture.feedItemID, episodeID: "native-1")
    #expect(
      try await store.fetchQueueIdentitiesWithoutDownloads() == [
        fixture.book(1), fixture.absEpisode(2), fixture.rssEpisode(1),
      ])
  }

  @Test("the tombstone decline flags removed server and native episodes only")
  func tombstonedDeclineFlagsOnlyTombstones() async throws {
    let (database, fixture) = try await Self.queuedEverything()
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE podcastEpisode SET softDeleted = 1 WHERE serverEpisodeId = 'abs-1'")
      try db.execute(
        sql: "UPDATE rssEpisode SET retained = 1, lastSeenGeneration = 1 WHERE identityKey = 'native-2'")
      try db.execute(sql: "UPDATE rssFeed SET refreshGeneration = 2")
      // Still listed by the feed's latest refresh, so not a tombstone.
      try db.execute(sql: "UPDATE rssEpisode SET lastSeenGeneration = 2 WHERE identityKey = 'native-1'")
    }

    try await store.declineTombstonedDownloads(at: Self.declinedAt)

    #expect(
      try await store.fetchQueueIdentitiesWithoutDownloads() == [
        fixture.book(1), fixture.book(2), fixture.absEpisode(2), fixture.rssEpisode(1),
      ])
  }

  // MARK: - Fixture

  private struct Fixture {
    let accountID: Int64
    let otherAccountID: Int64
    let otherBook: ListeningIdentity
    let feedID: Int64
    let feedItemID: String

    func book(_ number: Int) -> ListeningIdentity { .audiobook(itemID: "book-\(number)")! }
    func absEpisode(_ number: Int) -> ListeningIdentity {
      .podcastEpisode(itemID: "show", episodeID: "abs-\(number)")!
    }
    func rssEpisode(_ number: Int) -> ListeningIdentity {
      .rssEpisode(feedID: feedID, episodeID: "native-\(number)")!
    }

    var everything: [ListeningIdentity] {
      [book(1), book(2), absEpisode(1), absEpisode(2), rssEpisode(1), rssEpisode(2)]
    }
  }

  /// Two books, a server show's two episodes and a native show's two, all queued in that order;
  /// plus a second account holding a book with the same server id as the first.
  private static func queuedEverything() async throws -> (AppDatabase, Fixture) {
    let database = try AppDatabase.inMemory()
    let fixture = try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "decline-client", serverBaseURL: "https://abs.example",
        serverUserId: "decline-user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library", mediaType: "book", name: "Library")
      try library.insert(db)
      for number in 1...2 {
        var book = ItemRecord(
          accountId: account.id!, libraryId: library.id!, serverItemId: "book-\(number)",
          mediaKind: "book", title: "Book \(number)", sortTitle: "book \(number)",
          author: "Author", numAudioFiles: 1)
        try book.insert(db)
      }
      var show = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "show",
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try show.insert(db)
      for number in 1...2 {
        var episode = PodcastEpisodeRecord(
          accountId: account.id!, itemId: show.id!, serverEpisodeId: "abs-\(number)",
          title: "ABS \(number)", lastSeenGeneration: 1)
        try episode.insert(db)
      }
      var feed = RSSFeedRecord(
        feedURL: "https://rss.example/feed.xml", title: "Native Show",
        subscribedAt: Self.declinedAt, refreshGeneration: 1)
      try feed.insert(db)
      for number in 1...2 {
        var episode = RSSEpisodeRecord(
          feedId: feed.id!, identityKey: "native-\(number)", title: "Native \(number)",
          enclosureURL: "https://rss.example/\(number).mp3", lastSeenGeneration: 1)
        try episode.insert(db)
      }

      var otherAccount = AccountRecord(
        clientUUID: "other-client", serverBaseURL: "https://other.example",
        serverUserId: "other-user", serverVersion: "2.35.1")
      try otherAccount.insert(db)
      var otherLibrary = LibraryRecord(
        accountId: otherAccount.id!, serverLibraryId: "library", mediaType: "book", name: "Other")
      try otherLibrary.insert(db)
      var otherBook = ItemRecord(
        accountId: otherAccount.id!, libraryId: otherLibrary.id!, serverItemId: "book-1",
        mediaKind: "book", title: "Other Book", sortTitle: "other book", author: "Author",
        numAudioFiles: 1)
      try otherBook.insert(db)

      return Fixture(
        accountID: account.id!, otherAccountID: otherAccount.id!,
        otherBook: .audiobook(itemID: "book-1")!, feedID: feed.id!,
        feedItemID: try #require(PodcastSourceIdentity.rss(feedId: feed.id!)?.itemId))
    }
    let store = ListeningQueueStore(database: database, accountId: fixture.accountID)
    for identity in fixture.everything {
      try await store.append(identity: identity)
    }
    return (database, fixture)
  }
}
