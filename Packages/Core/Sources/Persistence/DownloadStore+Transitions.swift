import Foundation
import GRDB

extension DownloadStore {
  // MARK: - Transitions

  /// Applies a state transition, throwing `.illegalTransition` if `to` is not reachable from the
  /// row's current state (see `legalTransitions`). `holdReason` is retained only when `to ==
  /// .pending`; `errorCategory` only when `to == .failed`. Both are cleared on every other
  /// transition, like `OutboxStore.transition` clears a stale dead-letter reason.
  @discardableResult
  public func transition(
    downloadId: Int64,
    to newState: DownloadState,
    receivedBytes: Int64? = nil,
    holdReason: DownloadHoldReason? = nil,
    errorCategory: DownloadErrorCategory? = nil
  ) throws -> DownloadRecord {
    try database.write { db in
      try Self.transition(
        downloadId: downloadId,
        to: newState,
        receivedBytes: receivedBytes,
        holdReason: holdReason,
        errorCategory: errorCategory,
        in: db)
    }
  }

  @discardableResult
  public func transitionAsync(
    downloadId: Int64,
    to newState: DownloadState,
    receivedBytes: Int64? = nil,
    holdReason: DownloadHoldReason? = nil,
    errorCategory: DownloadErrorCategory? = nil
  ) async throws -> DownloadRecord {
    try await database.writeAsync { db in
      try Self.transition(
        downloadId: downloadId,
        to: newState,
        receivedBytes: receivedBytes,
        holdReason: holdReason,
        errorCategory: errorCategory,
        in: db)
    }
  }

  private static func transition(
    downloadId: Int64,
    to newState: DownloadState,
    receivedBytes: Int64?,
    holdReason: DownloadHoldReason?,
    errorCategory: DownloadErrorCategory?,
    in db: Database
  ) throws -> DownloadRecord {
    guard var record = try DownloadRecord.fetchOne(db, key: downloadId) else {
      throw DownloadStoreError.downloadNotFound(downloadId)
    }
    guard Self.legalTransitions[record.state]?.contains(newState) == true else {
      throw DownloadStoreError.illegalTransition(from: record.state, to: newState)
    }

    if let receivedBytes {
      record.receivedBytes = receivedBytes
    }
    record.holdReason = newState == .pending ? holdReason : nil
    record.errorCategory = newState == .failed ? errorCategory : nil
    // A deadline belongs to one failure: only `armAutomaticRetry` sets it, after the failure is
    // written. The automatic requeue has its own path, so this edge is Try Again.
    record.autoRetryNotBefore = nil
    if record.state == .failed, newState == .pending { record.autoRetryCount = 0 }
    record.state = newState
    try record.update(db)
    return record
  }

  /// Promotes an existing download row to `.manual` origin. A row's `origin` only ever moves this
  /// way: a manual request for an episode with an `.automatic` row takes it out of the automatic
  /// reaper's reach, never the reverse. Not a lifecycle transition (`state` is untouched), so it
  /// bypasses `legalTransitions`. A no-op when the row is already `.manual`.
  @discardableResult
  public func promoteToManual(downloadId: Int64) throws -> DownloadRecord {
    try database.write { db in try Self.promoteToManual(downloadId: downloadId, in: db) }
  }

  @discardableResult
  public func promoteToManualAsync(downloadId: Int64) async throws -> DownloadRecord {
    try await database.writeAsync { db in
      try Self.promoteToManual(downloadId: downloadId, in: db)
    }
  }

  private static func promoteToManual(
    downloadId: Int64, in db: Database
  ) throws -> DownloadRecord {
    guard var record = try DownloadRecord.fetchOne(db, key: downloadId) else {
      throw DownloadStoreError.downloadNotFound(downloadId)
    }
    guard record.origin != .manual else { return record }
    record.origin = .manual
    try record.update(db)
    return record
  }

  /// The only path to `completed`, and only with a verified final size and a relative path.
  /// Legal only from `downloading`; every other source state is rejected as an illegal
  /// transition.
  @discardableResult
  public func complete(downloadId: Int64, finalSizeBytes: Int64) throws -> DownloadRecord {
    try database.write { db in
      guard var record = try DownloadRecord.fetchOne(db, key: downloadId) else {
        throw DownloadStoreError.downloadNotFound(downloadId)
      }
      guard record.state == .downloading else {
        throw DownloadStoreError.illegalTransition(from: record.state, to: .completed)
      }
      guard finalSizeBytes > 0 else {
        throw DownloadStoreError.completionRequiresVerifiedFinalSize
      }
      guard record.destinationRelativePath.isEmpty == false else {
        throw DownloadStoreError.completionRequiresRelativePath
      }

      record.receivedBytes = finalSizeBytes
      record.expectedBytes = finalSizeBytes
      record.holdReason = nil
      record.errorCategory = nil
      record.autoRetryCount = 0
      record.autoRetryNotBefore = nil
      record.state = .completed
      try record.update(db)
      return record
    }
  }

  /// Updates only the byte-progress counter for a still-`downloading` row. Not a lifecycle
  /// transition, so it never touches `state` and is guarded directly rather than via
  /// `legalTransitions`. Any other source state is a caller error.
  @discardableResult
  public func updateProgress(downloadId: Int64, receivedBytes: Int64) throws -> DownloadRecord {
    try database.write { db in
      try Self.updateProgress(downloadId: downloadId, receivedBytes: receivedBytes, in: db)
    }
  }

  @discardableResult
  public func updateProgressAsync(
    downloadId: Int64, receivedBytes: Int64
  ) async throws -> DownloadRecord {
    try await database.writeAsync { db in
      try Self.updateProgress(downloadId: downloadId, receivedBytes: receivedBytes, in: db)
    }
  }

  private static func updateProgress(
    downloadId: Int64, receivedBytes: Int64, in db: Database
  ) throws -> DownloadRecord {
    guard var record = try DownloadRecord.fetchOne(db, key: downloadId) else {
      throw DownloadStoreError.downloadNotFound(downloadId)
    }
    guard record.state == .downloading else {
      throw DownloadStoreError.illegalTransition(from: record.state, to: .downloading)
    }
    record.receivedBytes = receivedBytes
    // A progress checkpoint is the hottest write in the download pipeline. Updating the full
    // record here made SQLite/GRDB treat every download column as changed, waking unrelated
    // list observations on every URLSession callback. Keep the write column-exact.
    try db.execute(
      sql: "UPDATE download SET receivedBytes = ? WHERE id = ?",
      arguments: [receivedBytes, downloadId])
    return record
  }
}
