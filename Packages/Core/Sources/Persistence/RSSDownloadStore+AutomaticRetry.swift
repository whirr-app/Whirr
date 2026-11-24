import Foundation
import GRDB

/// The RSS twin of `DownloadStore+AutomaticRetry.swift`, under the same rules.
extension RSSDownloadStore {
  @discardableResult
  public func armAutomaticRetryAsync(downloadId: Int64, notBefore: Date) async throws -> Bool {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE rssDownload SET autoRetryNotBefore = ?
          WHERE id = ? AND state = ? AND origin = ?
          """,
        arguments: [
          notBefore, downloadId, DownloadState.failed.rawValue, DownloadOrigin.automatic.rawValue,
        ])
      return db.changesCount > 0
    }
  }

  public func fetchDueAutomaticRetriesAsync(now: Date, limit: Int) async throws -> [RSSDownloadRecord] {
    try await database.readAsync { db in
      try RSSDownloadRecord.fetchAll(
        db,
        sql: """
          SELECT * FROM rssDownload
          WHERE state = ? AND origin = ? AND autoRetryNotBefore IS NOT NULL AND autoRetryNotBefore <= ?
          ORDER BY autoRetryNotBefore, id
          LIMIT ?
          """,
        arguments: [DownloadState.failed.rawValue, DownloadOrigin.automatic.rawValue, now, limit])
    }
  }

  public func requeueAutomaticRetryAsync(downloadId: Int64, now: Date) async throws -> RSSDownloadRecord? {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE rssDownload
          SET state = ?, holdReason = NULL, errorCode = NULL, autoRetryNotBefore = NULL,
              autoRetryCount = autoRetryCount + 1, updatedAt = ?
          WHERE id = ? AND state = ? AND origin = ? AND autoRetryNotBefore IS NOT NULL
            AND autoRetryNotBefore <= ?
          """,
        arguments: [
          DownloadState.pending.rawValue, now, downloadId, DownloadState.failed.rawValue,
          DownloadOrigin.automatic.rawValue, now,
        ])
      guard db.changesCount > 0 else { return nil }
      return try RSSDownloadRecord.fetchOne(db, key: downloadId)
    }
  }
}
