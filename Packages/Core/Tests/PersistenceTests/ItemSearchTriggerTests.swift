import Foundation
import GRDB
import Testing

@testable import Persistence

/// `itemSearch_au` carries a `WHEN` guard so a traversal stops re-indexing unchanged rows. It must
/// cover `softDeleted` as well as the four indexed text columns, as the trigger also de-indexes a
/// soft-deleted row and re-indexes a revived one; a text-only guard would break both.
@Suite struct ItemSearchTriggerTests {

  @Test func softDeletingAnItemRemovesItFromTheSearchIndex() async throws {
    let database = try AppDatabase.inMemory()
    let (itemId, _) = try await seedItem(database, title: "Alpha Beta")
    #expect(try matches(database, "alpha beta") == [itemId])

    try await setSoftDeleted(database, itemId: itemId, softDeleted: true)

    #expect(try matches(database, "alpha beta").isEmpty)
  }

  @Test func revivingASoftDeletedItemRestoresItToTheSearchIndex() async throws {
    let database = try AppDatabase.inMemory()
    let (itemId, _) = try await seedItem(database, title: "Alpha Beta")
    try await setSoftDeleted(database, itemId: itemId, softDeleted: true)
    #expect(try matches(database, "alpha beta").isEmpty)

    try await setSoftDeleted(database, itemId: itemId, softDeleted: false)

    #expect(try matches(database, "alpha beta") == [itemId])
  }

  @Test func changingIndexedTextReindexesTheRow() async throws {
    let database = try AppDatabase.inMemory()
    let (itemId, _) = try await seedItem(database, title: "Alpha Beta")

    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE item SET title = ? WHERE id = ?", arguments: ["Gamma Delta", itemId])
    }

    #expect(try matches(database, "alpha beta").isEmpty)
    #expect(try matches(database, "gamma delta") == [itemId])
  }

  /// The guard itself, asserted on the trigger definition rather than on behaviour.
  ///
  /// A generation-only update has no observable effect either way: the unguarded trigger
  /// re-inserts identical text, so only the work differs. The one behavioural probe (de-index a
  /// row by hand, see whether an update restores it) fails on FTS5 index corruption, not a clean
  /// expectation. So this pins the `WHEN` directly: the four indexed text columns plus
  /// `softDeleted`. Adding `lastSeenGeneration` would restore the cost the guard removes.
  @Test func theUpdateTriggerIsGuardedOnExactlyTheColumnsTheIndexDependsOn() async throws {
    let database = try AppDatabase.inMemory()

    let definition = try await database.readAsync { db in
      try String.fetchOne(
        db, sql: "SELECT sql FROM sqlite_master WHERE type = 'trigger' AND name = 'itemSearch_au'")
    }
    let sql = try #require(definition)
    let whenKeyword = try #require(sql.range(of: "WHEN"))
    let beginKeyword = try #require(sql.range(of: "BEGIN"))
    let guardClause = String(sql[whenKeyword.lowerBound..<beginKeyword.lowerBound])

    for column in ["softDeleted", "title", "author", "seriesName", "narratorName"] {
      #expect(guardClause.contains("new.\(column)"), "\(column) must be able to trigger a re-index")
    }
    for column in ["numAudioFiles", "durationSeconds", "serverUpdatedAt"] {
      #expect(
        guardClause.contains("new.\(column)") == false,
        "\(column) is not indexed and must not be able to trigger a re-index")
    }
  }

  /// A row that changes an unindexed column in the same statement as a real text change is still
  /// indexed: the guard is an OR over the indexed columns, not an AND.
  @Test func anUnindexedColumnChangeAlongsideATextChangeStillReindexes() async throws {
    let database = try AppDatabase.inMemory()
    let (itemId, _) = try await seedItem(database, title: "Alpha Beta")

    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET title = ?, numAudioFiles = 3 WHERE id = ?",
        arguments: ["Gamma Delta", itemId])
    }

    #expect(try matches(database, "gamma delta") == [itemId])
  }

  private func matches(_ database: AppDatabase, _ term: String) throws -> [Int64] {
    try database.read { db in
      try Int64.fetchAll(
        db, sql: "SELECT rowid FROM itemSearch WHERE itemSearch MATCH ? ORDER BY rowid",
        arguments: [SearchQueryNormalizer.normalize(term)])
    }
  }

  private func setSoftDeleted(
    _ database: AppDatabase, itemId: Int64, softDeleted: Bool
  ) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = ? WHERE id = ?", arguments: [softDeleted, itemId])
    }
  }

  private func seedItem(
    _ database: AppDatabase, title: String
  ) async throws -> (itemId: Int64, libraryId: Int64) {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: "user-1", serverVersion: "2.10.0")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib-1", mediaType: "book", name: "Library")
      try library.insert(db)
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "item-1", mediaKind: "book",
        title: title, sortTitle: title.lowercased())
      try item.insert(db)
      return (item.id!, library.id!)
    }
  }
}
