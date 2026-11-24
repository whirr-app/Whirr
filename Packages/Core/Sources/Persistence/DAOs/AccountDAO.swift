import Foundation
import GRDB

/// Minimal read/write access to the single v1 `AccountRecord` row. Free of any login/creation
/// policy (which account identity matches, when to generate a fresh `clientUUID`), which belongs
/// to `AccountLifecycle`. This DAO only fetches and persists the record the caller assembled.
public struct AccountDAO: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// The v1 store has at most one account row.
  public func fetch() throws -> AccountRecord? {
    try database.read { db in try AccountRecord.fetchOne(db) }
  }

  public func fetchAsync() async throws -> AccountRecord? {
    try await database.readAsync { db in try AccountRecord.fetchOne(db) }
  }

  @discardableResult
  public func save(_ record: AccountRecord) throws -> AccountRecord {
    try database.write { db in
      var record = record
      try record.save(db)
      return record
    }
  }

  /// Removes the single account row. Every account-owned table cascades on this delete
  /// (SchemaV1: `belongsTo("account", onDelete: .cascade)`), so callers may only use it when no
  /// account-owned rows exist, i.e. undoing a first-ever-login row whose composed login failed
  /// before any sync could run. Destroying a live account goes through `AccountRemover`.
  public func delete() throws {
    try database.write { db in
      try db.execute(sql: "DELETE FROM account")
    }
  }
}
