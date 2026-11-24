import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct AuthorSeriesEntityStoreTests {
  @Test func emptySnapshotIsCachedAndReplacementIsAuthoritative() async throws {
    let fixture = try await Self.fixture()
    let store = AuthorSeriesEntityStore(database: fixture.database)

    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books",
      entries: [
        AuthorSeriesSnapshotEntry(
          kind: .author, entityID: "a-1", name: "J. N. Chaney", bookCount: 2),
        AuthorSeriesSnapshotEntry(kind: .series, entityID: "s-1", name: "Ruins"),
      ])
    #expect(await store.hasSnapshot(accountID: fixture.accountID, libraryID: "books"))
    #expect(
      await store.entities(accountID: fixture.accountID, kind: .author, libraryIDs: ["books"])
        .map(\.name) == ["J. N. Chaney"])

    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "books", entries: [])
    #expect(await store.hasSnapshot(accountID: fixture.accountID, libraryID: "books"))
    #expect(
      await store.entities(accountID: fixture.accountID, kind: .author, libraryIDs: ["books"])
        .isEmpty)
  }

  @Test func mergesSpellingVariantsAcrossLibrariesInLibraryOrder() async throws {
    let fixture = try await Self.fixture(libraryIDs: ["audio", "ebooks"])
    let store = AuthorSeriesEntityStore(database: fixture.database)
    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "audio",
      entries: [
        AuthorSeriesSnapshotEntry(
          kind: .author, entityID: "audio-author", name: "J. N. Chaney", bookCount: 2)
      ])
    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "ebooks",
      entries: [
        AuthorSeriesSnapshotEntry(
          kind: .author, entityID: "ebook-author", name: "JN Chaney", bookCount: 3)
      ])

    let entities = await store.entities(
      accountID: fixture.accountID, kind: .author, libraryIDs: ["audio", "ebooks"])
    let entity = try #require(entities.first)
    #expect(entity.name == "J. N. Chaney")
    #expect(entity.identities.map(\.entityID) == ["audio-author", "ebook-author"])
    #expect(entity.bookCount == 5)
  }

  @Test func excludedLibrarySnapshotsAreNeitherReadNorReplaced() async throws {
    let fixture = try await Self.fixture(libraryIDs: ["included", "excluded"])
    let store = AuthorSeriesEntityStore(database: fixture.database)
    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "included",
      entries: [AuthorSeriesSnapshotEntry(kind: .author, entityID: "included-author", name: "Included")])
    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "excluded",
      entries: [AuthorSeriesSnapshotEntry(kind: .author, entityID: "excluded-author", name: "Excluded")])
    try await fixture.database.writeAsync { db in
      try LibraryRecord
        .filter(Column("accountId") == fixture.accountID)
        .filter(Column("serverLibraryId") == "excluded")
        .updateAll(db, Column("isIncluded").set(to: false))
    }

    #expect(await store.hasSnapshot(accountID: fixture.accountID, libraryID: "excluded") == false)
    #expect(
      await store.entities(
        accountID: fixture.accountID, kind: .author, libraryIDs: ["included", "excluded"]
      )
      .map(\.name) == ["Included"])

    try await store.replaceSnapshot(
      accountID: fixture.accountID, libraryID: "excluded",
      entries: [AuthorSeriesSnapshotEntry(kind: .author, entityID: "new-excluded", name: "New excluded")])
    #expect(
      await store.entities(accountID: fixture.accountID, kind: .author, libraryIDs: ["excluded"])
        .isEmpty)
  }

  private static func fixture(libraryIDs: [String] = ["books"]) async throws
    -> (database: AppDatabase, accountID: Int64)
  {
    let database = try AppDatabase.inMemory()
    let accountID = try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user", serverVersion: "2.35.1")
      try account.insert(db)
      for libraryID in libraryIDs {
        var library = LibraryRecord(
          accountId: account.id!, serverLibraryId: libraryID, mediaType: "book", name: libraryID)
        try library.insert(db)
      }
      return account.id!
    }
    return (database, accountID)
  }
}
