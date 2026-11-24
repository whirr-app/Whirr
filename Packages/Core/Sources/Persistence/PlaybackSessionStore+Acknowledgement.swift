import Foundation
import GRDB

extension PlaybackSessionStore {
  // MARK: - Acknowledgement

  /// Subtracts `operationId`'s frozen delta from the session's unacknowledged total, keeping any
  /// delta a concurrent tick accrued afterwards, then deletes the outbox row, all in one
  /// transaction (`OutboxStore.acknowledge`).
  public func acknowledgeSync(operationId: Int64, sessionId: Int64) throws {
    try database.write { db in
      try Self.acknowledgeSync(db, operationId: operationId, sessionId: sessionId)
    }
  }

  public func acknowledgeSyncAsync(operationId: Int64, sessionId: Int64) async throws {
    try await database.writeAsync { db in
      try Self.acknowledgeSync(db, operationId: operationId, sessionId: sessionId)
    }
  }

  /// Removes the session row only in the same transaction as its `sessionClose` outbox row, via
  /// `OutboxStore.acknowledge`.
  public func acknowledgeClose(operationId: Int64, sessionId: Int64) throws {
    try database.write { db in
      try Self.acknowledgeClose(db, operationId: operationId, sessionId: sessionId)
    }
  }

  public func acknowledgeCloseAsync(operationId: Int64, sessionId: Int64) async throws {
    try await database.writeAsync { db in
      try Self.acknowledgeClose(db, operationId: operationId, sessionId: sessionId)
    }
  }

  private static func acknowledgeSync(
    _ db: Database, operationId: Int64, sessionId: Int64
  ) throws {
    guard let operation = try OutboxOperationRecord.fetchOne(db, key: operationId) else {
      throw OutboxStoreError.operationNotFound(operationId)
    }
    guard var session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) else {
      _ = try operation.delete(db)
      return
    }
    let acceptedDelta = operation.payloadAccumulatedDeltaSeconds ?? 0
    session.listenedDeltaSeconds -= acceptedDelta
    // The server added this much to the session's `timeListening` (`/sync` is additive), so the
    // running total moves in the same transaction that drops the operation.
    session.acknowledgedListenedSeconds += acceptedDelta
    try session.update(db)
    _ = try operation.delete(db)
  }

  private static func acknowledgeClose(
    _ db: Database, operationId: Int64, sessionId: Int64
  ) throws {
    guard let operation = try OutboxOperationRecord.fetchOne(db, key: operationId) else {
      throw OutboxStoreError.operationNotFound(operationId)
    }
    if let session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) {
      _ = try session.delete(db)
    }
    _ = try operation.delete(db)
  }
}
