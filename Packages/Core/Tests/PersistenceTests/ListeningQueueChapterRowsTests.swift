import Foundation
import GRDB
import Testing

@testable import Persistence

/// A book may be queued as several chapter rows.
/// Edits name the row; a start consumes the whole-book row and the one chapter row it played.
@Suite struct ListeningQueueChapterRowsTests {
  private typealias Seed = ListeningQueueChapterStoreTests
  private static let one = ListeningQueueChapter(start: 0, end: 300, title: "One")
  private static let two = ListeningQueueChapter(start: 300, end: 600, title: "Two")
  private static let three = ListeningQueueChapter(start: 600, end: 900, title: "Three")
  private static let declinedAt = Date(timeIntervalSince1970: 1_700_000_000)

  private static func store() async throws -> (
    ListeningQueueStore, ListeningQueueChapterStoreTests.Fixture, AppDatabase
  ) {
    let database = try AppDatabase.inMemory()
    let fixture = try await Seed.seed(database)
    return (ListeningQueueStore(database: database, accountId: fixture.accountId), fixture, database)
  }

  // MARK: - Insertion

  @Test("several chapters of one book each take their own row, in the order added")
  func chaptersCoexist() async throws {
    let (store, fixture, _) = try await Self.store()
    #expect(try await store.append(identity: fixture.book, chapter: Self.two) == .appended)
    try await store.append(identity: fixture.episode)
    #expect(try await store.append(identity: fixture.book, chapter: Self.one) == .appended)

    let queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.book, fixture.episode, fixture.book])
    #expect(queue.map(\.chapter) == [Self.two, nil, Self.one])
    #expect(Set(queue.map(\.id)).count == 3)
    #expect(queue.map(\.rowChapter?.rowID) == [queue[0].id, nil, queue[2].id])
  }

  @Test("a chapter already queued, within tolerance, is already queued")
  func sameChapterIsAlreadyQueued() async throws {
    let (store, fixture, _) = try await Self.store()
    try await store.append(identity: fixture.book, chapter: Self.one)
    try await store.append(identity: fixture.book, chapter: Self.two)

    let nearlyTwo = ListeningQueueChapter(start: 300.4, end: 601, title: "Renamed")
    #expect(try await store.append(identity: fixture.book, chapter: nearlyTwo) == .alreadyQueued)
    #expect(await store.fetchQueue().map(\.chapter) == [Self.one, Self.two])
  }

  @Test("the whole book replaces every chapter row, in the first one's place")
  func wholeBookCollapsesChapterRows() async throws {
    let (store, fixture, _) = try await Self.store()
    try await store.append(identity: fixture.episode)
    try await store.append(identity: fixture.book, chapter: Self.one)
    try await store.append(identity: fixture.rssEpisode)
    try await store.append(identity: fixture.book, chapter: Self.two)

    #expect(try await store.append(identity: fixture.book) == .replaced)

    let queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.episode, fixture.book, fixture.rssEpisode])
    #expect(queue.map(\.chapter) == [nil, nil, nil])
    #expect(queue.map(\.position) == [0, 1, 2])
  }

  @Test("insert-next of a queued chapter moves that row first and leaves the others")
  func insertNextMovesTheSameChapter() async throws {
    let (store, fixture, _) = try await Self.store()
    try await store.append(identity: fixture.book, chapter: Self.one)
    try await store.append(identity: fixture.episode)
    try await store.append(identity: fixture.book, chapter: Self.three)
    let threeRow = try #require(await store.fetchQueue().last?.id)

    try await store.insertNext(identity: fixture.book, chapter: Self.three)

    let queue = await store.fetchQueue()
    #expect(queue.map(\.id).first == threeRow)
    #expect(queue.map(\.chapter) == [Self.three, Self.one, nil])
  }

  @Test("a batch insert-next queues a chaptered book whole, first")
  func batchInsertNextCollapsesToTheWholeBook() async throws {
    let (store, fixture, _) = try await Self.store()
    try await store.append(identity: fixture.episode)
    try await store.append(identity: fixture.book, chapter: Self.one)
    try await store.append(identity: fixture.book, chapter: Self.two)

    try await store.insertNext(identities: [fixture.book])

    let queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.book, fixture.episode])
    #expect(queue.map(\.chapter) == [nil, nil])
  }

  // MARK: - Row-keyed edits

  @Test("removing a row removes that chapter only; removing the title removes every row")
  func removeByRowAndByTitle() async throws {
    let (store, fixture, _) = try await Self.store()
    try await store.append(identity: fixture.book, chapter: Self.one)
    try await store.append(identity: fixture.book, chapter: Self.two)
    try await store.append(identity: fixture.book, chapter: Self.three)
    try await store.append(identity: fixture.episode)
    let rows = await store.fetchQueue()

    try await store.remove(rowID: rows[1].id)
    #expect(await store.fetchQueue().map(\.chapter) == [Self.one, Self.three, nil])

    try await store.remove(identity: fixture.book)
    #expect(await store.fetchQueue().map(\.identity) == [fixture.episode])
  }

  @Test("moving a row moves that chapter only")
  func moveByRow() async throws {
    let (store, fixture, _) = try await Self.store()
    try await store.append(identity: fixture.book, chapter: Self.one)
    try await store.append(identity: fixture.episode)
    try await store.append(identity: fixture.book, chapter: Self.two)
    let rows = await store.fetchQueue()

    try await store.move(rowID: rows[2].id, to: 0)

    let queue = await store.fetchQueue()
    #expect(queue.map(\.chapter) == [Self.two, Self.one, nil])
    #expect(queue.map(\.position) == [0, 1, 2])
  }

  // MARK: - Consumption

  @Test("a start names its chapter row: that row goes and the book's other chapters stay")
  func acknowledgingAChapterRowConsumesOnlyIt() async throws {
    let (store, fixture, _) = try await Self.store()
    try await store.append(identity: fixture.book, chapter: Self.one)
    try await store.append(identity: fixture.book, chapter: Self.two)
    let rows = await store.fetchQueue()

    try await store.acknowledgeStarted(identity: fixture.book, rowID: rows[0].id)

    #expect(await store.fetchQueue().map(\.id) == [rows[1].id])
  }

  @Test("a start from outside Up Next consumes the whole-book row and no chapter row")
  func acknowledgingWithoutARowLeavesChapterRows() async throws {
    let (store, fixture, _) = try await Self.store()
    try await store.append(identity: fixture.book, chapter: Self.one)
    try await store.append(identity: fixture.book, chapter: Self.two)

    try await store.acknowledgeStarted(identity: fixture.book, rowID: nil)
    #expect(await store.fetchQueue().map(\.chapter) == [Self.one, Self.two])

    try await store.append(identity: fixture.episode)
    try await store.acknowledgeStarted(identity: fixture.episode, rowID: nil)
    #expect(await store.fetchQueue().map(\.identity) == [fixture.book, fixture.book])
  }

  @Test("a start that consumes nothing leaves the queue revision alone")
  func unchangedAcknowledgementKeepsTheRevision() async throws {
    let (store, fixture, _) = try await Self.store()
    try await store.append(identity: fixture.book, chapter: Self.one)
    let token = try await store.clear()
    try await store.acknowledgeStarted(identity: fixture.book, rowID: nil)
    try await store.restore(token: token)

    #expect(await store.fetchQueue().map(\.chapter) == [Self.one], "the Undo token still holds")
  }

  // MARK: - Download declines

  @Test("a new chapter row of a declined book inherits the decline")
  func newChapterRowInheritsTheDecline() async throws {
    let (store, fixture, database) = try await Self.store()
    try await store.append(identity: fixture.book, chapter: Self.one)
    try await store.declineDownloads(itemID: "book", episodeID: nil, at: Self.declinedAt)

    try await store.append(identity: fixture.book, chapter: Self.two)
    try await store.insertNext(identity: fixture.book, chapter: Self.three)

    let declined = try await database.readAsync { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM listeningQueueEntry WHERE downloadDeclinedAt IS NOT NULL")
    }
    #expect(declined == 3)
    #expect(try await store.isDownloadDeclined(fixture.book))

    try await store.append(identity: fixture.book)
    #expect(try await store.isDownloadDeclined(fixture.book), "collapsing to the whole book keeps it")
  }

  @Test("a book queued as several chapters is one download candidate")
  func chapterRowsAreOneCandidate() async throws {
    let (store, fixture, _) = try await Self.store()
    try await store.append(identity: fixture.book, chapter: Self.one)
    try await store.append(identity: fixture.episode)
    try await store.append(identity: fixture.book, chapter: Self.two)

    #expect(
      try await store.fetchQueueIdentitiesWithoutDownloads() == [fixture.book, fixture.episode])
  }

  // MARK: - Schema

  @Test("v107 keeps every queued row and lets a book hold several chapter rows")
  func v107UpgradesInPlace() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in SchemaV1.registerSearchFunctions(db) }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v105")
    try queue.write { db in
      try db.execute(
        sql:
          "INSERT INTO account (clientUUID, serverBaseURL, serverUserId, serverVersion) VALUES ('c', 's', 'u', '2.35.1')"
      )
      let account = db.lastInsertedRowID
      try db.execute(
        sql: "INSERT INTO library (accountId, serverLibraryId, mediaType, name) VALUES (?, 'l', 'book', 'L')",
        arguments: [account])
      let library = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO item (accountId, libraryId, serverItemId, mediaKind, title, sortTitle)
          VALUES (?, ?, 'book', 'book', 'Book', 'book')
          """, arguments: [account, library])
      let item = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO listeningQueueEntry (accountId, itemId, position, chapterStart, chapterEnd)
          VALUES (?, ?, 0, 600, 900)
          """, arguments: [account, item])
    }

    try SchemaV1.migrator().migrate(queue)

    try queue.write { db in
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningQueueEntry") == 1)
      try db.execute(
        sql: """
          INSERT INTO listeningQueueEntry (accountId, itemId, position, chapterStart, chapterEnd)
          SELECT accountId, itemId, 1, 900, 1200 FROM listeningQueueEntry
          """)
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningQueueEntry") == 2)
      let names = Set(try db.indexes(on: "listeningQueueEntry").filter(\.isUnique).map(\.name))
      #expect(
        names.isSuperset(of: [
          "index_listeningQueueEntry_on_account_item",
          "index_listeningQueueEntry_on_account_item_chapter",
        ]))
    }
  }

  @Test("the database refuses a second whole-book row or a second row at one chapter start")
  func uniqueIndexesHoldTheRowShape() async throws {
    let (store, fixture, database) = try await Self.store()
    try await store.append(identity: fixture.book, chapter: Self.one)
    let row = try #require(await store.fetchQueue().first)
    #expect(throws: DatabaseError.self) {
      try database.write { db in
        try db.execute(
          sql: """
            INSERT INTO listeningQueueEntry (accountId, itemId, position, chapterStart, chapterEnd)
            SELECT accountId, itemId, position + 1, chapterStart, chapterEnd
            FROM listeningQueueEntry WHERE id = ?
            """, arguments: [row.id])
      }
    }

    try await store.append(identity: fixture.book)
    let whole = try #require(await store.fetchQueue().first)
    #expect(whole.chapter == nil)
    #expect(throws: DatabaseError.self) {
      try database.write { db in
        try db.execute(
          sql: """
            INSERT INTO listeningQueueEntry (accountId, itemId, position)
            SELECT accountId, itemId, position + 1 FROM listeningQueueEntry WHERE id = ?
            """, arguments: [whole.id])
      }
    }
  }
}
