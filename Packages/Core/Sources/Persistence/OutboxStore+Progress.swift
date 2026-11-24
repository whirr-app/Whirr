import Foundation
import GRDB

extension OutboxStore {
  // MARK: - Enqueue + coalescing

  /// Enqueues a `progress`-kind mutation, coalescing it into an existing unsent operation for the
  /// same account + entity + coalescing key. `updatingLocalState` runs in the outbox write's
  /// transaction, so the entity change and its outbox row commit together or not at all.
  ///
  /// `podcastEpisodeId` has no default: a defaulted `nil` would silently scope an episode's
  /// progress to its show, indistinguishable to the drain from an item-level mutation.
  @discardableResult
  public func enqueueProgress(
    accountId: Int64,
    entityKey: String,
    podcastEpisodeId: Int64?,
    coalescingKey: String,
    localSequence: Int64,
    payload: OutboxProgressPayload,
    clientOperationId: @autoclosure () -> String = UUID().uuidString,
    payloadVersion: Int = 1,
    updatingLocalState: @Sendable (Database) throws -> Void = { _ in }
  ) throws -> OutboxOperationRecord {
    let newClientOperationId = clientOperationId()
    return try database.write { db in
      try updatingLocalState(db)
      return try Self.enqueueProgress(
        db,
        accountId: accountId,
        entityKey: entityKey,
        podcastEpisodeId: podcastEpisodeId,
        coalescingKey: coalescingKey,
        localSequence: localSequence,
        payload: payload,
        clientOperationId: newClientOperationId,
        payloadVersion: payloadVersion)
    }
  }

  /// The coalescing key every local-session position mirror shares: one unsent row per identity,
  /// overwritten by each tick rather than queued per tick.
  public static let localSessionProgressCoalescingKey = "local-session-progress"

  /// The prefix a playback finished-transition assertion coalesces under, segment-keyed so it can
  /// never merge with (or be overwritten by) a plain position for the same identity.
  public static let playbackFinishedCoalescingKeyPrefix = "playback-finished:"

  /// Module-internal core of `enqueueProgress`, run on an already-open `db` instead of opening its
  /// own transaction. For callers such as `PlaybackSessionStore.markSessionGone` that combine
  /// preserving the last known position through the ordinary progress path with other writes
  /// (marking a session dead, removing its live-session outbox rows) in one transaction.
  @discardableResult
  static func enqueueProgress(
    _ db: Database,
    accountId: Int64,
    entityKey: String,
    podcastEpisodeId: Int64?,
    coalescingKey: String,
    localSequence: Int64,
    payload: OutboxProgressPayload,
    clientOperationId: @autoclosure () -> String = UUID().uuidString,
    payloadVersion: Int = 1
  ) throws -> OutboxOperationRecord {
    let mergeableStateValues = Self.mergeableStates.map(\.rawValue)
    if var existing =
      try OutboxOperationRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("entityKey") == entityKey)
      .filter(Column("podcastEpisodeId") == podcastEpisodeId)
      .filter(Column("coalescingKey") == coalescingKey)
      .filter(Column("operationKind") == OutboxOperationKind.progress.rawValue)
      .filter(
        mergeableStateValues.contains(Column("state"))
          || (Column("state") == OutboxOperationState.deadLetter.rawValue
            && Column("deadLetterReason") == Self.quarantinedItemDeadLetterReason)
      )
      .fetchOne(db)
    {
      existing.payloadCurrentTime = payload.currentTime
      existing.payloadIsFinished = payload.isFinished
      existing.payloadAccumulatedDeltaSeconds =
        (existing.payloadAccumulatedDeltaSeconds ?? 0) + payload.accumulatedDeltaSeconds
      existing.localSequence = localSequence
      try Self.updateRespectingItemQuarantine(db, record: &existing)
      return existing
    }

    var record = OutboxOperationRecord(
      accountId: accountId,
      clientOperationId: clientOperationId(),
      entityKey: entityKey,
      podcastEpisodeId: podcastEpisodeId,
      operationKind: OutboxOperationKind.progress.rawValue,
      coalescingKey: coalescingKey,
      payloadVersion: payloadVersion,
      localSequence: localSequence,
      payloadCurrentTime: payload.currentTime,
      payloadIsFinished: payload.isFinished,
      payloadAccumulatedDeltaSeconds: payload.accumulatedDeltaSeconds)
    try Self.insertRespectingItemQuarantine(db, record: &record)
    return record
  }
}
