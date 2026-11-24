import Foundation
import GRDB

/// Schema-level account removal.
///
/// Every account-owned table declares `t.belongsTo("account", onDelete: .cascade)`
/// (SchemaV1.swift) and `AppDatabase` enforces `PRAGMA foreign_keys = ON`, so one
/// `DELETE FROM account` cascades atomically in a single GRDB transaction. The sweep deciding
/// which tables are account-owned reads `sqlite_master` plus `PRAGMA foreign_key_list` at removal
/// time, so a new table is covered without touching this file.
public struct AccountRemover: AccountRemoving, Sendable {

  /// Thrown by the post-delete verification if any account-owned table still carries a row for
  /// the removed account, meaning the cascade did not fully apply. Should never happen under
  /// `PRAGMA foreign_keys = ON`; the check makes a schema regression fail loudly instead of
  /// leaving orphaned rows.
  public struct RowsSurvivedRemoval: Error, Equatable {
    public let tables: [String]
  }

  /// File-side companion to `RowsSurvivedRemoval`: thrown by the post-delete verification when a
  /// caller-supplied root (downloads root, cover cache, exported diagnostics) still exists on
  /// disk after `AccountRemovalCoordinator` believed it had removed it.
  public struct FileSystemArtifactsSurvivedRemoval: Error, Equatable {
    public let paths: [String]
  }

  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Deletes the `accountId` row and, via cascade, every row it owns, in one transaction, then
  /// verifies no account-owned row referencing it remains.
  public func removeAccount(accountId: Int64) throws {
    try deleteAccountRow(accountId)
    try verifyRemoval(of: accountId)
  }

  /// Same DB-side delete and schema-driven verification as `removeAccount(accountId:)`, plus a
  /// file-system sweep confirming every one of `roots` is gone. `AccountRemovalCoordinator` calls
  /// this overload, so a regression in its file-removal step (or a stray write racing it) fails
  /// loudly instead of leaving an orphaned directory after the journal is cleared.
  public func removeAccount(accountId: Int64, verifyingFileSystemRootsAbsent roots: [URL]) throws {
    try deleteAccountRow(accountId)
    try verifyRemoval(of: accountId)
    let survivors = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    guard survivors.isEmpty else {
      throw FileSystemArtifactsSurvivedRemoval(paths: survivors.map(\.path).sorted())
    }
  }

  private func deleteAccountRow(_ accountId: Int64) throws {
    try database.write { db in
      // v1 composes one account at a time, while this derived/disposable table predates account
      // scoping. Clear it in the same transaction so artwork from the removed account cannot be
      // shown after a later login.
      try db.execute(sql: "DELETE FROM coverPaletteRecord")
      try db.execute(sql: "DELETE FROM coverShape")
      try db.execute(sql: "DELETE FROM account WHERE id = ?", arguments: [accountId])
      try NativeListeningQueueWriter.compact(in: db)
      try NativeListeningQueueWriter.bumpRevision(in: db)
    }
  }

  /// The schema-driven sweep: every table whose foreign-key list references `account`.
  /// Exposed so tests can assert this matches the schema's actual accountId-FK tables rather
  /// than a hand-maintained list.
  public func accountOwnedTables() throws -> Set<String> {
    try database.read { db in try Self.discoverAccountOwnedTables(db) }
  }

  /// Introspects the live schema, so tables added by later migrations are discovered
  /// automatically.
  static func discoverAccountOwnedTables(_ db: Database) throws -> Set<String> {
    let tableNames = try String.fetchAll(
      db,
      sql: """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
        """)

    var owned: Set<String> = []
    for table in tableNames where table != "account" {
      let foreignKeys = try db.foreignKeys(on: table)
      if foreignKeys.contains(where: { $0.destinationTable == "account" }) {
        owned.insert(table)
      }
    }
    return owned
  }

  private func verifyRemoval(of accountId: Int64) throws {
    try database.read { db in
      let owned = try Self.discoverAccountOwnedTables(db)
      var survivors: [String] = []
      for table in owned {
        let rowCount =
          try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM \(table.quotedDatabaseIdentifier) WHERE accountId = ?",
            arguments: [accountId]) ?? 0
        if rowCount > 0 {
          survivors.append(table)
        }
      }
      if !survivors.isEmpty {
        throw RowsSurvivedRemoval(tables: survivors.sorted())
      }
      let coverPaletteCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM coverPaletteRecord") ?? 0
      if coverPaletteCount > 0 {
        throw RowsSurvivedRemoval(tables: ["coverPaletteRecord"])
      }
      let coverShapeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM coverShape") ?? 0
      if coverShapeCount > 0 {
        throw RowsSurvivedRemoval(tables: ["coverShape"])
      }
    }
  }
}
