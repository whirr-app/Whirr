import Foundation
import GRDB

/// Minimal read/write access to `LibraryRecord` rows, keyed by the schema's identity
/// `(accountId, serverLibraryId)`. Traversal/generation bookkeeping lives in SyncEngine; this
/// DAO exposes only the fetch/upsert primitives.
///
/// `fetchIncluded` is the catalogue/discovery fan-out source and hides tombstoned and excluded
/// rows. `fetchAccessible` serves Settings/reconciliation and can include tombstones for the
/// missing-library write path.
///
/// There is no delete: `library` cascades to `item` and through it to `download`, so removing a
/// row would let the next `DownloadIntegritySweep` reclaim the reader's files over an inference
/// a single server response can reverse.
public struct LibraryDAO: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func fetchIncluded(
    accountId: Int64
  ) throws -> [LibraryRecord] {
    try database.read { db in
      try Self.all(accountId: accountId, includingRemoved: false, includingExcluded: false).fetchAll(db)
    }
  }

  public func fetchIncludedAsync(
    accountId: Int64
  ) async throws -> [LibraryRecord] {
    try await database.readAsync { db in
      try Self.all(accountId: accountId, includingRemoved: false, includingExcluded: false).fetchAll(db)
    }
  }

  public func fetchAccessible(
    accountId: Int64, includingRemoved: Bool = false
  ) throws -> [LibraryRecord] {
    try database.read { db in
      try Self.all(accountId: accountId, includingRemoved: includingRemoved, includingExcluded: true).fetchAll(db)
    }
  }

  public func fetchAccessibleAsync(
    accountId: Int64, includingRemoved: Bool = false
  ) async throws -> [LibraryRecord] {
    try await database.readAsync { db in
      try Self.all(accountId: accountId, includingRemoved: includingRemoved, includingExcluded: true).fetchAll(db)
    }
  }

  public func fetchOneAccessible(
    accountId: Int64, serverLibraryId: String, includingRemoved: Bool = false
  ) throws -> LibraryRecord? {
    try database.read { db in
      try Self.all(accountId: accountId, includingRemoved: includingRemoved, includingExcluded: true)
        .filter(Column("serverLibraryId") == serverLibraryId)
        .fetchOne(db)
    }
  }

  /// The single-library counterpart to `fetchIncludedAsync`, for an engine that must re-check a
  /// library between network requests without broadening back out to Settings' accessible set.
  public func fetchOneIncludedAsync(
    accountId: Int64, serverLibraryId: String
  ) async throws -> LibraryRecord? {
    try await database.readAsync { db in
      try Self.all(accountId: accountId, includingRemoved: false, includingExcluded: false)
        .filter(Column("serverLibraryId") == serverLibraryId)
        .fetchOne(db)
    }
  }

  /// The one place the tombstone/inclusion predicates are spelled, so no fetch above can drift.
  private static func all(
    accountId: Int64, includingRemoved: Bool, includingExcluded: Bool
  ) -> QueryInterfaceRequest<LibraryRecord> {
    let request = LibraryRecord.filter(Column("accountId") == accountId)
    let live = includingRemoved ? request : request.filter(Column("softDeleted") == false)
    return includingExcluded ? live : live.filter(Column("isIncluded") == true)
  }

  @discardableResult
  public func upsert(_ record: LibraryRecord) throws -> LibraryRecord {
    try database.write { db in
      var record = record
      if let existing =
        try LibraryRecord
        .filter(Column("accountId") == record.accountId)
        .filter(Column("serverLibraryId") == record.serverLibraryId)
        .fetchOne(db)
      {
        record.id = existing.id
      }
      try record.save(db)
      return record
    }
  }

  @discardableResult
  public func upsertAsync(_ record: LibraryRecord) async throws -> LibraryRecord {
    try await database.writeAsync { db in
      var record = record
      if let existing =
        try LibraryRecord
        .filter(Column("accountId") == record.accountId)
        .filter(Column("serverLibraryId") == record.serverLibraryId)
        .fetchOne(db)
      {
        record.id = existing.id
      }
      try record.save(db)
      return record
    }
  }
}
