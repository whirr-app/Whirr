import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite struct EbookTableOfContentsAccessTests {
  @Test("an unseen item has no stored contents")
  func unseenItemHasNoStoredContents() async throws {
    let fixture = try await Self.makeFixture()

    #expect(try await fixture.access.fetchTableOfContents(itemId: "item-1").isEmpty)
  }

  @Test("a stored table of contents round-trips in flattened order")
  func storedTableOfContentsRoundTrips() async throws {
    let fixture = try await Self.makeFixture()
    let entries = [
      StoredEbookTOCEntry(
        position: 0, title: "Part One", href: "part1.xhtml", depth: 0, startProgression: 0),
      StoredEbookTOCEntry(
        position: 1, title: "Chapter 1", href: "ch1.xhtml#start", depth: 1, startProgression: 0.05),
      StoredEbookTOCEntry(
        position: 2, title: "Chapter 2", href: nil, depth: 1, startProgression: nil),
    ]

    try await fixture.access.storeTableOfContents(entries, itemId: "item-1")

    #expect(try await fixture.access.fetchTableOfContents(itemId: "item-1") == entries)
  }

  @Test("re-storing replaces the previous snapshot rather than appending to it")
  func reStoringReplacesThePreviousSnapshot() async throws {
    let fixture = try await Self.makeFixture()
    try await fixture.access.storeTableOfContents(
      [
        StoredEbookTOCEntry(
          position: 0, title: "Old A", href: "a.xhtml", depth: 0, startProgression: 0),
        StoredEbookTOCEntry(
          position: 1, title: "Old B", href: "b.xhtml", depth: 0, startProgression: 0.5),
      ], itemId: "item-1")

    let replacement = [
      StoredEbookTOCEntry(position: 0, title: "New", href: "n.xhtml", depth: 0, startProgression: 0)
    ]
    try await fixture.access.storeTableOfContents(replacement, itemId: "item-1")

    #expect(try await fixture.access.fetchTableOfContents(itemId: "item-1") == replacement)
  }

  @Test("one item's contents are invisible to another")
  func contentsAreScopedToTheirItem() async throws {
    let fixture = try await Self.makeFixture()
    try await fixture.insertItem(serverItemId: "item-2")
    try await fixture.access.storeTableOfContents(
      [
        StoredEbookTOCEntry(
          position: 0, title: "Only mine", href: "a.xhtml", depth: 0, startProgression: 0)
      ], itemId: "item-1")

    #expect(try await fixture.access.fetchTableOfContents(itemId: "item-2").isEmpty)
  }

  @Test("storing against an unknown item is a no-op rather than a throw")
  func storingAgainstAnUnknownItemIsANoOp() async throws {
    let fixture = try await Self.makeFixture()

    try await fixture.access.storeTableOfContents(
      [
        StoredEbookTOCEntry(
          position: 0, title: "Ghost", href: "g.xhtml", depth: 0, startProgression: 0)
      ], itemId: "missing")

    #expect(try await fixture.access.fetchTableOfContents(itemId: "missing").isEmpty)
  }

  /// The contents snapshot belongs to its item: a purged item must not leave orphan rows behind
  /// that a later item reusing the same row id could inherit.
  @Test("deleting the item cascades its contents away")
  func deletingTheItemCascadesItsContents() async throws {
    let fixture = try await Self.makeFixture()
    try await fixture.access.storeTableOfContents(
      [
        StoredEbookTOCEntry(
          position: 0, title: "Chapter 1", href: "ch1.xhtml", depth: 0, startProgression: 0)
      ], itemId: "item-1")

    try await fixture.database.writeAsync { db in
      _ = try ItemRecord.filter(Column("serverItemId") == "item-1").deleteAll(db)
    }

    let remaining = try await fixture.database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ebookTOCEntry") ?? -1
    }
    #expect(remaining == 0)
  }

  @Test("an empty snapshot clears the stored contents")
  func anEmptySnapshotClearsTheStoredContents() async throws {
    let fixture = try await Self.makeFixture()
    try await fixture.access.storeTableOfContents(
      [
        StoredEbookTOCEntry(
          position: 0, title: "Chapter 1", href: "ch1.xhtml", depth: 0, startProgression: 0)
      ], itemId: "item-1")

    try await fixture.access.storeTableOfContents([], itemId: "item-1")

    #expect(try await fixture.access.fetchTableOfContents(itemId: "item-1").isEmpty)
  }

  // MARK: - Fixture

  private struct Fixture {
    let database: AppDatabase
    let access: DefaultEbookTableOfContentsAccess
    let accountId: Int64
    let libraryId: Int64

    func insertItem(serverItemId: String) async throws {
      try await database.writeAsync { [accountId, libraryId] db in
        var item = PersistenceFixtures.item(
          accountId: accountId,
          libraryId: libraryId,
          serverItemId: serverItemId,
          mediaKind: "book",
          title: serverItemId,
          sortTitle: serverItemId,
          ebookFormat: "epub")
        try item.insert(db)
      }
    }
  }

  private static func makeFixture() async throws -> Fixture {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString,
        serverBaseURL: "https://example.com",
        serverUserId: "user",
        serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library", mediaType: "book", name: "Library")
      try library.insert(db)
      var item = ItemRecord(
        accountId: account.id!,
        libraryId: library.id!,
        serverItemId: "item-1",
        mediaKind: "book",
        title: "Book",
        sortTitle: "book",
        ebookFormat: "epub")
      try item.insert(db)
      return (account.id!, library.id!)
    }
    return Fixture(
      database: database,
      access: DefaultEbookTableOfContentsAccess(database: database),
      accountId: accountId,
      libraryId: libraryId)
  }
}
