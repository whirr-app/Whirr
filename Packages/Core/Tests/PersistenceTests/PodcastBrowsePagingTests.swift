import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// Bounded show and episode paging for both podcast sources: pages follow the phone's order,
/// membership is decided before the limit, and a cursor taken under one order is refused under
/// another.
@Suite struct PodcastBrowsePagingTests {

  // MARK: Server shows

  @Test func serverShowsPageAlphabeticallyAndSkipBooksAndRemovedShows() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await database.writeAsync { db in
      for index in 0..<7 {
        try Self.insertShow(db, account: account, id: "show-\(index)", sortTitle: "t\(index)")
      }
      try Self.insertShow(db, account: account, id: "gone", sortTitle: "a", softDeleted: true)
      try Self.insertShow(db, account: account, id: "empty", sortTitle: "b", episodeCount: 0)
      var book = ItemRecord(
        accountId: account.accountId, libraryId: account.bookLibraryId, serverItemId: "book",
        mediaKind: "book", title: "Book", sortTitle: "c", numAudioFiles: 2)
      try book.insert(db)
    }
    let paging = DefaultPodcastBrowsePaging(database: database, accountId: account.accountId)

    let first = try await paging.showPage(after: nil, limit: 3)
    let second = try await paging.showPage(after: first.next, limit: 3)
    let third = try await paging.showPage(after: second.next, limit: 3)

    #expect(first.rows.count == 3)
    #expect((first.rows + second.rows + third.rows).map(\.serverItemId) == (0..<7).map { "show-\($0)" })
    #expect(third.next == nil)
  }

  @Test func serverShowsPageInCustomOrderWithTheUnpositionedTail() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await database.writeAsync { db in
      for id in ["a", "b", "c", "d"] {
        try Self.insertShow(db, account: account, id: id, sortTitle: id)
      }
    }
    try await DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
      .replaceCustomOrder(itemIDs: ["d", "b", "a", "c"])
    try await database.writeAsync { db in
      // Synced after the reorder: no position, so they follow alphabetically.
      try Self.insertShow(db, account: account, id: "z", sortTitle: "z")
      try Self.insertShow(db, account: account, id: "y", sortTitle: "y")
    }
    let paging = DefaultPodcastBrowsePaging(database: database, accountId: account.accountId)

    var seen: [String] = []
    var cursor: AudioBrowseCursor?
    repeat {
      let page = try await paging.showPage(after: cursor, limit: 2)
      seen += page.rows.map(\.serverItemId)
      cursor = page.next
    } while cursor != nil && seen.count < 20

    #expect(seen == ["d", "b", "a", "c", "y", "z"])
  }

  @Test func aCursorTakenUnderAnotherShowOrderIsRefused() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await database.writeAsync { db in
      for id in ["a", "b", "c"] {
        try Self.insertShow(db, account: account, id: id, sortTitle: id)
      }
    }
    let paging = DefaultPodcastBrowsePaging(database: database, accountId: account.accountId)
    let first = try await paging.showPage(after: nil, limit: 1)

    try await DefaultPodcastShowOrdering(database: database, accountId: account.accountId)
      .replaceCustomOrder(itemIDs: ["c", "b", "a"])

    await #expect(throws: AudioBrowsePagingError.staleCursor) {
      _ = try await paging.showPage(after: first.next, limit: 1)
    }
  }

  // MARK: Server episodes

  @Test func serverEpisodesPageNewestFirstWithUndatedLast() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    let show = try await database.writeAsync { db in
      let show = try Self.insertShow(db, account: account, id: "show", sortTitle: "show")
      for index in 0..<5 {
        try Self.insertEpisode(
          db, account: account, show: show, id: "dated-\(index)",
          publishedAt: Date(timeIntervalSince1970: Double(1_000 + index)))
      }
      // Two episodes published in the same instant fall back to their server id.
      try Self.insertEpisode(
        db, account: account, show: show, id: "tie-b", publishedAt: Date(timeIntervalSince1970: 500))
      try Self.insertEpisode(
        db, account: account, show: show, id: "tie-a", publishedAt: Date(timeIntervalSince1970: 500))
      try Self.insertEpisode(db, account: account, show: show, id: "undated-b", publishedAt: nil)
      try Self.insertEpisode(db, account: account, show: show, id: "undated-a", publishedAt: nil)
      try Self.insertEpisode(
        db, account: account, show: show, id: "removed",
        publishedAt: Date(timeIntervalSince1970: 9_000), softDeleted: true)
      return show
    }
    #expect(show > 0)
    let paging = DefaultPodcastBrowsePaging(database: database, accountId: account.accountId)

    var seen: [String?] = []
    var cursor: AudioBrowseCursor?
    var pages = 0
    repeat {
      let page = try await paging.episodePage(itemID: "show", after: cursor, limit: 4)
      #expect(page.rows.count == 4 || page.next == nil)
      seen += page.rows.map(\.identity.episodeID)
      cursor = page.next
      pages += 1
    } while cursor != nil && pages < 10

    #expect(
      seen == [
        "dated-4", "dated-3", "dated-2", "dated-1", "dated-0", "tie-a", "tie-b", "undated-a", "undated-b",
      ])
    #expect(pages == 3)
  }

  @Test func aServerEpisodeIsDownloadedOnlyWhenEveryLiveFileCompleted() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await database.writeAsync { db in
      let show = try Self.insertShow(db, account: account, id: "show", sortTitle: "show")
      let complete = try Self.insertEpisode(
        db, account: account, show: show, id: "complete", publishedAt: Date(timeIntervalSince1970: 4))
      let partial = try Self.insertEpisode(
        db, account: account, show: show, id: "partial", publishedAt: Date(timeIntervalSince1970: 3))
      let leaving = try Self.insertEpisode(
        db, account: account, show: show, id: "leaving", publishedAt: Date(timeIntervalSince1970: 2))
      try Self.insertEpisode(
        db, account: account, show: show, id: "none", publishedAt: Date(timeIntervalSince1970: 1))
      // Two files for one episode must not take two places in the page.
      try Self.insertDownload(db, account: account, show: show, episode: complete, ino: "c1", state: .completed)
      try Self.insertDownload(db, account: account, show: show, episode: complete, ino: "c2", state: .completed)
      try Self.insertDownload(db, account: account, show: show, episode: partial, ino: "p1", state: .completed)
      try Self.insertDownload(db, account: account, show: show, episode: partial, ino: "p2", state: .downloading)
      try Self.insertDownload(db, account: account, show: show, episode: leaving, ino: "l1", state: .deleting)
      // A download of the show itself says nothing about any one episode.
      try Self.insertDownload(db, account: account, show: show, episode: nil, ino: "s1", state: .completed)
    }
    let paging = DefaultPodcastBrowsePaging(database: database, accountId: account.accountId)

    let page = try await paging.episodePage(itemID: "show", after: nil, limit: 4)

    #expect(page.rows.map(\.identity.episodeID) == ["complete", "partial", "leaving", "none"])
    #expect(page.rows.map(\.audioDownloaded) == [true, false, false, false])
    #expect(page.next == nil)
    #expect(page.rows.first?.identity == .podcastEpisode(itemID: "show", episodeID: "complete"))
  }

  @Test func episodesCarryHowFarInTheListenerIs() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await database.writeAsync { db in
      let show = try Self.insertShow(db, account: account, id: "show", sortTitle: "show")
      let started = try Self.insertEpisode(
        db, account: account, show: show, id: "started", publishedAt: Date(timeIntervalSince1970: 2))
      try Self.insertEpisode(
        db, account: account, show: show, id: "new", publishedAt: Date(timeIntervalSince1970: 1))
      var progress = MediaProgressRecord(
        accountId: account.accountId, itemId: show, podcastEpisodeId: started, currentTime: 125,
        isFinished: false, localSequence: 1, origin: .server, originKey: "server")
      try progress.insert(db)
    }
    let feed = try await Self.subscribe(database, title: "Followed")
    _ = try await RSSEpisodeStore(database: database).applyRefresh(
      feedId: feed, episodes: [Self.upsert("heard", publishedAt: Date(timeIntervalSince1970: 1))])
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO rssEpisodeState (episodeId, position, finished, localSequence, updatedAt)
          SELECT id, 40, 0, 1, ? FROM rssEpisode WHERE feedId = ?
          """,
        arguments: [Date(), feed])
    }
    let followedID = try #require(PodcastSourceIdentity.rss(feedId: feed)?.itemId)

    let server = try await DefaultPodcastBrowsePaging(database: database, accountId: account.accountId)
      .episodePage(itemID: "show", after: nil, limit: 4)
    let followed = try await RSSPodcastReading(database: database)
      .episodePage(itemID: followedID, after: nil, limit: 4)

    #expect(server.rows.map(\.progressSeconds) == [125, 0])
    #expect(followed.rows.map(\.progressSeconds) == [40])
  }

  @Test func aServerEpisodeCursorForAnotherShowIsRefused() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await database.writeAsync { db in
      for id in ["one", "two"] {
        let show = try Self.insertShow(db, account: account, id: id, sortTitle: id)
        for index in 0..<3 {
          try Self.insertEpisode(
            db, account: account, show: show, id: "\(id)-\(index)",
            publishedAt: Date(timeIntervalSince1970: Double(index)))
        }
      }
    }
    let paging = DefaultPodcastBrowsePaging(database: database, accountId: account.accountId)
    let first = try await paging.episodePage(itemID: "one", after: nil, limit: 1)

    await #expect(throws: AudioBrowsePagingError.staleCursor) {
      _ = try await paging.episodePage(itemID: "two", after: first.next, limit: 1)
    }
  }

  @Test func anUnknownOrExcludedServerShowHasNoEpisodes() async throws {
    let database = try AppDatabase.inMemory()
    let account = try await Self.seedAccount(database)
    try await database.writeAsync { db in
      let hidden = try Self.insertShow(
        db, account: account, id: "hidden", sortTitle: "hidden", libraryId: account.excludedLibraryId)
      try Self.insertEpisode(db, account: account, show: hidden, id: "e", publishedAt: nil)
    }
    let paging = DefaultPodcastBrowsePaging(database: database, accountId: account.accountId)

    #expect(try await paging.episodePage(itemID: "hidden", after: nil, limit: 5).rows.isEmpty)
    #expect(try await paging.episodePage(itemID: "missing", after: nil, limit: 5).rows.isEmpty)
    #expect(try await paging.showPage(after: nil, limit: 5).rows.isEmpty)
  }

  // MARK: Followed feeds

  @Test func followedShowsPageInEachDeviceOrder() async throws {
    let database = try AppDatabase.inMemory()
    let feeds = RSSFeedStore(database: database)
    let bravo = try await Self.subscribe(database, title: "bravo")
    let alpha = try await Self.subscribe(database, title: "Alpha")
    let untitled = try await Self.subscribe(database, title: nil)
    let charlie = try await Self.subscribe(database, title: "Charlie")
    let episodes = RSSEpisodeStore(database: database)
    _ = try await episodes.applyRefresh(
      feedId: bravo, episodes: [Self.upsert("b", publishedAt: Date(timeIntervalSince1970: 300))])
    _ = try await episodes.applyRefresh(
      feedId: charlie, episodes: [Self.upsert("c", publishedAt: Date(timeIntervalSince1970: 200))])
    let paging = RSSPodcastReading(database: database)

    #expect(try await Self.allShows(paging) == [untitled, alpha, bravo, charlie])

    try await feeds.setSortMode(.mostRecent)
    #expect(try await Self.allShows(paging) == [bravo, charlie, untitled, alpha])

    try await feeds.replaceCustomOrder(feedIds: [charlie, untitled, alpha, bravo])
    #expect(try await Self.allShows(paging) == [charlie, untitled, alpha, bravo])
  }

  @Test func aFollowedShowCursorTakenUnderAnotherOrderIsRefused() async throws {
    let database = try AppDatabase.inMemory()
    _ = try await Self.subscribe(database, title: "a")
    _ = try await Self.subscribe(database, title: "b")
    let paging = RSSPodcastReading(database: database)
    let first = try await paging.showPage(after: nil, limit: 1)

    try await RSSFeedStore(database: database).setSortMode(.mostRecent)

    await #expect(throws: AudioBrowsePagingError.staleCursor) {
      _ = try await paging.showPage(after: first.next, limit: 1)
    }
  }

  @Test func followedEpisodesPageNewestFirstAndReportCompletedDownloadsOnly() async throws {
    let database = try AppDatabase.inMemory()
    let feed = try await Self.subscribe(database, title: "Show")
    let other = try await Self.subscribe(database, title: "Other")
    let store = RSSEpisodeStore(database: database)
    _ = try await store.applyRefresh(
      feedId: feed,
      episodes: (0..<6).map { Self.upsert("dated-\($0)", publishedAt: Date(timeIntervalSince1970: Double(100 + $0))) }
        + [Self.upsert("undated", publishedAt: nil)])
    _ = try await store.applyRefresh(feedId: other, episodes: [Self.upsert("elsewhere", publishedAt: Date())])
    try await Self.insertRSSDownload(database, feed: feed, key: "dated-5", state: "completed")
    try await Self.insertRSSDownload(database, feed: feed, key: "dated-4", state: "downloading")
    let paging = RSSPodcastReading(database: database)
    let itemID = try #require(PodcastSourceIdentity.rss(feedId: feed)?.itemId)

    let first = try await paging.episodePage(itemID: itemID, after: nil, limit: 3)
    let second = try await paging.episodePage(itemID: itemID, after: first.next, limit: 3)
    let third = try await paging.episodePage(itemID: itemID, after: second.next, limit: 3)

    #expect(first.rows.map(\.identity.episodeID) == ["dated-5", "dated-4", "dated-3"])
    #expect(first.rows.map(\.audioDownloaded) == [true, false, false])
    #expect(first.rows.first?.identity == ListeningIdentity.rssEpisode(feedID: feed, episodeID: "dated-5"))
    #expect(second.rows.map(\.identity.episodeID) == ["dated-2", "dated-1", "dated-0"])
    #expect(third.rows.map(\.identity.episodeID) == ["undated"])
    #expect(third.next == nil)
    #expect(try await paging.episodePage(itemID: "server-item", after: nil, limit: 3).rows.isEmpty)
  }

  @Test func followedDownloadsListCompletedEpisodesByShowThenNewestFirst() async throws {
    let database = try AppDatabase.inMemory()
    let zulu = try await Self.subscribe(database, title: "Zulu")
    let alpha = try await Self.subscribe(database, title: "alpha")
    let store = RSSEpisodeStore(database: database)
    _ = try await store.applyRefresh(
      feedId: zulu, episodes: [Self.upsert("z-1", publishedAt: Date(timeIntervalSince1970: 1))])
    _ = try await store.applyRefresh(
      feedId: alpha,
      episodes: (0..<4).map { Self.upsert("a-\($0)", publishedAt: Date(timeIntervalSince1970: Double($0))) })
    try await Self.insertRSSDownload(database, feed: zulu, key: "z-1", state: "completed")
    try await Self.insertRSSDownload(database, feed: alpha, key: "a-0", state: "completed")
    try await Self.insertRSSDownload(database, feed: alpha, key: "a-2", state: "completed")
    try await Self.insertRSSDownload(database, feed: alpha, key: "a-3", state: "downloading")
    let paging = DefaultRSSDownloadsReading(database: database)

    let first = try await paging.downloadedAudioPage(after: nil, limit: 2)
    let second = try await paging.downloadedAudioPage(after: first.next, limit: 2)

    #expect(
      first.rows.map(\.identity) == [
        ListeningIdentity.rssEpisode(feedID: alpha, episodeID: "a-2"),
        ListeningIdentity.rssEpisode(feedID: alpha, episodeID: "a-0"),
      ])
    #expect(first.rows.map(\.subtitle) == ["alpha", "alpha"])
    #expect(first.rows.first?.artworkFeedURL != nil)
    #expect(second.rows.map(\.identity) == [ListeningIdentity.rssEpisode(feedID: zulu, episodeID: "z-1")])
    #expect(second.next == nil)
  }

  // MARK: Fixtures

  private struct Account: Sendable {
    let accountId: Int64
    let podcastLibraryId: Int64
    let bookLibraryId: Int64
    let excludedLibraryId: Int64
  }

  private static func seedAccount(_ database: AppDatabase) async throws -> Account {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "paging-client", serverBaseURL: "https://example.test",
        serverUserId: "paging-user", serverVersion: "2.35.1")
      try account.insert(db)
      var podcasts = LibraryRecord(
        accountId: account.id!, serverLibraryId: "podcasts", mediaType: "podcast", name: "Podcasts")
      try podcasts.insert(db)
      var books = LibraryRecord(
        accountId: account.id!, serverLibraryId: "books", mediaType: "book", name: "Books")
      try books.insert(db)
      var excluded = LibraryRecord(
        accountId: account.id!, serverLibraryId: "other", mediaType: "podcast", name: "Other",
        isIncluded: false)
      try excluded.insert(db)
      return Account(
        accountId: account.id!, podcastLibraryId: podcasts.id!, bookLibraryId: books.id!,
        excludedLibraryId: excluded.id!)
    }
  }

  @discardableResult
  private static func insertShow(
    _ db: Database, account: Account, id: String, sortTitle: String, softDeleted: Bool = false,
    episodeCount: Int? = nil, libraryId: Int64? = nil
  ) throws -> Int64 {
    var item = ItemRecord(
      accountId: account.accountId, libraryId: libraryId ?? account.podcastLibraryId, serverItemId: id,
      mediaKind: "podcast", title: sortTitle, sortTitle: sortTitle, softDeleted: softDeleted)
    try item.insert(db)
    if let episodeCount {
      try db.execute(
        sql: "UPDATE item SET podcastServerEpisodeCount = ? WHERE id = ?", arguments: [episodeCount, item.id!])
    }
    return item.id!
  }

  @discardableResult
  private static func insertEpisode(
    _ db: Database, account: Account, show: Int64, id: String, publishedAt: Date?, softDeleted: Bool = false
  ) throws -> Int64 {
    var episode = PersistenceFixtures.episode(
      accountId: account.accountId, itemId: show, serverEpisodeId: id, title: "Episode \(id)",
      publishedAt: publishedAt, lastSeenGeneration: 1, softDeleted: softDeleted)
    try episode.insert(db)
    return episode.id!
  }

  private static func insertDownload(
    _ db: Database, account: Account, show: Int64, episode: Int64?, ino: String, state: DownloadState
  ) throws {
    var download = DownloadRecord(
      accountId: account.accountId, itemId: show, podcastEpisodeId: episode, serverFileIno: ino,
      orderIndex: 0, destinationRelativePath: "podcast/\(ino).mp3", expectedBytes: 100,
      expectedMimeType: "audio/mpeg", fileDurationSeconds: 60, state: state)
    try download.insert(db)
  }

  private static func subscribe(_ database: AppDatabase, title: String?) async throws -> Int64 {
    try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/\(UUID().uuidString).xml")!, title: title,
      author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
  }

  private static func upsert(_ key: String, publishedAt: Date?) -> RSSEpisodeUpsert {
    RSSEpisodeUpsert(
      identityKey: key, title: key, enclosureURL: URL(string: "https://example.com/\(key).mp3")!,
      publishedAt: publishedAt)
  }

  private static func insertRSSDownload(
    _ database: AppDatabase, feed: Int64, key: String, state: String
  ) async throws {
    try await database.writeAsync { db in
      let episode = try Int64.fetchOne(
        db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?", arguments: [feed, key])
      try db.execute(
        sql: """
          INSERT INTO rssDownload
            (episodeId, state, relativePath, expectedBytes, actualBytes, origin, decidedStamp, createdAt, updatedAt)
          VALUES (?, ?, ?, 10, 10, 'manual', ?, ?, ?)
          """,
        arguments: [episode, state, "\(key).mp3", Date(), Date(), Date()])
    }
  }

  /// Every followed show's feed id, read one row at a time so each row crosses a page boundary.
  private static func allShows(_ paging: RSSPodcastReading) async throws -> [Int64] {
    var seen: [Int64] = []
    var cursor: AudioBrowseCursor?
    repeat {
      let page = try await paging.showPage(after: cursor, limit: 1)
      seen += page.rows.compactMap { PodcastSourceIdentity(itemId: $0.serverItemId)?.rssFeedId }
      cursor = page.next
    } while cursor != nil && seen.count < 20
    return seen
  }
}
