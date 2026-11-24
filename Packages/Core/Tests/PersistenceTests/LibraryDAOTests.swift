import Foundation
import GRDB
import Testing

@testable import Persistence

/// A library the server stops listing is tombstoned, not deleted, as `item` rows are
/// (`softDeleted`) and `DownloadIntegritySweep` states: a reversible sync inference must never
/// become a file deletion. `library` cascades to `item`, so deleting the row would take the items
/// and, on the next integrity sweep, their files, turning a momentary under-report into data loss.
///
/// A library re-created on the server (a new id) must not leave the old row behind:
/// `SyncEngine.search` fans out over every local row, so an orphan would 404 every search.
@Suite struct LibraryDAOTests {

  @Test("a tombstoned library is hidden from the ordinary fetches, and reachable through the explicit one")
  func tombstonedLibraryIsHiddenFromOrdinaryFetches() async throws {
    let database = try AppDatabase.inMemory()
    let dao = LibraryDAO(database: database)
    let accountId = try await Self.seedAccount(database)

    _ = try await dao.upsertAsync(Self.library(accountId: accountId, serverLibraryId: "live"))
    _ = try await dao.upsertAsync(
      Self.library(accountId: accountId, serverLibraryId: "gone", softDeleted: true))

    #expect(try await dao.fetchIncludedAsync(accountId: accountId).map(\.serverLibraryId) == ["live"])
    #expect(try dao.fetchIncluded(accountId: accountId).map(\.serverLibraryId) == ["live"])

    // The tombstone write path still has to see it.
    let all = try await dao.fetchAccessibleAsync(accountId: accountId, includingRemoved: true)
    #expect(all.map(\.serverLibraryId).sorted() == ["gone", "live"])
  }

  /// The re-created-library case: the same name and content come back under a new id, so this is
  /// about the old row staying out of the way. A server that merely blinked must still be able to
  /// bring its library back without the user losing anything.
  @Test("a tombstoned library that the server lists again is live once more")
  func reappearingLibraryIsRevived() async throws {
    let database = try AppDatabase.inMemory()
    let dao = LibraryDAO(database: database)
    let accountId = try await Self.seedAccount(database)

    let tombstoned = try await dao.upsertAsync(
      Self.library(accountId: accountId, serverLibraryId: "blinked", softDeleted: true))
    #expect(try await dao.fetchIncludedAsync(accountId: accountId).isEmpty)

    // What `refreshLibraries` writes when the server lists it again: a fresh record with
    // the default (live) tombstone state, matched to the existing row by identity.
    let revived = try await dao.upsertAsync(
      Self.library(accountId: accountId, serverLibraryId: "blinked"))

    #expect(revived.id == tombstoned.id, "revival must reuse the row, not orphan a second one")
    #expect(revived.softDeleted == false)
    #expect(try await dao.fetchIncludedAsync(accountId: accountId).map(\.serverLibraryId) == ["blinked"])
  }

  @Test("included reads exclude opted-out and tombstoned rows while accessible reads retain them")
  func includedAndAccessibleReadsHaveDistinctSemantics() async throws {
    let database = try AppDatabase.inMemory()
    let dao = LibraryDAO(database: database)
    let accountId = try await Self.seedAccount(database)

    _ = try await dao.upsertAsync(Self.library(accountId: accountId, serverLibraryId: "included"))
    _ = try await dao.upsertAsync(Self.library(accountId: accountId, serverLibraryId: "excluded", isIncluded: false))
    _ = try await dao.upsertAsync(Self.library(accountId: accountId, serverLibraryId: "removed", softDeleted: true))

    #expect(try await dao.fetchIncludedAsync(accountId: accountId).map(\.serverLibraryId) == ["included"])
    #expect(
      try await dao.fetchAccessibleAsync(accountId: accountId).map(\.serverLibraryId).sorted() == [
        "excluded", "included",
      ])
    #expect(
      try await dao.fetchAccessibleAsync(accountId: accountId, includingRemoved: true)
        .map(\.serverLibraryId).sorted() == ["excluded", "included", "removed"])
  }

  // MARK: - Fixtures

  private static func library(
    accountId: Int64, serverLibraryId: String, softDeleted: Bool = false, isIncluded: Bool = true
  ) -> LibraryRecord {
    LibraryRecord(
      accountId: accountId, serverLibraryId: serverLibraryId, mediaType: "book",
      name: serverLibraryId, softDeleted: softDeleted, isIncluded: isIncluded)
  }

  private static func seedAccount(_ database: AppDatabase) async throws -> Int64 {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.35.1")
      try account.insert(db)
      return account.id!
    }
  }
}
