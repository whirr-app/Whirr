import Foundation
import GRDB

extension OutboxStore {
  /// Deletes every unsent progress row this device's playback queued for one identity (position
  /// mirrors and finished assertions). Used by the take-server resolution
  /// (`PlaybackSessionStore.discardHeldLocalUpload(applyingServerCurrentTime:…)`): a surviving
  /// local claim would push the abandoned value back on the next drain. `.sending` rows are left
  /// for the drainer to acknowledge.
  static func deleteUnsentLocalPlaybackProgress(
    _ db: Database, accountId: Int64, entityKey: String, podcastEpisodeId: Int64?
  ) throws {
    let mergeableStateValues = Self.mergeableStates.map(\.rawValue)
    _ =
      try OutboxOperationRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("entityKey") == entityKey)
      .filter(Column("podcastEpisodeId") == podcastEpisodeId)
      .filter(Column("operationKind") == OutboxOperationKind.progress.rawValue)
      .filter(
        mergeableStateValues.contains(Column("state"))
          || (Column("state") == OutboxOperationState.deadLetter.rawValue
            && Column("deadLetterReason") == Self.quarantinedItemDeadLetterReason)
      )
      .filter(
        Column("coalescingKey") == Self.localSessionProgressCoalescingKey
          || Column("coalescingKey").like("\(Self.playbackFinishedCoalescingKeyPrefix)%")
      )
      .deleteAll(db)
  }

  /// Enqueues a `sessionSync`-kind mutation, coalescing it into an existing unsent operation for
  /// the same session + coalescing key. Identity is checked against `playbackSessionId` (an
  /// explicit FK), not just the `coalescingKey`/`entityKey` strings. `updatingLocalState` runs in
  /// the outbox write's transaction, so `MediaProgress`, the session row and this outbox row
  /// commit together or not at all.
  @discardableResult
  public func enqueueSessionSync(
    accountId: Int64,
    playbackSessionId: Int64,
    entityKey: String,
    coalescingKey: String,
    localSequence: Int64,
    payload: OutboxSessionPayload,
    clientOperationId: @autoclosure () -> String = UUID().uuidString,
    payloadVersion: Int = 1,
    updatingLocalState: @Sendable (Database) throws -> Void = { _ in }
  ) throws -> OutboxOperationRecord {
    let newClientOperationId = clientOperationId()
    return try database.write { db in
      try updatingLocalState(db)
      return try enqueueSessionSync(
        in: db,
        accountId: accountId,
        playbackSessionId: playbackSessionId,
        entityKey: entityKey,
        coalescingKey: coalescingKey,
        localSequence: localSequence,
        payload: payload,
        clientOperationId: newClientOperationId,
        payloadVersion: payloadVersion)
    }
  }

  func enqueueSessionSync(
    in db: Database,
    accountId: Int64,
    playbackSessionId: Int64,
    entityKey: String,
    coalescingKey: String,
    localSequence: Int64,
    payload: OutboxSessionPayload,
    clientOperationId: String,
    payloadVersion: Int = 1
  ) throws -> OutboxOperationRecord {
    let mergeableStateValues = Self.mergeableStates.map(\.rawValue)
    if var existing =
      try OutboxOperationRecord
      .filter(Column("playbackSessionId") == playbackSessionId)
      .filter(Column("coalescingKey") == coalescingKey)
      .filter(Column("operationKind") == OutboxOperationKind.sessionSync.rawValue)
      .filter(mergeableStateValues.contains(Column("state")))
      .fetchOne(db)
    {
      existing.payloadCurrentTime = payload.currentTime
      existing.payloadAccumulatedDeltaSeconds =
        (existing.payloadAccumulatedDeltaSeconds ?? 0) + payload.accumulatedDeltaSeconds
      existing.payloadDurationSeconds = payload.durationSeconds
      existing.localSequence = localSequence
      try Self.updateRespectingItemQuarantine(db, record: &existing)
      return existing
    }

    var record = OutboxOperationRecord(
      accountId: accountId,
      clientOperationId: clientOperationId,
      entityKey: entityKey,
      podcastEpisodeId: nil,
      operationKind: OutboxOperationKind.sessionSync.rawValue,
      coalescingKey: coalescingKey,
      payloadVersion: payloadVersion,
      localSequence: localSequence,
      payloadCurrentTime: payload.currentTime,
      payloadAccumulatedDeltaSeconds: payload.accumulatedDeltaSeconds,
      payloadDurationSeconds: payload.durationSeconds,
      playbackSessionId: playbackSessionId)
    try Self.insertRespectingItemQuarantine(db, record: &record)
    return record
  }

  /// Enqueues a `sessionClose`-kind mutation. Close is a coalescing boundary in its own right,
  /// so this always inserts a fresh row rather than merging into an existing `sessionSync` row.
  /// The close row carries only the remainder delta not already captured by an earlier row.
  /// `updatingLocalState` runs in the same transaction as the insert, so the session's frozen
  /// delta/`closePending` and this outbox row commit together or neither does.
  @discardableResult
  public func enqueueSessionClose(
    accountId: Int64,
    playbackSessionId: Int64,
    entityKey: String,
    coalescingKey: String,
    localSequence: Int64,
    payload: OutboxSessionPayload,
    clientOperationId: @autoclosure () -> String = UUID().uuidString,
    payloadVersion: Int = 1,
    updatingLocalState: @Sendable (Database) throws -> Void = { _ in }
  ) throws -> OutboxOperationRecord {
    let newClientOperationId = clientOperationId()
    return try enqueueSessionBoundary(
      operationKind: .sessionClose,
      accountId: accountId,
      playbackSessionId: playbackSessionId,
      entityKey: entityKey,
      coalescingKey: coalescingKey,
      localSequence: localSequence,
      payload: payload,
      clientOperationId: newClientOperationId,
      payloadVersion: payloadVersion,
      updatingLocalState: updatingLocalState)
  }

  /// Enqueues the single `localSessionUpload`-kind row a local session's close produces
  /// (API-CONVENTIONS rule 10). Always inserts a fresh row, as there is nothing to coalesce into
  /// (like `enqueueSessionClose`), and `updatingLocalState` runs in the same transaction as
  /// the insert, so the session's frozen delta/position/state and this outbox row commit together
  /// or neither does.
  @discardableResult
  public func enqueueLocalSessionUpload(
    accountId: Int64,
    playbackSessionId: Int64,
    entityKey: String,
    coalescingKey: String,
    localSequence: Int64,
    payload: OutboxSessionPayload,
    clientOperationId: @autoclosure () -> String = UUID().uuidString,
    payloadVersion: Int = 1,
    updatingLocalState: @Sendable (Database) throws -> Void = { _ in }
  ) throws -> OutboxOperationRecord {
    let newClientOperationId = clientOperationId()
    return try enqueueSessionBoundary(
      operationKind: .localSessionUpload,
      accountId: accountId,
      playbackSessionId: playbackSessionId,
      entityKey: entityKey,
      coalescingKey: coalescingKey,
      localSequence: localSequence,
      payload: payload,
      clientOperationId: newClientOperationId,
      payloadVersion: payloadVersion,
      updatingLocalState: updatingLocalState)
  }

  private func enqueueSessionBoundary(
    operationKind: OutboxOperationKind,
    accountId: Int64,
    playbackSessionId: Int64,
    entityKey: String,
    coalescingKey: String,
    localSequence: Int64,
    payload: OutboxSessionPayload,
    clientOperationId: String,
    payloadVersion: Int,
    updatingLocalState: @Sendable (Database) throws -> Void
  ) throws -> OutboxOperationRecord {
    try database.write { db in
      try updatingLocalState(db)
      var record = OutboxOperationRecord(
        accountId: accountId,
        clientOperationId: clientOperationId,
        entityKey: entityKey,
        podcastEpisodeId: nil,
        operationKind: operationKind.rawValue,
        coalescingKey: coalescingKey,
        payloadVersion: payloadVersion,
        localSequence: localSequence,
        payloadCurrentTime: payload.currentTime,
        payloadAccumulatedDeltaSeconds: payload.accumulatedDeltaSeconds,
        payloadDurationSeconds: payload.durationSeconds,
        playbackSessionId: playbackSessionId)
      try Self.insertRespectingItemQuarantine(db, record: &record)
      return record
    }
  }
}
