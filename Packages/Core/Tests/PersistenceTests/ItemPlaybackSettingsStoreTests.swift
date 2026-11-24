import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

@Suite struct ItemPlaybackSettingsStoreTests {

  @Test func absentRowReadsAsNoOverride() async throws {
    let fixture = try await Fixture()

    #expect(try await fixture.store.fetchOverride(itemID: "book-1") == nil)
    #expect(try await fixture.store.fetchOverrides().isEmpty)
  }

  @Test func explicitOneTimesOverrideRoundTripsAndIsDistinctFromAbsence() async throws {
    let fixture = try await Fixture()

    #expect(try await fixture.store.fetchOverride(itemID: "book-1") == nil)
    try await fixture.store.upsertOverride(itemID: "book-1", rateStep: 20)

    #expect(try await fixture.store.fetchOverride(itemID: "book-1") == 20)
    #expect(try await fixture.store.fetchOverrides() == ["book-1": 20])
  }

  @Test func overrideEqualToTheGlobalDefaultIsStillStored() async throws {
    let fixture = try await Fixture()
    let currentGlobalDefaultStep = 30

    // The global default is UserDefaults-owned and is not read by Persistence. A
    // row equal to it still pins this title, so changing that global later must not erase it.
    try await fixture.store.upsertOverride(
      itemID: "book-1", rateStep: currentGlobalDefaultStep)

    #expect(try await fixture.store.fetchOverride(itemID: "book-1") == currentGlobalDefaultStep)
    #expect(try await fixture.store.fetchOverrides() == ["book-1": currentGlobalDefaultStep])
  }

  @Test func upsertReplacesTheExistingOverride() async throws {
    let fixture = try await Fixture()

    try await fixture.store.upsertOverride(itemID: "book-1", rateStep: 20)
    try await fixture.store.upsertOverride(itemID: "book-1", rateStep: 36)

    #expect(try await fixture.store.fetchOverride(itemID: "book-1") == 36)
    #expect(try await fixture.store.fetchOverrides() == ["book-1": 36])
  }

  @Test func deleteOneRemovesOnlyThatOverride() async throws {
    let fixture = try await Fixture()

    try await fixture.store.upsertOverride(itemID: "book-1", rateStep: 20)
    try await fixture.store.upsertOverride(itemID: "show-1", rateStep: 40)
    try await fixture.store.deleteOverride(itemID: "book-1")

    #expect(try await fixture.store.fetchOverride(itemID: "book-1") == nil)
    #expect(try await fixture.store.fetchOverrides() == ["show-1": 40])
  }

  @Test func deleteAllRemovesEveryOverrideForTheAccount() async throws {
    let fixture = try await Fixture()

    try await fixture.store.upsertOverride(itemID: "book-1", rateStep: 20)
    try await fixture.store.upsertOverride(itemID: "show-1", rateStep: 40)
    try await fixture.store.deleteAllOverrides()

    #expect(try await fixture.store.fetchOverrides().isEmpty)
  }

  @Test func observationEmitsOnInsertUpdateAndDelete() async throws {
    let fixture = try await Fixture()
    let observations = PersistenceObservationCollector(fixture.store.observeOverrides())

    #expect(await TestSupport.waitUntil { observations.contains { $0.isEmpty } })

    try await fixture.store.upsertOverride(itemID: "book-1", rateStep: 20)
    #expect(await TestSupport.waitUntil { observations.contains { $0 == ["book-1": 20] } })

    try await fixture.store.upsertOverride(itemID: "book-1", rateStep: 36)
    #expect(await TestSupport.waitUntil { observations.contains { $0 == ["book-1": 36] } })

    let observationCountBeforeDelete = observations.values.count
    try await fixture.store.deleteOverride(itemID: "book-1")
    #expect(
      await TestSupport.waitUntil {
        let values = observations.values
        return values.count > observationCountBeforeDelete && values.last?.isEmpty == true
      })
  }

  @Test func deletingTheItemCascadesItsSettingsRow() async throws {
    let fixture = try await Fixture()
    try await fixture.store.upsertOverride(itemID: "book-1", rateStep: 20)

    try await fixture.database.writeAsync { db in
      try db.execute(
        sql: "DELETE FROM item WHERE id = ?", arguments: [fixture.itemRowIDs["book-1"]!])
    }

    #expect(try await fixture.store.fetchOverride(itemID: "book-1") == nil)
    #expect(try await fixture.store.fetchOverrides().isEmpty)
    let rowCount = try fixture.database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM itemPlaybackSettings") ?? -1
    }
    #expect(rowCount == 0)
  }

  @Test func deletingTheAccountCascadesItsSettingsRows() async throws {
    let fixture = try await Fixture()
    try await fixture.store.upsertOverride(itemID: "book-1", rateStep: 20)

    try await fixture.database.writeAsync { db in
      try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [fixture.accountId])
    }

    #expect(try await fixture.store.fetchOverrides().isEmpty)
    let rowCount = try fixture.database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM itemPlaybackSettings") ?? -1
    }
    #expect(rowCount == 0)
  }

  @Test func aWrongAccountItemIDIsRejectedByTheCompositeForeignKey() async throws {
    let fixture = try await Fixture()
    let otherAccountId = try await Self.insertAccountAndLibrary(
      fixture.database, serverUserId: "user-2"
    ).accountId

    await #expect(throws: (any Error).self) {
      try await fixture.database.writeAsync { db in
        let record = ItemPlaybackSettingsRecord(
          itemId: fixture.itemRowIDs["book-1"]!, accountId: otherAccountId, rateStep: 20)
        try record.insert(db)
      }
    }

    let rowCount = try fixture.database.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM itemPlaybackSettings") ?? -1
    }
    #expect(rowCount == 0)
  }

  @Test func aSoftDeletedBookStillResolvesItsOverride() async throws {
    let fixture = try await Fixture()
    _ = try await Self.insertItem(
      fixture.database, accountId: fixture.accountId, libraryId: fixture.libraryId,
      serverItemID: "tombstoned-book", mediaKind: "book", softDeleted: true)
    try await fixture.store.upsertOverride(itemID: "tombstoned-book", rateStep: 24)

    #expect(try await fixture.store.fetchOverride(itemID: "tombstoned-book") == 24)
    #expect(try await fixture.store.fetchOverrides() == ["tombstoned-book": 24])
  }

  @Test func anInvalidStoredRateStepReadsAsNoOverride() async throws {
    let fixture = try await Fixture()

    try await fixture.database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO itemPlaybackSettings (itemId, accountId, rateStep)
          VALUES (?, ?, ?)
          """,
        arguments: [fixture.itemRowIDs["book-1"]!, fixture.accountId, 61])
    }

    #expect(try await fixture.store.fetchOverride(itemID: "book-1") == nil)
    #expect(try await fixture.store.fetchOverrides().isEmpty)
  }

  @Test func noOpAccessFinishesItsObservationAndAcceptsWrites() async throws {
    let reading = NoOpItemPlaybackSettingsReading()
    var iterator = reading.observeOverrides().makeAsyncIterator()
    #expect(await iterator.next() == nil)

    let writing = NoOpItemPlaybackSettingsWriting()
    try await writing.upsertOverride(itemID: "book-1", rateStep: 20)
    try await writing.deleteOverride(itemID: "book-1")
    try await writing.deleteAllOverrides()
  }

  // MARK: - Fixture

  private struct Fixture {
    let database: AppDatabase
    let accountId: Int64
    let libraryId: Int64
    let itemRowIDs: [String: Int64]
    let store: ItemPlaybackSettingsStore

    init() async throws {
      database = try AppDatabase.inMemory()
      (accountId, libraryId) = try await ItemPlaybackSettingsStoreTests.insertAccountAndLibrary(
        database, serverUserId: "user-1")
      let bookID = try await ItemPlaybackSettingsStoreTests.insertItem(
        database, accountId: accountId, libraryId: libraryId, serverItemID: "book-1",
        mediaKind: "book")
      let showID = try await ItemPlaybackSettingsStoreTests.insertItem(
        database, accountId: accountId, libraryId: libraryId, serverItemID: "show-1",
        mediaKind: "podcast")
      itemRowIDs = ["book-1": bookID, "show-1": showID]
      store = ItemPlaybackSettingsStore(database: database, accountId: accountId)
    }
  }

  private static func insertAccountAndLibrary(_ database: AppDatabase, serverUserId: String)
    async
    throws -> (accountId: Int64, libraryId: Int64)
  {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-\(serverUserId)", serverBaseURL: "https://example.com",
        serverUserId: serverUserId, serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library-\(serverUserId)", mediaType: "book",
        name: "Library")
      try library.insert(db)
      return (account.id!, library.id!)
    }
  }

  private static func insertItem(
    _ database: AppDatabase,
    accountId: Int64,
    libraryId: Int64,
    serverItemID: String,
    mediaKind: String,
    softDeleted: Bool = false
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      var item = PersistenceFixtures.item(
        accountId: accountId, libraryId: libraryId, serverItemId: serverItemID, mediaKind: mediaKind,
        title: serverItemID, sortTitle: serverItemID, softDeleted: softDeleted)
      try item.insert(db)
      return item.id!
    }
  }

}
