import Foundation
import GRDB

extension PlaybackSessionStore {
  // MARK: - Local session upload material + acknowledgement

  /// Everything `OutboxDrainer`'s bounded `local-all` batch drain needs to map one
  /// `localSessionUpload` outbox row to an `ABSApi.LocalPlaybackSession` payload, without that
  /// module reaching into `ItemRecord`/`PodcastEpisodeRecord` directly.
  public struct LocalSessionUploadMaterial: Sendable, Equatable {
    public let clientSessionId: String
    public let itemServerId: String
    public let episodeServerId: String?
    public let startedAt: Date
    public let updatedAt: Date
    /// The session's frozen opening position, uploaded as the payload's `startTime` (the server
    /// persists no start of its own for a local session). `nil` for a session opened before the
    /// column existed, or one whose start was never recorded. The payload then omits the field
    /// rather than claiming a start at zero.
    public let startPosition: Double?
    public let isFinished: Bool
    public let state: PlaybackSessionState

    public init(
      clientSessionId: String, itemServerId: String, episodeServerId: String?, startedAt: Date, updatedAt: Date,
      startPosition: Double? = nil, isFinished: Bool, state: PlaybackSessionState
    ) {
      self.clientSessionId = clientSessionId
      self.itemServerId = itemServerId
      self.episodeServerId = episodeServerId
      self.startedAt = startedAt
      self.updatedAt = updatedAt
      self.startPosition = startPosition
      self.isFinished = isFinished
      self.state = state
    }
  }

  /// `nil` if the session row is already gone (an acknowledged/discarded upload, or a row that
  /// never existed). The caller treats that like `sendSessionOperation`'s "no session identity to
  /// send against" ambiguity: nothing to retry toward, so the row is retained.
  public func fetchLocalSessionUploadMaterial(sessionId: Int64) throws -> LocalSessionUploadMaterial? {
    try database.read { db in try Self.fetchLocalSessionUploadMaterial(db, sessionId: sessionId) }
  }

  public func fetchLocalSessionUploadMaterialAsync(
    sessionId: Int64
  ) async throws -> LocalSessionUploadMaterial? {
    try await database.readAsync { db in
      try Self.fetchLocalSessionUploadMaterial(db, sessionId: sessionId)
    }
  }

  /// Acknowledges a successful `local-all` upload for one session: deletes the
  /// `localSessionUpload` outbox row and the session row in one transaction. Once the server has
  /// accepted the whole-session upload, neither row is needed again.
  public func acknowledgeLocalUpload(operationId: Int64, sessionId: Int64) throws {
    try outbox.acknowledge(operationId: operationId) { db in
      if let session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) {
        _ = try session.delete(db)
      }
    }
  }

  /// Releases a session's held (`needsResolution`) `localSessionUpload` row after an explicit
  /// keep-local confirmation. Overwrites the session's `startedAt`/`updatedAt` with the clamped
  /// values that will be uploaded next, which lets a possibly newer clamped timestamp win under
  /// the server's last-write-wins behaviour and stops the skew check re-flagging the row on a
  /// later drain. Then returns the operation to `pending` so the next drain sends it normally.
  public func releaseHeldLocalUpload(
    operationId: Int64, sessionId: Int64, clampedStartedAt: Date, clampedUpdatedAt: Date
  ) throws {
    try database.write { db in
      try Self.updateHeldLocalUpload(
        db, sessionId: sessionId, clampedStartedAt: clampedStartedAt,
        clampedUpdatedAt: clampedUpdatedAt)
    }
    _ = try? database.write { db in
      try Self.transitionHeldLocalUploadToPending(db, operationId: operationId)
    }
  }

  public func releaseHeldLocalUploadAsync(
    operationId: Int64, sessionId: Int64, clampedStartedAt: Date, clampedUpdatedAt: Date
  ) async throws {
    try await database.writeAsync { db in
      try Self.updateHeldLocalUpload(
        db, sessionId: sessionId, clampedStartedAt: clampedStartedAt,
        clampedUpdatedAt: clampedUpdatedAt)
    }
    _ = try? await database.writeAsync { db in
      try Self.transitionHeldLocalUploadToPending(db, operationId: operationId)
    }
  }

  /// Take-server / discard-upload: removes the held operation without claiming it was uploaded.
  /// The session row is retained as local history (never deleted, never re-queued).
  public func discardHeldLocalUpload(operationId: Int64) throws {
    try database.write { db in try Self.discardHeldLocalUpload(db, operationId: operationId) }
  }

  public func discardHeldLocalUploadAsync(operationId: Int64) async throws {
    try await database.writeAsync { db in
      try Self.discardHeldLocalUpload(db, operationId: operationId)
    }
  }

  /// As the plain overload above, but also applies the server progress value a just-fetched
  /// item-progress refresh returned, in the same transaction as removing the held operation. A
  /// resolution is never half done ("discarded but not applied" or "applied but still held").
  /// The session row is left alone (retained as local history, never marked uploaded).
  public func discardHeldLocalUpload(
    operationId: Int64,
    sessionId: Int64,
    applyingServerCurrentTime serverCurrentTime: Double,
    serverIsFinished: Bool,
    serverUpdatedAt: Date?
  ) throws {
    try database.write { db in
      try Self.discardHeldLocalUpload(
        db,
        operationId: operationId,
        sessionId: sessionId,
        applyingServerCurrentTime: serverCurrentTime,
        serverIsFinished: serverIsFinished,
        serverUpdatedAt: serverUpdatedAt)
    }
  }

  public func discardHeldLocalUploadAsync(
    operationId: Int64,
    sessionId: Int64,
    applyingServerCurrentTime serverCurrentTime: Double,
    serverIsFinished: Bool,
    serverUpdatedAt: Date?
  ) async throws {
    try await database.writeAsync { db in
      try Self.discardHeldLocalUpload(
        db,
        operationId: operationId,
        sessionId: sessionId,
        applyingServerCurrentTime: serverCurrentTime,
        serverIsFinished: serverIsFinished,
        serverUpdatedAt: serverUpdatedAt)
    }
  }

  private static func fetchLocalSessionUploadMaterial(
    _ db: Database, sessionId: Int64
  ) throws -> LocalSessionUploadMaterial? {
    guard let session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) else { return nil }
    guard let itemRecord = try ItemRecord.fetchOne(db, key: session.itemId) else { return nil }
    var episodeServerId: String?
    if let episodeRowId = session.podcastEpisodeId {
      episodeServerId = try PodcastEpisodeRecord.fetchOne(db, key: episodeRowId)?.serverEpisodeId
    }
    let isFinished = try Self.fetchProgress(db, session: session)?.isFinished ?? false
    return LocalSessionUploadMaterial(
      clientSessionId: session.clientSessionId, itemServerId: itemRecord.serverItemId,
      episodeServerId: episodeServerId, startedAt: session.startedAt, updatedAt: session.updatedAt,
      startPosition: session.startPosition, isFinished: isFinished, state: session.state)
  }

  private static func updateHeldLocalUpload(
    _ db: Database,
    sessionId: Int64,
    clampedStartedAt: Date,
    clampedUpdatedAt: Date
  ) throws {
    guard var session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) else { return }
    session.startedAt = clampedStartedAt
    session.updatedAt = clampedUpdatedAt
    try session.update(db)
  }

  private static func transitionHeldLocalUploadToPending(
    _ db: Database, operationId: Int64
  ) throws {
    guard var record = try OutboxOperationRecord.fetchOne(db, key: operationId) else {
      throw OutboxStoreError.operationNotFound(operationId)
    }
    guard OutboxStore.legalTransitions[record.state]?.contains(.pending) == true else {
      throw OutboxStoreError.illegalTransition(from: record.state, to: .pending)
    }
    record.state = .pending
    record.nextAttemptAt = nil
    record.deadLetterReason = nil
    try record.update(db)
  }

  private static func discardHeldLocalUpload(
    _ db: Database, operationId: Int64
  ) throws {
    guard let operation = try OutboxOperationRecord.fetchOne(db, key: operationId) else {
      throw OutboxStoreError.operationNotFound(operationId)
    }
    _ = try operation.delete(db)
  }

  private static func discardHeldLocalUpload(
    _ db: Database,
    operationId: Int64,
    sessionId: Int64,
    applyingServerCurrentTime serverCurrentTime: Double,
    serverIsFinished: Bool,
    serverUpdatedAt: Date?
  ) throws {
    guard let operation = try OutboxOperationRecord.fetchOne(db, key: operationId) else {
      throw OutboxStoreError.operationNotFound(operationId)
    }
    guard let session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) else {
      _ = try operation.delete(db)
      return
    }
    var progress =
      try Self.fetchProgress(db, session: session)
      ?? MediaProgressRecord(
        accountId: session.accountId,
        itemId: session.itemId,
        podcastEpisodeId: session.podcastEpisodeId,
        currentTime: serverCurrentTime,
        isFinished: serverIsFinished,
        serverUpdatedAt: serverUpdatedAt,
        localSequence: 0,
        origin: .server,
        originKey: ProgressOrigin.serverOriginKey)
    progress.currentTime = serverCurrentTime
    progress.isFinished = serverIsFinished
    progress.serverUpdatedAt = serverUpdatedAt
    // Taking the server's value is itself the newest observation of this item.
    progress.lastActivityAt = serverUpdatedAt ?? progress.lastActivityAt
    progress.origin = .server
    progress.originKey = ProgressOrigin.serverOriginKey
    try progress.save(db)

    // Rule 11a: this device's own unsent position/finished claims for the same identity die with
    // the upload they belonged to. Leaving one queued would re-push the value the user has just
    // resolved away from, on the very next drain.
    if let item = try ItemRecord.fetchOne(db, key: session.itemId) {
      try OutboxStore.deleteUnsentLocalPlaybackProgress(
        db, accountId: session.accountId, entityKey: item.serverItemId,
        podcastEpisodeId: session.podcastEpisodeId)
    }
    _ = try operation.delete(db)
  }
}
