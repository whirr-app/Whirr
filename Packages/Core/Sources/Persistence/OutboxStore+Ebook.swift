import Foundation
import GRDB

extension OutboxStore {
  /// Coalescing key: `ebook-position:<accountId>:<serverItemId>`. Ebook position operations for
  /// the same `(account, item)` coalesce with each other, newest position wins; the shared-finish
  /// operation coalesces with nothing, including other finishes; and neither ever coalesces with
  /// an audio progress operation. The operation kind is part of the query as well as this key,
  /// so a caller cannot merge the two media shapes by passing the same arbitrary string.
  public static func ebookPositionCoalescingKey(accountId: Int64, entityKey: String) -> String {
    "ebook-position:\(accountId):\(entityKey)"
  }

  /// Enqueues an ebook position operation, coalescing only an unsent ebook position for the same
  /// account/item. `updatingLocalState` is part of this transaction;
  /// `MediaProgressDAO.writeEbookPositionAndEnqueueAsync` is the typed production wrapper.
  @discardableResult
  public func enqueueEbookPosition(
    accountId: Int64,
    entityKey: String,
    localSequence: Int64,
    payload: OutboxEbookPositionPayload,
    clientOperationId: @autoclosure () -> String = UUID().uuidString,
    payloadVersion: Int = 1,
    updatingLocalState: @Sendable (Database) throws -> Void = { _ in }
  ) throws -> OutboxOperationRecord {
    let newClientOperationId = clientOperationId()
    return try database.write { db in
      try updatingLocalState(db)
      return try Self.enqueueEbookPosition(
        db,
        accountId: accountId,
        entityKey: entityKey,
        localSequence: localSequence,
        payload: payload,
        clientOperationId: newClientOperationId,
        payloadVersion: payloadVersion)
    }
  }

  /// The already-open-transaction core used by `MediaProgressDAO` so the local progress row and
  /// its outbox operation commit together, never as two nested writes.
  @discardableResult
  static func enqueueEbookPosition(
    _ db: Database,
    accountId: Int64,
    entityKey: String,
    localSequence: Int64,
    payload: OutboxEbookPositionPayload,
    clientOperationId: String,
    payloadVersion: Int = 1
  ) throws -> OutboxOperationRecord {
    let coalescingKey = Self.ebookPositionCoalescingKey(
      accountId: accountId, entityKey: entityKey)
    let mergeableStateValues = Self.mergeableStates.map(\.rawValue)
    if var existing =
      try OutboxOperationRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("entityKey") == entityKey)
      .filter(Column("podcastEpisodeId") == nil)
      .filter(Column("coalescingKey") == coalescingKey)
      .filter(Column("operationKind") == OutboxOperationKind.ebookPosition.rawValue)
      .filter(mergeableStateValues.contains(Column("state")))
      .fetchOne(db)
    {
      existing.payloadEbookProgress = payload.ebookProgress
      existing.payloadEbookLocation = payload.ebookLocation
      existing.localSequence = localSequence
      try existing.update(db)
      return existing
    }

    var record = OutboxOperationRecord(
      accountId: accountId,
      clientOperationId: clientOperationId,
      entityKey: entityKey,
      podcastEpisodeId: nil,
      operationKind: OutboxOperationKind.ebookPosition.rawValue,
      coalescingKey: coalescingKey,
      payloadVersion: payloadVersion,
      localSequence: localSequence,
      payloadEbookProgress: payload.ebookProgress,
      payloadEbookLocation: payload.ebookLocation)
    try record.insert(db)
    return record
  }

  /// The already-open-transaction core for a non-coalescing ebook reset. A reset is an explicit
  /// boundary and must remain ordered behind any earlier ebook position or finish operation.
  @discardableResult
  static func enqueueEbookReset(
    _ db: Database,
    accountId: Int64,
    entityKey: String,
    localSequence: Int64,
    clientOperationId: String = UUID().uuidString,
    payloadVersion: Int = 1
  ) throws -> OutboxOperationRecord {
    let liveStates = [
      OutboxOperationState.pending,
      .sending,
      .retryWaiting,
    ].map(\.rawValue)
    let latestEbookSequence =
      try Int64.fetchOne(
        db,
        sql: """
          SELECT MAX(localSequence) FROM outboxOperation
          WHERE accountId = ? AND entityKey = ?
            AND operationKind IN (?, ?, ?) AND state IN (?, ?, ?)
          """,
        arguments: [
          accountId, entityKey,
          OutboxOperationKind.ebookPosition.rawValue,
          OutboxOperationKind.sharedFinish.rawValue,
          OutboxOperationKind.ebookReset.rawValue,
          liveStates[0], liveStates[1], liveStates[2],
        ]) ?? 0

    var record = OutboxOperationRecord(
      accountId: accountId,
      clientOperationId: clientOperationId,
      entityKey: entityKey,
      podcastEpisodeId: nil,
      operationKind: OutboxOperationKind.ebookReset.rawValue,
      coalescingKey: "ebook-reset:\(clientOperationId)",
      payloadVersion: payloadVersion,
      localSequence: max(localSequence, latestEbookSequence + 1))
    try record.insert(db)
    return record
  }

  /// Enqueues the shared finish as a fresh row every time. It has no coalescing segment, and its
  /// local sequence is raised past every still-live ebook position for the same item so a finish
  /// cannot overtake a queued position. `updatingLocalState` is committed with the row.
  @discardableResult
  public func enqueueSharedFinish(
    accountId: Int64,
    entityKey: String,
    localSequence: Int64,
    clientOperationId: @autoclosure () -> String = UUID().uuidString,
    payloadVersion: Int = 1,
    updatingLocalState: @Sendable (Database) throws -> Void = { _ in }
  ) throws -> OutboxOperationRecord {
    let newClientOperationId = clientOperationId()
    return try database.write { db in
      try updatingLocalState(db)
      return try Self.enqueueSharedFinish(
        db,
        accountId: accountId,
        entityKey: entityKey,
        localSequence: localSequence,
        clientOperationId: newClientOperationId,
        payloadVersion: payloadVersion)
    }
  }

  /// The already-open-transaction core for the ebook-safe finish intent.
  @discardableResult
  static func enqueueSharedFinish(
    _ db: Database,
    accountId: Int64,
    entityKey: String,
    localSequence: Int64,
    clientOperationId: String,
    payloadVersion: Int = 1
  ) throws -> OutboxOperationRecord {
    let liveStates = [
      OutboxOperationState.pending,
      .sending,
      .retryWaiting,
    ].map(\.rawValue)
    let latestPositionSequence =
      try Int64.fetchOne(
        db,
        sql: """
          SELECT MAX(localSequence) FROM outboxOperation
          WHERE accountId = ? AND entityKey = ?
            AND operationKind = ? AND state IN (?, ?, ?)
          """,
        arguments: [
          accountId, entityKey, OutboxOperationKind.ebookPosition.rawValue,
          liveStates[0], liveStates[1], liveStates[2],
        ]) ?? 0
    let orderedSequence = max(localSequence, latestPositionSequence + 1)

    var record = OutboxOperationRecord(
      accountId: accountId,
      clientOperationId: clientOperationId,
      entityKey: entityKey,
      podcastEpisodeId: nil,
      operationKind: OutboxOperationKind.sharedFinish.rawValue,
      // A unique key marks the absence of a merge segment while satisfying the schema's non-null
      // identity column. Never used as a merge key for this operation kind.
      coalescingKey: "shared-finish:\(clientOperationId)",
      payloadVersion: payloadVersion,
      localSequence: orderedSequence)
    try record.insert(db)
    return record
  }
}
