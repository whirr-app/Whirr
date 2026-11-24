import Foundation
import GRDB

/// Minimal read/write access to `ListeningHistoryEntryRecord` rows, scoped per account + item
/// Upsert identity is `(accountId, itemId, sessionId)`: a refresh that re-fetches the same server
/// session updates that row in place rather than duplicating it.
public struct ListeningHistoryDAO: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Cached entries for one item, newest session first, the ordering `ItemHistoryModel`'s
  /// "jump back to where each previous session started" list depends on.
  public func fetchAll(accountId: Int64, itemId: Int64) throws -> [ListeningHistoryEntryRecord] {
    try database.read { db in
      try ListeningHistoryEntryRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("itemId") == itemId)
        .order(Column("startedAt").desc)
        .fetchAll(db)
    }
  }

  @discardableResult
  public func upsert(_ record: ListeningHistoryEntryRecord) throws -> ListeningHistoryEntryRecord {
    try database.write { db in
      var record = record
      if let existing =
        try ListeningHistoryEntryRecord
        .filter(Column("accountId") == record.accountId)
        .filter(Column("itemId") == record.itemId)
        .filter(Column("sessionId") == record.sessionId)
        .fetchOne(db)
      {
        record.id = existing.id
      }
      try record.save(db)
      return record
    }
  }
}
