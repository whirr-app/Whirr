import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// `ListeningHistoryDAO`: cached per-item listening-session history
/// (`GET /api/me/listening-sessions`, API-CONVENTIONS.md rule 6a), upserted by account + item +
/// server session id, read back newest-first for the item detail screen's History list.
@Suite struct ListeningHistoryDAOTests {

  @Test func upsertInsertsANewRowAndFetchAllOrdersNewestSessionFirst() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, itemId) = try await Self.insertAccountAndItem(database)
    let dao = ListeningHistoryDAO(database: database)

    try dao.upsert(
      ListeningHistoryEntryRecord(
        accountId: accountId, itemId: itemId, sessionId: "session-1",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000), startPosition: 0, endPosition: 120,
        listenedSeconds: 120))
    try dao.upsert(
      ListeningHistoryEntryRecord(
        accountId: accountId, itemId: itemId, sessionId: "session-2",
        startedAt: Date(timeIntervalSince1970: 1_700_010_000), startPosition: 120, endPosition: 400,
        listenedSeconds: 280))

    let entries = try dao.fetchAll(accountId: accountId, itemId: itemId)

    #expect(entries.map(\.sessionId) == ["session-2", "session-1"])
    #expect(entries.map(\.startPosition) == [120, 0])
    #expect(entries.map(\.endPosition) == [400, 120])
    #expect(entries.map(\.listenedSeconds) == [280, 120])
  }

  @Test func upsertUpdatesTheExistingRowForTheSameAccountItemAndSessionRatherThanDuplicating() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, itemId) = try await Self.insertAccountAndItem(database)
    let dao = ListeningHistoryDAO(database: database)

    let inserted = try dao.upsert(
      ListeningHistoryEntryRecord(
        accountId: accountId, itemId: itemId, sessionId: "session-1",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000), startPosition: 0, endPosition: 100,
        listenedSeconds: 100))
    let updated = try dao.upsert(
      ListeningHistoryEntryRecord(
        accountId: accountId, itemId: itemId, sessionId: "session-1",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000), startPosition: 0, endPosition: 250,
        listenedSeconds: 250))

    #expect(updated.id == inserted.id)
    let entries = try dao.fetchAll(accountId: accountId, itemId: itemId)
    #expect(entries.count == 1)
    #expect(entries.first?.endPosition == 250)
    #expect(entries.first?.listenedSeconds == 250)
  }

  @Test func fetchAllNeverCrossesItemsOrAccounts() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, itemId) = try await Self.insertAccountAndItem(database)
    let (otherAccountId, otherItemInOtherAccount) = try await Self.insertAccountAndItem(
      database, serverUserId: "user-2", serverItemId: "item-other-account")
    let otherItemId = try await Self.insertItem(database, accountId: accountId, serverItemId: "item-2")
    let dao = ListeningHistoryDAO(database: database)

    try dao.upsert(
      ListeningHistoryEntryRecord(
        accountId: accountId, itemId: itemId, sessionId: "session-1",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000), startPosition: 0, endPosition: 100,
        listenedSeconds: 100))
    try dao.upsert(
      ListeningHistoryEntryRecord(
        accountId: accountId, itemId: otherItemId, sessionId: "session-2",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000), startPosition: 0, endPosition: 50,
        listenedSeconds: 50))
    try dao.upsert(
      ListeningHistoryEntryRecord(
        accountId: otherAccountId, itemId: otherItemInOtherAccount, sessionId: "session-3",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000), startPosition: 0, endPosition: 75,
        listenedSeconds: 75))

    let entries = try dao.fetchAll(accountId: accountId, itemId: itemId)

    #expect(entries.map(\.sessionId) == ["session-1"])
  }

  @Test func fetchAllIsEmptyWhenNoHistoryExistsForTheItem() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, itemId) = try await Self.insertAccountAndItem(database)
    let dao = ListeningHistoryDAO(database: database)

    #expect(try dao.fetchAll(accountId: accountId, itemId: itemId).isEmpty)
  }

  // MARK: - Helpers

  private static func insertAccountAndItem(
    _ database: AppDatabase, serverUserId: String = "user-1", serverItemId: String = "item-1"
  ) async throws -> (accountId: Int64, itemId: Int64) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: serverUserId, serverVersion: "2.35.1")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)

      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: serverItemId, mediaKind: "book",
        title: "Title", sortTitle: "title")
      try item.insert(db)

      return (account.id!, item.id!)
    }
  }

  private static func insertItem(_ database: AppDatabase, accountId: Int64, serverItemId: String) async throws -> Int64
  {
    try await database.writeAsync { db in
      let library = try LibraryRecord.filter(Column("accountId") == accountId).fetchOne(db)!
      var item = PersistenceFixtures.item(
        accountId: accountId, libraryId: library.id!, serverItemId: serverItemId, mediaKind: "book",
        title: "Title 2", sortTitle: "title 2")
      try item.insert(db)
      return item.id!
    }
  }
}
