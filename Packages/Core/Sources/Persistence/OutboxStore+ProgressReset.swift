import Foundation
import GRDB

/// The medium a `progressReset` operation clears. An episode reset is an `audio` reset scoped by
/// the operation's `podcastEpisodeId`.
public enum ProgressResetMedium: String, Sendable, Equatable {
  case audio
  case ebook
}

/// A `progressReset` operation's persisted send phase. Each phase is recorded before the request
/// that depends on it, so a crash or retry resumes where the last one stopped.
public enum ProgressResetPhase: String, Sendable, Equatable {
  /// Nothing has been sent. The drain reads the server row and captures the other medium.
  case resolve
  /// The capture is persisted and the row is being deleted. A resumed attempt re-reads the row and
  /// deletes whatever is still there, keeping the first capture.
  case delete
  /// The row is gone. Only the restore PATCH of the captured position remains, if there is one.
  case restore
}

/// The server's position for the medium a reset must preserve, read before the delete. Taking it
/// from the server rather than from this device's row means a stale device cannot regress a newer
/// position another device wrote to that medium.
public struct ProgressResetCapture: Sendable, Equatable {
  public let currentTime: Double?
  public let progress: Double?
  public let ebookProgress: Double?
  public let ebookLocation: String?

  public init(
    currentTime: Double? = nil,
    progress: Double? = nil,
    ebookProgress: Double? = nil,
    ebookLocation: String? = nil
  ) {
    self.currentTime = currentTime
    self.progress = progress
    self.ebookProgress = ebookProgress
    self.ebookLocation = ebookLocation
  }

  public static let none = ProgressResetCapture()
}

extension OutboxOperationRecord {
  public var progressResetMedium: ProgressResetMedium? {
    payloadResetMedium.flatMap(ProgressResetMedium.init(rawValue:))
  }

  /// A row with no recorded phase has sent nothing yet.
  public var progressResetPhase: ProgressResetPhase {
    payloadResetPhase.flatMap(ProgressResetPhase.init(rawValue:)) ?? .resolve
  }

  public var progressResetCapture: ProgressResetCapture {
    ProgressResetCapture(
      currentTime: payloadCurrentTime,
      progress: payloadRestoreProgress,
      ebookProgress: payloadEbookProgress,
      ebookLocation: payloadEbookLocation)
  }
}

extension OutboxStore {
  /// Enqueues a reset as a fresh row that coalesces with nothing. An ebook reset's sequence is
  /// raised past every still-live ebook operation for the item, as the other ebook kinds do, so it
  /// cannot overtake a queued ebook position.
  @discardableResult
  static func enqueueProgressReset(
    _ db: Database,
    accountId: Int64,
    entityKey: String,
    podcastEpisodeId: Int64?,
    medium: ProgressResetMedium,
    localSequence: Int64,
    clientOperationId: String = UUID().uuidString
  ) throws -> OutboxOperationRecord {
    var sequence = localSequence
    if medium == .ebook {
      let liveStates = [OutboxOperationState.pending, .sending, .retryWaiting].map(\.rawValue)
      let latestEbookSequence =
        try Int64.fetchOne(
          db,
          sql: """
            SELECT MAX(localSequence) FROM outboxOperation
            WHERE accountId = ? AND entityKey = ?
              AND (operationKind IN (?, ?, ?)
                OR (operationKind = ? AND payloadResetMedium = ?))
              AND state IN (?, ?, ?)
            """,
          arguments: [
            accountId, entityKey,
            OutboxOperationKind.ebookPosition.rawValue,
            OutboxOperationKind.sharedFinish.rawValue,
            OutboxOperationKind.ebookReset.rawValue,
            OutboxOperationKind.progressReset.rawValue, ProgressResetMedium.ebook.rawValue,
            liveStates[0], liveStates[1], liveStates[2],
          ]) ?? 0
      sequence = max(localSequence, latestEbookSequence + 1)
    }
    var record = OutboxOperationRecord(
      accountId: accountId,
      clientOperationId: clientOperationId,
      entityKey: entityKey,
      podcastEpisodeId: podcastEpisodeId,
      operationKind: OutboxOperationKind.progressReset.rawValue,
      coalescingKey: "reset:\(clientOperationId)",
      payloadVersion: 1,
      localSequence: sequence,
      payloadResetMedium: medium.rawValue,
      payloadResetPhase: ProgressResetPhase.resolve.rawValue)
    try Self.insertRespectingItemQuarantine(db, record: &record)
    return record
  }

  /// Persists the capture and enters the delete phase, before the first DELETE is sent. A row that
  /// already holds a capture keeps it: the first read is the only one taken before anything was
  /// deleted.
  public func recordProgressResetCaptureAsync(
    operationId: Int64, capture: ProgressResetCapture
  ) async throws {
    try await database.writeAsync { db in
      guard var operation = try OutboxOperationRecord.fetchOne(db, key: operationId) else {
        throw OutboxStoreError.operationNotFound(operationId)
      }
      guard operation.progressResetPhase == .resolve else { return }
      operation.payloadCurrentTime = capture.currentTime
      operation.payloadRestoreProgress = capture.progress
      operation.payloadEbookProgress = capture.ebookProgress
      operation.payloadEbookLocation = capture.ebookLocation
      operation.payloadResetPhase = ProgressResetPhase.delete.rawValue
      try operation.update(db)
    }
  }

  /// Records that the server row is gone, so a later attempt sends only the restore.
  public func advanceProgressResetToRestoreAsync(operationId: Int64) async throws {
    try await database.writeAsync { db in
      guard var operation = try OutboxOperationRecord.fetchOne(db, key: operationId) else {
        throw OutboxStoreError.operationNotFound(operationId)
      }
      operation.payloadResetPhase = ProgressResetPhase.restore.rawValue
      try operation.update(db)
    }
  }
}
