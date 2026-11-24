import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// A queued audiobook row may carry one chapter.
@Suite struct ListeningQueueChapterStoreTests {
  private static let chapterThree = ListeningQueueChapter(start: 600, end: 900, title: "Three")
  private static let chapterFour = ListeningQueueChapter(start: 900, end: 1200, title: "Four")

  // MARK: - Migration

  @Test("v96 adds three nullable chapter columns to the ABS queue table only")
  func v96AddsNullableChapterColumns() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in SchemaV1.registerSearchFunctions(db) }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v94")
    try queue.read { db in
      let before = try db.columns(in: "listeningQueueEntry")
      #expect(before.count == 5)
    }

    try SchemaV1.migrator().migrate(queue, upTo: "v96")

    try queue.read { db in
      let columns = try db.columns(in: "listeningQueueEntry")
      for name in ["chapterStart", "chapterEnd", "chapterTitle"] {
        let column = try #require(columns.first { $0.name == name })
        #expect(column.isNotNull == false)
      }
      let rssColumns = try db.columns(in: "rssListeningQueueEntry").map(\.name)
      #expect(rssColumns.contains("chapterStart") == false)
    }
  }

  // MARK: - Projection

  @Test("a chapter row carries its chapter through the queue, the live prefix and the peek")
  func chapterReachesEveryReader() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)

    #expect(try await store.append(identity: fixture.book, chapter: Self.chapterThree) == .appended)
    try await store.append(identity: fixture.episode)

    let queue = await store.fetchQueue()
    #expect(queue.map(\.chapter) == [Self.chapterThree, nil])
    #expect(await store.peekNextLive()?.chapter == Self.chapterThree)
    var live = store.observeLiveQueue(limit: 1).makeAsyncIterator()
    #expect(await live.next()?.first?.chapter == Self.chapterThree)
  }

  @Test("a row moved by the dense renumber keeps its chapter")
  func renumberKeepsTheChapter() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.book, chapter: Self.chapterThree)
    try await store.append(identity: fixture.episode)

    try await store.move(identity: fixture.book, to: 1)
    try await store.insertNext(identity: fixture.rssEpisode)

    let queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.rssEpisode, fixture.episode, fixture.book])
    #expect(queue.map(\.chapter) == [nil, nil, Self.chapterThree])
  }

  // MARK: - Validation

  @Test("a chapter is rejected on anything but an audiobook")
  func chapterNeedsAnAudiobook() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)

    for identity in [fixture.episode, fixture.rssEpisode] {
      await #expect(throws: ListeningQueueStoreError.chapterNotAllowed) {
        try await store.append(identity: identity, chapter: Self.chapterThree)
      }
      await #expect(throws: ListeningQueueStoreError.chapterNotAllowed) {
        try await store.insertNext(identity: identity, chapter: Self.chapterThree)
      }
    }
    #expect(await store.fetchQueue().isEmpty)
  }

  @Test(
    "a chapter with a negative start, or an end not after its start, is rejected",
    arguments: [
      ListeningQueueChapter(start: -1, end: 10, title: nil),
      ListeningQueueChapter(start: 10, end: 10, title: nil),
      ListeningQueueChapter(start: 10, end: 5, title: nil),
      ListeningQueueChapter(start: .nan, end: 5, title: nil),
      ListeningQueueChapter(start: 0, end: .infinity, title: nil),
    ])
  func malformedChapterIsRejected(chapter: ListeningQueueChapter) async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)

    await #expect(throws: ListeningQueueStoreError.chapterInvalid) {
      try await store.append(identity: fixture.book, chapter: chapter)
    }
    await #expect(throws: ListeningQueueStoreError.chapterInvalid) {
      try await store.insertNext(identity: fixture.book, chapter: chapter)
    }
    #expect(await store.fetchQueue().isEmpty)
  }

  // MARK: - Replacing

  @Test("appending the same chapter again is already queued; starts within half a second match")
  func sameChapterIsAlreadyQueued() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.book, chapter: Self.chapterThree)

    let nearlySame = ListeningQueueChapter(start: 600.4, end: 901, title: "Renamed")
    #expect(try await store.append(identity: fixture.book, chapter: nearlySame) == .alreadyQueued)
    #expect(await store.fetchQueue().map(\.chapter) == [Self.chapterThree])
  }

  @Test("appending another chapter of a book queued as chapters adds its own row")
  func anotherChapterAddsARow() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.episode)
    try await store.append(identity: fixture.book, chapter: Self.chapterThree)

    #expect(try await store.append(identity: fixture.book, chapter: Self.chapterFour) == .appended)

    let queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.episode, fixture.book, fixture.book])
    #expect(queue.map(\.chapter) == [nil, Self.chapterThree, Self.chapterFour])
  }

  @Test("appending a chapter onto a queued whole book replaces it with the chapter")
  func chapterReplacesWholeBook() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.book)

    #expect(try await store.append(identity: fixture.book, chapter: Self.chapterThree) == .replaced)
    #expect(await store.fetchQueue().map(\.chapter) == [Self.chapterThree])
  }

  @Test("appending the whole book onto a chapter row clears the chapter in the database")
  func wholeBookReplacesChapterAndClearsItsColumns() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.book, chapter: Self.chapterThree)

    #expect(try await store.append(identity: fixture.book) == .replaced)

    #expect(await store.fetchQueue().map(\.chapter) == [nil])
    let storedChapterValues = try await database.readAsync { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM listeningQueueEntry
          WHERE chapterStart IS NOT NULL OR chapterEnd IS NOT NULL OR chapterTitle IS NOT NULL
          """)
    }
    #expect(storedChapterValues == 0)
    // The whole book again is the ordinary idempotent no-op.
    #expect(try await store.append(identity: fixture.book) == .alreadyQueued)
  }

  @Test("insert-next puts a new chapter row first; the whole book then replaces every row")
  func insertNextMovesAndSetsTheChapter() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.episode)
    try await store.append(identity: fixture.book, chapter: Self.chapterThree)

    try await store.insertNext(identity: fixture.book, chapter: Self.chapterFour)
    var queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.book, fixture.episode, fixture.book])
    #expect(queue.map(\.chapter) == [Self.chapterFour, nil, Self.chapterThree])

    try await store.insertNext(identity: fixture.book)
    queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.book, fixture.episode])
    #expect(queue.map(\.chapter) == [nil, nil])
  }

  @Test("a batch insert-next of a queued chapter's book makes it the whole book")
  func batchInsertNextQueuesWholeBooks() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.book, chapter: Self.chapterThree)

    try await store.insertNext(identities: [fixture.episode, fixture.book])

    let queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.episode, fixture.book])
    #expect(queue.map(\.chapter) == [nil, nil])
  }

  // MARK: - Clear and Undo

  @Test("clear then restore brings chapter rows back with their chapters")
  func clearThenRestoreKeepsChapters() async throws {
    let database = try AppDatabase.inMemory()
    let fixture = try await Self.seed(database)
    let store = ListeningQueueStore(database: database, accountId: fixture.accountId)
    try await store.append(identity: fixture.episode)
    try await store.append(identity: fixture.book, chapter: Self.chapterThree)
    try await store.append(identity: fixture.rssEpisode)

    let token = try await store.clear()
    #expect(await store.fetchQueue().isEmpty)
    try await store.restore(token: token)

    let queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.episode, fixture.book, fixture.rssEpisode])
    #expect(queue.map(\.chapter) == [nil, Self.chapterThree, nil])
  }

  // MARK: - Fixture

  struct Fixture: Sendable {
    let accountId: Int64
    let book: ListeningIdentity
    let episode: ListeningIdentity
    let rssEpisode: ListeningIdentity
  }

  static func seed(_ database: AppDatabase) async throws -> Fixture {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-\(UUID().uuidString)", serverBaseURL: "server", serverUserId: "user",
        serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library", mediaType: "book", name: "Library")
      try library.insert(db)
      var book = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "book", mediaKind: "book",
        title: "Book", sortTitle: "book", author: "Author", numAudioFiles: 4)
      try book.insert(db)
      var show = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "show",
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try show.insert(db)
      var episode = PodcastEpisodeRecord(
        accountId: account.id!, itemId: show.id!, serverEpisodeId: "episode", title: "Episode",
        lastSeenGeneration: 1)
      try episode.insert(db)
      var feed = RSSFeedRecord(
        feedURL: "https://rss.example/feed.xml", title: "Native Show",
        subscribedAt: Date(timeIntervalSince1970: 1_700_000_000), refreshGeneration: 1)
      try feed.insert(db)
      var rssEpisode = RSSEpisodeRecord(
        feedId: feed.id!, identityKey: "rss-episode", title: "Native Episode",
        enclosureURL: "https://rss.example/episode.mp3", lastSeenGeneration: 1)
      try rssEpisode.insert(db)
      let feedID = feed.id!
      return Fixture(
        accountId: account.id!,
        book: try #require(ListeningIdentity.audiobook(itemID: "book")),
        episode: try #require(
          ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode")),
        rssEpisode: try #require(
          ListeningIdentity.rssEpisode(feedID: feedID, episodeID: "rss-episode")))
    }
  }
}
