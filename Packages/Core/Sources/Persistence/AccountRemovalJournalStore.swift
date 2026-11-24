import Foundation
import GRDB

/// DB-facing access to the single-row removal journal. Mirrors `AccountDAO`'s "at most one row"
/// shape. No removal policy: when to create or clear it is `AccountRemovalCoordinator`'s
/// (SyncEngine) job; this type only persists and fetches what it is given.
public struct AccountRemovalJournalStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// At most one row: present while a removal is pending, absent otherwise. The durable,
  /// relaunch-surviving signal that gates login/setup.
  public func fetch() throws -> AccountRemovalJournalRecord? {
    try database.read { db in try AccountRemovalJournalRecord.fetchOne(db) }
  }

  public func fetchAsync() async throws -> AccountRemovalJournalRecord? {
    try await database.readAsync { db in try AccountRemovalJournalRecord.fetchOne(db) }
  }

  /// The first durable step of a confirmed removal, before any destructive side effect.
  /// Idempotent: if a journal already exists (a resumed removal after a crash), returns that row
  /// unchanged, so a caller need not check `fetch()` first.
  @discardableResult
  public func create(_ record: AccountRemovalJournalRecord) throws -> AccountRemovalJournalRecord {
    try database.write { db in try Self.create(record, in: db) }
  }

  @discardableResult
  public func createAsync(
    _ record: AccountRemovalJournalRecord
  ) async throws -> AccountRemovalJournalRecord {
    try await database.writeAsync { db in try Self.create(record, in: db) }
  }

  private static func create(
    _ record: AccountRemovalJournalRecord, in db: Database
  ) throws -> AccountRemovalJournalRecord {
    if let existing = try AccountRemovalJournalRecord.fetchOne(db) {
      return existing
    }
    var record = record
    try record.insert(db)
    return record
  }

  /// The only legal exit. `AccountRemovalCoordinator` calls this last, once every destructive
  /// step and both verification sweeps have succeeded.
  public func clear() throws {
    try database.write { db in try db.execute(sql: "DELETE FROM accountRemovalJournal") }
  }

  public func clearAsync() async throws {
    try await database.writeAsync { db in try db.execute(sql: "DELETE FROM accountRemovalJournal") }
  }
}
