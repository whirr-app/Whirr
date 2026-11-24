import Foundation
import GRDB

/// The persisted half of the bounded automatic retry. The store holds the count and deadline; the
/// policy that computes them lives in SyncEngine.
extension DownloadStore {
  /// Gives a failed automatic row a retry deadline. Guarded in SQL so a row the user has already
  /// retried, deleted or promoted to manual is left alone. Returns whether the row was armed.
  @discardableResult
  public func armAutomaticRetryAsync(downloadId: Int64, notBefore: Date) async throws -> Bool {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE download SET autoRetryNotBefore = ?
          WHERE id = ? AND state = ? AND origin = ?
          """,
        arguments: [
          notBefore, downloadId, DownloadState.failed.rawValue, DownloadOrigin.automatic.rawValue,
        ])
      return db.changesCount > 0
    }
  }

  /// Failed automatic rows whose deadline has passed, earliest deadline first.
  public func fetchDueAutomaticRetriesAsync(now: Date, limit: Int) async throws -> [DownloadRecord] {
    try await database.readAsync { db in
      try DownloadRecord.fetchAll(
        db,
        sql: """
          SELECT * FROM download
          WHERE state = ? AND origin = ? AND autoRetryNotBefore IS NOT NULL AND autoRetryNotBefore <= ?
          ORDER BY autoRetryNotBefore, id
          LIMIT ?
          """,
        arguments: [DownloadState.failed.rawValue, DownloadOrigin.automatic.rawValue, now, limit])
    }
  }

  /// Moves one due row `.failed -> .pending` and spends one attempt, in one guarded write. Returns
  /// `nil` when the row is no longer due, so a repeated sweep cannot spend a second attempt.
  public func requeueAutomaticRetryAsync(downloadId: Int64, now: Date) async throws -> DownloadRecord? {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE download
          SET state = ?, holdReason = NULL, errorCategory = NULL, autoRetryNotBefore = NULL,
              autoRetryCount = autoRetryCount + 1
          WHERE id = ? AND state = ? AND origin = ? AND autoRetryNotBefore IS NOT NULL
            AND autoRetryNotBefore <= ?
          """,
        arguments: [
          DownloadState.pending.rawValue, downloadId, DownloadState.failed.rawValue,
          DownloadOrigin.automatic.rawValue, now,
        ])
      guard db.changesCount > 0 else { return nil }
      return try DownloadRecord.fetchOne(db, key: downloadId)
    }
  }
}
