import Foundation
import TestSupport
import Testing

@testable import Persistence

@Suite("Reader restore lookup")
struct ReaderRestoreLookupTests {

  @Test("returns the current progress for an item resolved by server item id")
  func returnsProgressForMatchingItem() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let item = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "restore-item")
    let expected = try await insertProgress(
      database, accountId: accountId, itemId: try #require(item.id))
    let dao = MediaProgressDAO(database: database)

    let result = try await dao.fetchCurrentForServerItemAsync(
      accountId: accountId, serverItemId: "restore-item")

    #expect(result == expected)
    #expect(result?.readingPositionJSON == "{\"href\":\"Text/chapter.xhtml\"}")
    #expect(result?.ebookProgress == 0.42)
  }

  @Test("returns nil for an unknown server item id")
  func returnsNilForUnknownServerItemId() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, _) = try await insertAccountAndLibrary(database)
    let dao = MediaProgressDAO(database: database)

    let result = try await dao.fetchCurrentForServerItemAsync(
      accountId: accountId, serverItemId: "missing-item")

    #expect(result == nil)
  }

  @Test("returns nil when the item exists without a progress row")
  func returnsNilWhenProgressIsMissing() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    _ = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "no-progress")
    let dao = MediaProgressDAO(database: database)

    let result = try await dao.fetchCurrentForServerItemAsync(
      accountId: accountId, serverItemId: "no-progress")

    #expect(result == nil)
  }

  @Test("returns progress for a soft-deleted item")
  func includesSoftDeletedItem() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let item = try await insertItem(
      database,
      accountId: accountId,
      libraryId: libraryId,
      serverItemId: "soft-deleted-item",
      softDeleted: true)
    let expected = try await insertProgress(
      database, accountId: accountId, itemId: try #require(item.id))
    let dao = MediaProgressDAO(database: database)

    let result = try await dao.fetchCurrentForServerItemAsync(
      accountId: accountId, serverItemId: "soft-deleted-item")

    #expect(result == expected)
  }

  @Test("matches the existing two-read item and progress lookup")
  func equalsTwoReadComposition() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)
    let item = try await insertItem(
      database, accountId: accountId, libraryId: libraryId, serverItemId: "equivalent-item")
    _ = try await insertProgress(
      database, accountId: accountId, itemId: try #require(item.id))
    let itemDAO = ItemDAO(database: database)
    let progressDAO = MediaProgressDAO(database: database)

    let twoReadResult: MediaProgressRecord?
    if let resolvedItem = try itemDAO.fetchOne(
      accountId: accountId, serverItemId: "equivalent-item"), let itemId = resolvedItem.id
    {
      twoReadResult = try await progressDAO.fetchCurrentAsync(
        accountId: accountId, identity: .item(itemId: itemId))
    } else {
      twoReadResult = nil
    }

    let singleReadResult = try await progressDAO.fetchCurrentForServerItemAsync(
      accountId: accountId, serverItemId: "equivalent-item")

    #expect(singleReadResult == twoReadResult)
  }

  private func insertAccountAndLibrary(_ database: AppDatabase) async throws -> (
    accountId: Int64, libraryId: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString,
        serverBaseURL: "https://example.com",
        serverUserId: "restore-user",
        serverVersion: "2.35.1")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: try #require(account.id),
        serverLibraryId: "restore-library",
        mediaType: "book",
        name: "Restore Library")
      try library.insert(db)
      return (try #require(account.id), try #require(library.id))
    }
  }

  private func insertItem(
    _ database: AppDatabase,
    accountId: Int64,
    libraryId: Int64,
    serverItemId: String,
    softDeleted: Bool = false
  ) async throws -> ItemRecord {
    try await ItemDAO(database: database).upsertAsync(
      PersistenceFixtures.item(
        accountId: accountId,
        libraryId: libraryId,
        serverItemId: serverItemId,
        mediaKind: "book",
        title: "Restore Item",
        sortTitle: "restore item",
        softDeleted: softDeleted))
  }

  private func insertProgress(
    _ database: AppDatabase,
    accountId: Int64,
    itemId: Int64
  ) async throws -> MediaProgressRecord {
    try await database.writeAsync { db in
      var progress = MediaProgressRecord(
        accountId: accountId,
        itemId: itemId,
        currentTime: 123.5,
        isFinished: false,
        hideFromContinueListening: true,
        serverUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        localSequence: 7,
        origin: .local,
        originKey: "restore-client",
        readingPositionJSON: "{\"href\":\"Text/chapter.xhtml\"}",
        ebookProgress: 0.42,
        ebookLocation: "epubcfi(/6/2)",
        lastActivityAt: Date(timeIntervalSince1970: 1_700_000_100))
      try progress.insert(db)
      return progress
    }
  }
}
