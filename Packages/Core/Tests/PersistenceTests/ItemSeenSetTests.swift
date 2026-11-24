import Foundation
import GRDB
import Testing

@testable import Persistence

/// The traversal seen-set lives in `itemSeen`, not on `item`.
///
/// Two properties not obvious from the schema. A traversal re-seeing an unchanged item must not
/// write `item`, which invalidates every observation reading it. Deletion inference must treat a
/// row with no seen row as unseen: rows also arrive outside traversals, and an inner join would
/// exempt them from deletion forever.
@Suite struct ItemSeenSetTests {

  @Test("re-seeing an unchanged item writes the seen row and leaves the item row untouched")
  func unchangedItemIsNotRewritten() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let dao = SyncRunDAO(database: database)
    let run = try dao.startRun(
      accountId: accountId, libraryId: libraryId, reason: "test", generation: 1,
      sortRequested: nil, startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    let item = Self.item(accountId: accountId, libraryId: libraryId, serverItemId: "item-1")
    _ = try dao.applyPage(
      runId: run.id!, accountId: accountId, libraryId: libraryId, generation: 1, items: [item],
      pageNumber: 0, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000), resultCategory: nil)

    let afterFirst = try #require(
      try database.read { db in try ItemRecord.fetchOne(db, key: ["libraryId": libraryId, "serverItemId": "item-1"]) })
    let itemRowId = try #require(afterFirst.id)
    try await Self.countItemWrites(database)

    _ = try dao.applyPage(
      runId: run.id!, accountId: accountId, libraryId: libraryId, generation: 2, items: [item],
      pageNumber: 1, fetchedAt: Date(timeIntervalSince1970: 1_700_000_060), resultCategory: nil)

    #expect(try Self.itemWriteCount(database) == 0)
    #expect(try Self.seenGeneration(database, itemRowId: itemRowId) == 2)
  }

  @Test("an item whose contents changed is still written")
  func changedItemIsRewritten() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let dao = SyncRunDAO(database: database)
    let run = try dao.startRun(
      accountId: accountId, libraryId: libraryId, reason: "test", generation: 1,
      sortRequested: nil, startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    var item = Self.item(accountId: accountId, libraryId: libraryId, serverItemId: "item-1")
    _ = try dao.applyPage(
      runId: run.id!, accountId: accountId, libraryId: libraryId, generation: 1, items: [item],
      pageNumber: 0, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000), resultCategory: nil)

    item.title = "A New Title"
    _ = try dao.applyPage(
      runId: run.id!, accountId: accountId, libraryId: libraryId, generation: 2, items: [item],
      pageNumber: 1, fetchedAt: Date(timeIntervalSince1970: 1_700_000_060), resultCategory: nil)

    let stored = try #require(
      try database.read { db in try ItemRecord.fetchOne(db, key: ["libraryId": libraryId, "serverItemId": "item-1"]) })
    #expect(stored.title == "A New Title")
    #expect(try Self.seenGeneration(database, itemRowId: try #require(stored.id)) == 2)
  }

  /// Revival is a content change (`softDeleted` goes false), so the row is written even though
  /// nothing the server sent differs.
  @Test("re-seeing a soft-deleted item revives it")
  func softDeletedItemIsRevived() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let dao = SyncRunDAO(database: database)
    let run = try dao.startRun(
      accountId: accountId, libraryId: libraryId, reason: "test", generation: 1,
      sortRequested: nil, startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    let item = Self.item(accountId: accountId, libraryId: libraryId, serverItemId: "item-1")
    _ = try dao.applyPage(
      runId: run.id!, accountId: accountId, libraryId: libraryId, generation: 1, items: [item],
      pageNumber: 0, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000), resultCategory: nil)
    let summary = try dao.inferDeletions(libraryId: libraryId, generation: 2)
    #expect(summary.softDeletedCount == 1)

    _ = try dao.applyPage(
      runId: run.id!, accountId: accountId, libraryId: libraryId, generation: 3, items: [item],
      pageNumber: 1, fetchedAt: Date(timeIntervalSince1970: 1_700_000_060), resultCategory: nil)

    let revived = try #require(
      try database.read { db in try ItemRecord.fetchOne(db, key: ["libraryId": libraryId, "serverItemId": "item-1"]) })
    #expect(revived.softDeleted == false)
  }

  /// The LEFT JOIN contract. Search's non-destructive upsert and podcast refresh both insert items
  /// no traversal has ever seen; those rows have no `itemSeen` row at all, and must still be
  /// swept by the next completed traversal that does not confirm them.
  @Test("an item no traversal has ever seen is still subject to deletion inference")
  func neverSeenItemIsStillDeleted() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let itemRowId = try await database.writeAsync { db -> Int64 in
      var item = Self.item(accountId: accountId, libraryId: libraryId, serverItemId: "never-seen")
      try item.insert(db)
      return item.id!
    }
    #expect(try Self.seenGeneration(database, itemRowId: itemRowId) == nil)

    let dao = SyncRunDAO(database: database)
    let first = try dao.inferDeletions(libraryId: libraryId, generation: 5)
    #expect(first.softDeletedCount == 1)
    let second = try dao.inferDeletions(libraryId: libraryId, generation: 6)
    #expect(second.hardDeletedCount == 1)
    #expect(try database.read { db in try ItemRecord.fetchOne(db, key: itemRowId) } == nil)
  }

  /// An item seen by this generation survives, including one seen by a later generation than the
  /// pass is inferring for.
  @Test("an item seen at or after the inferred generation survives")
  func seenItemSurvives() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await Self.seedAccountAndLibrary(database)
    let dao = SyncRunDAO(database: database)
    let run = try dao.startRun(
      accountId: accountId, libraryId: libraryId, reason: "test", generation: 4,
      sortRequested: nil, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    _ = try dao.applyPage(
      runId: run.id!, accountId: accountId, libraryId: libraryId, generation: 4,
      items: [Self.item(accountId: accountId, libraryId: libraryId, serverItemId: "item-1")],
      pageNumber: 0, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000), resultCategory: nil)

    let summary = try dao.inferDeletions(libraryId: libraryId, generation: 4)

    #expect(summary.softDeletedCount == 0)
    #expect(try database.read { db in try ItemRecord.fetchCount(db) } == 1)
  }

  /// Counts writes to `item` from here on. A trigger is the only honest probe: `rowid` does not
  /// move on update, and re-reading the row cannot distinguish "never written" from "written with
  /// identical values".
  private static func countItemWrites(_ database: AppDatabase) async throws {
    try await database.writeAsync { db in
      try db.execute(sql: "CREATE TABLE itemWriteLog (n INTEGER)")
      try db.execute(
        sql: """
          CREATE TRIGGER itemWriteCounter AFTER UPDATE ON item
          BEGIN INSERT INTO itemWriteLog (n) VALUES (1); END
          """)
    }
  }

  private static func itemWriteCount(_ database: AppDatabase) throws -> Int {
    try database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM itemWriteLog")
    } ?? -1
  }

  private static func seenGeneration(_ database: AppDatabase, itemRowId: Int64) throws -> Int? {
    try database.read { db in try ItemSeenRecord.fetchOne(db, key: itemRowId)?.generation }
  }

  private static func item(
    accountId: Int64, libraryId: Int64, serverItemId: String
  ) -> ItemRecord {
    ItemRecord(
      accountId: accountId, libraryId: libraryId, serverItemId: serverItemId, mediaKind: "book",
      title: "Title", sortTitle: "title", author: "Author", durationSeconds: 3600,
      // Sub-second on purpose: a wire epoch-millis date does not survive a GRDB round-trip
      // bit-for-bit, so comparing records with `==` rather than as database values would report
      // this row as changed on every traversal and undo the write elision.
      addedAt: Date(timeIntervalSince1970: 1_690_000_000.123))
  }

  private static func seedAccountAndLibrary(_ database: AppDatabase) async throws -> (
    accountId: Int64, libraryId: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      return (account.id!, library.id!)
    }
  }
}
