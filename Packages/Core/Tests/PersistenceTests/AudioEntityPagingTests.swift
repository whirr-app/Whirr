import Foundation
import GRDB
import Testing

@testable import Persistence

/// Authors and series as a small screen pages them: derived from the audiobooks on the device,
/// so every row has something to play and the lists work without a connection.
@Suite struct AudioEntityPagingTests {

  @Test func authorsAreTheIndividualNamesOfAudiobooksInNameOrder() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    try await database.writeAsync { db in
      try Self.insert(db, scope: scope, id: "a", author: "Terry Pratchett, Neil Gaiman")
      try Self.insert(db, scope: scope, id: "b", author: "Terry Pratchett")
      try Self.insert(db, scope: scope, id: "c", author: "ursula K. Le Guin")
      try Self.insert(db, scope: scope, id: "d", author: nil)
      try Self.insert(db, scope: scope, id: "e", author: "  ")
    }

    let page = try await DefaultAudioBrowsePaging(database: database)
      .entityPage(kind: .author, after: nil, limit: 10)

    #expect(page.rows.map(\.name) == ["Neil Gaiman", "Terry Pratchett", "ursula K. Le Guin"])
    #expect(page.rows.map(\.bookCount) == [1, 2, 1])
    #expect(page.next == nil)
  }

  @Test func entitiesWithNoListableAudiobookAreLeftOut() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    try await database.writeAsync { db in
      try Self.insert(db, scope: scope, id: "audio", author: "Heard", series: "Kept #1")
      try Self.insert(db, scope: scope, id: "mixed", author: "Both", series: "Kept #2", audioFiles: 2, ebook: "epub")
      try Self.insert(
        db, scope: scope, id: "ebook", author: "Read Only", series: "Paper #1", audioFiles: 0, ebook: "epub")
      try Self.insert(db, scope: scope, id: "gone", author: "Removed", series: "Gone #1", softDeleted: true)
      try Self.insert(
        db, scope: scope, id: "hidden", author: "Excluded", series: "Hidden #1",
        libraryId: scope.excludedLibraryId)
      try Self.insert(db, scope: scope, id: "show", author: "Host", mediaKind: "podcast")
    }
    let paging = DefaultAudioBrowsePaging(database: database)

    let authors = try await paging.entityPage(kind: .author, after: nil, limit: 10)
    let series = try await paging.entityPage(kind: .series, after: nil, limit: 10)

    #expect(authors.rows.map(\.name) == ["Both", "Heard"])
    #expect(series.rows.map(\.name) == ["Kept"])
    #expect(series.rows.map(\.bookCount) == [2])
  }

  @Test func pagingVisitsEveryEntityOnceAndOnlyTheLastPageIsShort() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    let names = (0..<23).map { String(format: "Author %02d", $0) }
    try await database.writeAsync { db in
      // Inserted out of name order, each author on two books.
      for (index, name) in names.reversed().enumerated() {
        try Self.insert(db, scope: scope, id: "x\(index)", author: name)
        try Self.insert(db, scope: scope, id: "y\(index)", author: "\(name), Author 00")
      }
    }
    let paging = DefaultAudioBrowsePaging(database: database)

    var seen: [String] = []
    var cursor: AudioEntityCursor?
    var pages = 0
    repeat {
      let page = try await paging.entityPage(kind: .author, after: cursor, limit: 5)
      #expect(page.rows.count == 5 || page.next == nil)
      seen += page.rows.map(\.name)
      cursor = page.next
      pages += 1
    } while cursor != nil && pages < 50

    #expect(seen == names)
    #expect(pages == 5)
  }

  @Test func aCursorFromTheOtherKindIsRefused() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    try await database.writeAsync { db in
      for index in 0..<3 {
        try Self.insert(db, scope: scope, id: "b\(index)", author: "Author \(index)", series: "Series \(index) #1")
      }
    }
    let paging = DefaultAudioBrowsePaging(database: database)
    let authors = try await paging.entityPage(kind: .author, after: nil, limit: 1)

    await #expect(throws: AudioBrowsePagingError.staleCursor) {
      _ = try await paging.entityPage(kind: .series, after: authors.next, limit: 1)
    }
  }

  @Test func anAuthorsBooksAreExactlyTheirsInTitleOrder() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    try await database.writeAsync { db in
      try Self.insert(db, scope: scope, id: "solo", sortTitle: "b", author: "Ann Lee")
      try Self.insert(db, scope: scope, id: "shared", sortTitle: "a", author: "Bo Chen, Ann Lee")
      // A longer name that contains the one asked for is another author.
      try Self.insert(db, scope: scope, id: "other", sortTitle: "c", author: "Joann Lee")
      try Self.insert(db, scope: scope, id: "ebook", sortTitle: "d", author: "Ann Lee", audioFiles: 0, ebook: "epub")
    }

    let page = try await DefaultAudioBrowsePaging(database: database)
      .entityBookPage(kind: .author, name: "Ann Lee", after: nil, limit: 10)

    #expect(page.rows.map(\.identity.itemID) == ["shared", "solo"])
    #expect(page.rows.map(\.seriesSequence) == [nil, nil])
    #expect(page.next == nil)
  }

  @Test func aSeriesReadsInSequenceOrderWithUnnumberedBooksLast() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    try await database.writeAsync { db in
      try Self.insert(db, scope: scope, id: "ten", sortTitle: "a", series: "Saga #10")
      try Self.insert(db, scope: scope, id: "two", sortTitle: "z", series: "Other #7, Saga #2")
      try Self.insert(db, scope: scope, id: "half", sortTitle: "m", series: "Saga #1.5")
      try Self.insert(db, scope: scope, id: "extra", sortTitle: "b", series: "Saga")
      try Self.insert(db, scope: scope, id: "prequel", sortTitle: "c", series: "Saga Prequels #1")
    }
    let paging = DefaultAudioBrowsePaging(database: database)

    let first = try await paging.entityBookPage(kind: .series, name: "Saga", after: nil, limit: 3)
    let second = try await paging.entityBookPage(kind: .series, name: "Saga", after: first.next, limit: 3)

    #expect(first.rows.map(\.identity.itemID) == ["half", "two", "ten"])
    #expect(first.rows.map(\.seriesSequence) == ["1.5", "2", "10"])
    #expect(second.rows.map(\.identity.itemID) == ["extra"])
    #expect(second.next == nil)
  }

  @Test func aBookCursorWhoseRowHasGoneIsRefused() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    try await database.writeAsync { db in
      for index in 0..<4 {
        try Self.insert(db, scope: scope, id: "b\(index)", sortTitle: "t\(index)", author: "Ann Lee")
      }
    }
    let paging = DefaultAudioBrowsePaging(database: database)
    let first = try await paging.entityBookPage(kind: .author, name: "Ann Lee", after: nil, limit: 2)
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE item SET softDeleted = 1 WHERE serverItemId = 'b1'")
    }

    await #expect(throws: AudioBrowsePagingError.staleCursor) {
      _ = try await paging.entityBookPage(kind: .author, name: "Ann Lee", after: first.next, limit: 2)
    }
    await #expect(throws: AudioBrowsePagingError.staleCursor) {
      _ = try await paging.entityBookPage(kind: .author, name: "Bo Chen", after: first.next, limit: 2)
    }
  }

  @Test func anEightThousandItemLibraryListsItsAuthorsAPageAtATime() async throws {
    let database = try AppDatabase.inMemory()
    let scope = try await Self.seedScope(database)
    try await database.writeAsync { db in
      for index in 0..<8_000 {
        try Self.insert(
          db, scope: scope, id: "item-\(index)", sortTitle: "t\(index)",
          author: "Author \(index % 900), Author \((index * 7) % 900)", series: "Series \(index % 400) #\(index % 9)")
      }
    }
    let paging = DefaultAudioBrowsePaging(database: database)

    let page = try await paging.entityPage(kind: .author, after: nil, limit: 40)

    #expect(page.rows.count == 40)
    #expect(page.next != nil)
  }

  // MARK: Fixtures

  private struct Scope: Sendable {
    let accountId: Int64
    let libraryId: Int64
    let excludedLibraryId: Int64
  }

  private static func seedScope(_ database: AppDatabase) async throws -> Scope {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "entity-client", serverBaseURL: "https://example.test",
        serverUserId: "entity-user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "books", mediaType: "book", name: "Books")
      try library.insert(db)
      var excluded = LibraryRecord(
        accountId: account.id!, serverLibraryId: "other", mediaType: "book", name: "Other",
        isIncluded: false)
      try excluded.insert(db)
      return Scope(accountId: account.id!, libraryId: library.id!, excludedLibraryId: excluded.id!)
    }
  }

  private static func insert(
    _ db: Database, scope: Scope, id: String, sortTitle: String? = nil, author: String? = "Author",
    series: String? = nil, mediaKind: String = "book", audioFiles: Int = 1, ebook: String? = nil,
    softDeleted: Bool = false, libraryId: Int64? = nil
  ) throws {
    var item = ItemRecord(
      accountId: scope.accountId, libraryId: libraryId ?? scope.libraryId, serverItemId: id,
      mediaKind: mediaKind, title: "Title \(id)", sortTitle: sortTitle ?? id, author: author,
      numAudioFiles: audioFiles, ebookFormat: ebook, seriesName: series, softDeleted: softDeleted)
    try item.insert(db)
  }
}
