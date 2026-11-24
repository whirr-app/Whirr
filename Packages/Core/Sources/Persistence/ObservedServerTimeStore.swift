import Foundation
import GRDB

/// Per-account observed-server-clock-offset store. `OutboxDrainer` reads this at `local-all`
/// upload time to compute `estimatedServerNow = localNow + offset`, never the stale server
/// timestamp captured when the observation was made.
public struct ObservedServerTimeStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Persists `offsetSeconds` for `accountId`, captured at `observedAt` (local receipt time),
  /// but only if this observation is newer than whatever is already stored, so a straggler
  /// response for an earlier observation can never regress a fresher one. One row per account
  /// (insert if absent, update in place otherwise), both paths in the same transaction.
  public func recordObservation(accountId: Int64, offsetSeconds: Double, observedAt: Date) throws {
    try database.write { db in
      if var existing = try ObservedServerTimeRecord.filter(Column("accountId") == accountId).fetchOne(db) {
        guard observedAt > existing.observedAt else { return }
        existing.offsetSeconds = offsetSeconds
        existing.observedAt = observedAt
        try existing.update(db)
        return
      }
      var record = ObservedServerTimeRecord(accountId: accountId, offsetSeconds: offsetSeconds, observedAt: observedAt)
      try record.insert(db)
    }
  }

  /// The account's most recently observed offset, or `nil` if no observation has ever been
  /// recorded. Distinct from an offset of zero: upload is unclamped only when no observation is
  /// available at all.
  public func fetchOffset(accountId: Int64) throws -> Double? {
    try database.read { db in
      try ObservedServerTimeRecord.filter(Column("accountId") == accountId).fetchOne(db)?.offsetSeconds
    }
  }
}
