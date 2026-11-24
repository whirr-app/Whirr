import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct LibraryReconciliationStoreTests {

  @Test("reviving a tombstone keeps its prior inclusion")
  func tombstoneRevivalPreservesInclusion() async throws {
    let fixture = try await Fixture(mode: .selected)
    try await fixture.insert("books", included: false, softDeleted: true)

    let result = try await fixture.store.reconcile([
      LibraryReconciliationDescriptor(serverLibraryID: "books", name: "Renamed", mediaType: "book")
    ])

    #expect(result.liveIncludedServerLibraryIDs.isEmpty)
    let record = try #require(try await fixture.library("books"))
    #expect(record.softDeleted == false)
    #expect(record.isIncluded == false)
    #expect(record.name == "Renamed")
  }

  @Test("new libraries follow the account selection mode")
  func newLibraryPolicyDependsOnMode() async throws {
    let all = try await Fixture(mode: .all)
    let pending = try await Fixture(mode: .pending)
    let selected = try await Fixture(mode: .selected)
    let descriptor = LibraryReconciliationDescriptor(serverLibraryID: "new", name: "New", mediaType: "book")

    #expect(try await all.store.reconcile([descriptor]).liveIncludedServerLibraryIDs == ["new"])
    #expect(try await pending.store.reconcile([descriptor]).liveIncludedServerLibraryIDs.isEmpty)
    #expect(try await selected.store.reconcile([descriptor]).liveIncludedServerLibraryIDs.isEmpty)
    #expect(try await all.library("new")?.isIncluded == true)
    #expect(try await pending.library("new")?.isIncluded == false)
    #expect(try await selected.library("new")?.isIncluded == false)
  }

  @Test("reconciliation never overwrites existing inclusion flags")
  func existingFlagsSurviveReconciliation() async throws {
    let fixture = try await Fixture(mode: .all)
    try await fixture.insert("kept-off", included: false)
    try await fixture.insert("kept-on", included: true)

    let result = try await fixture.store.reconcile([
      LibraryReconciliationDescriptor(serverLibraryID: "kept-off", name: "Off renamed", mediaType: "book"),
      LibraryReconciliationDescriptor(serverLibraryID: "kept-on", name: "On renamed", mediaType: "podcast"),
    ])

    #expect(result.liveIncludedServerLibraryIDs == ["kept-on"])
    #expect(try await fixture.library("kept-off")?.isIncluded == false)
    #expect(try await fixture.library("kept-on")?.isIncluded == true)
  }

  @Test("reconciliation refreshes the server-owned Continue Series setting")
  func refreshesContinueSeriesSetting() async throws {
    let fixture = try await Fixture(mode: .all)

    _ = try await fixture.store.reconcile([
      LibraryReconciliationDescriptor(
        serverLibraryID: "books", name: "Books", mediaType: "book",
        onlyShowLaterBooksInContinueSeries: true)
    ])
    #expect(try await fixture.library("books")?.onlyShowLaterBooksInContinueSeries == true)

    _ = try await fixture.store.reconcile([
      LibraryReconciliationDescriptor(
        serverLibraryID: "books", name: "Books", mediaType: "book",
        onlyShowLaterBooksInContinueSeries: false)
    ])
    #expect(try await fixture.library("books")?.onlyShowLaterBooksInContinueSeries == false)
  }

  private struct Fixture {
    let database: AppDatabase
    let store: LibraryReconciliationStore
    let accountID: Int64

    init(mode: LibrarySelectionMode) async throws {
      database = try AppDatabase.inMemory()
      accountID = try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: UUID().uuidString, serverBaseURL: "https://example.com", serverUserId: "user",
          serverVersion: "2.35", librarySelectionMode: mode)
        try account.insert(db)
        guard let accountID = account.id else { throw FixtureError.accountInsertFailed }
        return accountID
      }
      store = LibraryReconciliationStore(database: database, accountID: accountID)
    }

    func insert(_ id: String, included: Bool, softDeleted: Bool = false) async throws {
      try await database.writeAsync { db in
        var library = LibraryRecord(
          accountId: accountID, serverLibraryId: id, mediaType: "book", name: id,
          softDeleted: softDeleted, isIncluded: included)
        try library.insert(db)
      }
    }

    func library(_ id: String) async throws -> LibraryRecord? {
      try await database.readAsync { db in
        try LibraryRecord
          .filter(Column("accountId") == accountID)
          .filter(Column("serverLibraryId") == id)
          .fetchOne(db)
      }
    }
  }

  private enum FixtureError: Error { case accountInsertFailed }
}
