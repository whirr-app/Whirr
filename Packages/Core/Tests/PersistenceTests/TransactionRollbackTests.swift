import Foundation
import GRDB
import Testing

@testable import Persistence

/// A failing write inside a page-upsert transaction leaves no partial rows. `AppDatabase.write`
/// passes its closure to GRDB's `DatabaseWriter.write`, one transaction, so a thrown error rolls
/// back everything including statements that already succeeded.
@Suite struct TransactionRollbackTests {

  private struct InjectedFailure: Error {}

  @Test func aFailingWriteInsideAPageUpsertLeavesNoPartialRows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)

    await #expect(throws: InjectedFailure.self) {
      try await database.writeAsync { db in
        // A run, its page checkpoint and the items the page contains, as in a real page upsert.
        var run = SyncRunRecord(
          accountId: accountId, libraryId: libraryId, reason: "foreground", generation: 1,
          startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try run.insert(db)

        var page = SyncPageRecord(
          accountId: accountId, syncRunId: run.id!, pageNumber: 1, itemCount: 2,
          fetchedAt: Date(timeIntervalSince1970: 1_700_000_010))
        try page.insert(db)

        var firstItem = ItemRecord(
          accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "book",
          title: "First", sortTitle: "first")
        try firstItem.insert(db)

        // Simulate a failure partway through the page (e.g. a decode/DB error on the second
        // row). Nothing from this page, including the already-inserted run, page and first item,
        // may survive.
        throw InjectedFailure()
      }
    }

    try database.read { db in
      let runCount = try SyncRunRecord.fetchCount(db)
      let pageCount = try SyncPageRecord.fetchCount(db)
      let itemCount = try ItemRecord.fetchCount(db)
      #expect(runCount == 0)
      #expect(pageCount == 0)
      #expect(itemCount == 0)
    }
  }

  @Test func aFailingWriteDueToAConstraintViolationLeavesNoPartialRows() async throws {
    let database = try AppDatabase.inMemory()
    let (accountId, libraryId) = try await insertAccountAndLibrary(database)

    // Seed one existing item so a same-page duplicate collides with the unique
    // (libraryId, serverItemId) identity, mid-transaction.
    try await database.writeAsync { db in
      var existing = ItemRecord(
        accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "book",
        title: "Existing", sortTitle: "existing")
      try existing.insert(db)
    }

    await #expect(throws: (any Error).self) {
      try await database.writeAsync { db in
        var freshRun = SyncRunRecord(
          accountId: accountId, libraryId: libraryId, reason: "foreground", generation: 2,
          startedAt: Date(timeIntervalSince1970: 1_700_000_200))
        try freshRun.insert(db)

        // Violates the unique (libraryId, serverItemId) index.
        var duplicate = ItemRecord(
          accountId: accountId, libraryId: libraryId, serverItemId: "item-1", mediaKind: "book",
          title: "Duplicate", sortTitle: "duplicate")
        try duplicate.insert(db)
      }
    }

    try database.read { db in
      // The pre-existing item survives (never touched by the failed transaction); the new run
      // never commits.
      let itemCount = try ItemRecord.fetchCount(db)
      let runCount = try SyncRunRecord.fetchCount(db)
      #expect(itemCount == 1)
      #expect(runCount == 0)
    }
  }

  // MARK: - Helpers

  private func insertAccountAndLibrary(_ database: AppDatabase) async throws -> (
    accountId: Int64, libraryId: Int64
  ) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.10.0")
      try account.insert(db)

      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)

      return (account.id!, library.id!)
    }
  }
}
