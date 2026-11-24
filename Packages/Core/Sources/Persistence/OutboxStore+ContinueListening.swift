import Foundation
import GRDB

extension OutboxStore {
  /// The coalescing key for a field-only Continue Listening visibility mutation. The episode row
  /// id is part of the identity because a podcast show and each of its episodes have independent
  /// progress rows.
  public static func continueListeningVisibilityCoalescingKey(
    accountId: Int64,
    entityKey: String,
    podcastEpisodeId: Int64?
  ) -> String {
    let episodeKey = podcastEpisodeId.map(String.init) ?? "-"
    return "continue-listening:\(accountId):\(entityKey):\(episodeKey)"
  }

  /// Enqueues a visibility-only progress mutation. Hide and unhide share one operation kind and
  /// rewrite a pending/retry-waiting row in place so the newest intent is the only one drained.
  @discardableResult
  public func enqueueContinueListeningVisibility(
    accountId: Int64,
    entityKey: String,
    podcastEpisodeId: Int64?,
    localSequence: Int64,
    hideFromContinueListening: Bool,
    clientOperationId: @autoclosure () -> String = UUID().uuidString,
    payloadVersion: Int = 1,
    updatingLocalState: @Sendable (Database) throws -> Void = { _ in }
  ) throws -> OutboxOperationRecord {
    let newClientOperationId = clientOperationId()
    return try database.write { db in
      try updatingLocalState(db)
      return try Self.enqueueContinueListeningVisibility(
        db,
        accountId: accountId,
        entityKey: entityKey,
        podcastEpisodeId: podcastEpisodeId,
        localSequence: localSequence,
        hideFromContinueListening: hideFromContinueListening,
        clientOperationId: newClientOperationId,
        payloadVersion: payloadVersion)
    }
  }

  /// Already-open-transaction core used by `ItemProgressIntentStore`.
  @discardableResult
  static func enqueueContinueListeningVisibility(
    _ db: Database,
    accountId: Int64,
    entityKey: String,
    podcastEpisodeId: Int64?,
    localSequence: Int64,
    hideFromContinueListening: Bool,
    clientOperationId: String,
    payloadVersion: Int = 1
  ) throws -> OutboxOperationRecord {
    let coalescingKey = Self.continueListeningVisibilityCoalescingKey(
      accountId: accountId, entityKey: entityKey, podcastEpisodeId: podcastEpisodeId)
    let mergeableStateValues = Self.mergeableStates.map(\.rawValue)
    if var existing =
      try OutboxOperationRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("entityKey") == entityKey)
      .filter(Column("podcastEpisodeId") == podcastEpisodeId)
      .filter(Column("coalescingKey") == coalescingKey)
      .filter(Column("operationKind") == OutboxOperationKind.continueListeningVisibility.rawValue)
      .filter(mergeableStateValues.contains(Column("state")))
      .fetchOne(db)
    {
      existing.payloadHideFromContinueListening = hideFromContinueListening
      existing.localSequence = localSequence
      try existing.update(db)
      return existing
    }

    var record = OutboxOperationRecord(
      accountId: accountId,
      clientOperationId: clientOperationId,
      entityKey: entityKey,
      podcastEpisodeId: podcastEpisodeId,
      operationKind: OutboxOperationKind.continueListeningVisibility.rawValue,
      coalescingKey: coalescingKey,
      payloadVersion: payloadVersion,
      localSequence: localSequence,
      payloadHideFromContinueListening: hideFromContinueListening)
    try record.insert(db)
    return record
  }
}
