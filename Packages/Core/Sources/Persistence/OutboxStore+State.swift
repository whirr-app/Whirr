import Foundation
import GRDB

extension OutboxStore {
  /// Fixed privacy-safe terminal reason for work owned by a server item whose identity collides
  /// with a device namespace. These rows are audit evidence, not user-retryable server failures.
  static let quarantinedItemDeadLetterReason = "quarantinedItemIdentity"

  private static let queuedStateValues = [OutboxOperationState.pending, .retryWaiting]
    .map(\.rawValue)

  /// Inserts an operation in its final durable state. When either the operation's server item
  /// key or its playback-session owner is quarantined, the row is born terminal inside this same
  /// transaction; no observer can ever see runnable work for the invalid identity.
  static func insertRespectingItemQuarantine(
    _ db: Database, record: inout OutboxOperationRecord
  ) throws {
    if let quarantineItemID = try quarantineItemID(db, for: record) {
      record.state = .deadLetter
      record.nextAttemptAt = nil
      record.deadLetterReason = Self.quarantinedItemDeadLetterReason
      try incrementTerminalizedOperationCount(db, itemID: quarantineItemID)
    }
    try record.insert(db)
  }

  /// Applies the same invariant to a coalesced row. An already-terminal quarantine audit row can
  /// absorb a later payload update without inflating the marker count or becoming retryable.
  static func updateRespectingItemQuarantine(
    _ db: Database, record: inout OutboxOperationRecord
  ) throws {
    if let quarantineItemID = try quarantineItemID(db, for: record) {
      let newlyTerminalized =
        record.state != .deadLetter
        || record.deadLetterReason != Self.quarantinedItemDeadLetterReason
      record.state = .deadLetter
      record.nextAttemptAt = nil
      record.deadLetterReason = Self.quarantinedItemDeadLetterReason
      if newlyTerminalized {
        try incrementTerminalizedOperationCount(db, itemID: quarantineItemID)
      }
    }
    try record.update(db)
  }

  private static func quarantineItemID(
    _ db: Database, for record: OutboxOperationRecord
  ) throws -> Int64? {
    try Int64.fetchOne(
      db,
      sql: """
        SELECT itemQuarantine.itemId
        FROM itemQuarantine
        WHERE itemQuarantine.accountId = ?
          AND (
            itemQuarantine.serverItemId = ?
            OR itemQuarantine.itemId = (
              SELECT playbackSession.itemId
              FROM playbackSession
              WHERE playbackSession.id = ?
                AND playbackSession.accountId = ?
            )
          )
        LIMIT 1
        """,
      arguments: [
        record.accountId, record.entityKey, record.playbackSessionId, record.accountId,
      ])
  }

  private static func incrementTerminalizedOperationCount(
    _ db: Database, itemID: Int64
  ) throws {
    try db.execute(
      sql: """
        UPDATE itemQuarantine
        SET terminalizedOperationCount = terminalizedOperationCount + 1
        WHERE itemId = ?
        """,
      arguments: [itemID])
  }

  /// Outbound operations are keyed by the server item ID, except playback-session operations,
  /// which carry the item's local ID through `playbackSessionId`. Keep both forms behind one
  /// selection predicate so a durable quarantine marker is observed by every outbound drain path
  /// even after the invalid item itself is reaped. Ordinary soft deletion remains reversible and
  /// must not silently withhold runnable work.
  private static let outboundWorkItemEligibilitySQL = """
    NOT EXISTS (
      SELECT 1
      FROM itemQuarantine AS quarantinedItem
      WHERE quarantinedItem.accountId = outboxOperation.accountId
        AND (
          quarantinedItem.serverItemId = outboxOperation.entityKey
          OR EXISTS (
            SELECT 1
            FROM playbackSession AS operationSession
            WHERE operationSession.id = outboxOperation.playbackSessionId
              AND operationSession.accountId = outboxOperation.accountId
              AND operationSession.itemId = quarantinedItem.itemId
          )
        )
    )
    """

  /// The allowed-transition matrix; any other pair makes `transition(operationId:to:)` throw.
  ///
  /// - `pending -> sending`: a drain attempt begins.
  /// - `pending -> needsResolution`: a pull-side conflict flags a mutation never attempted.
  /// - `sending -> pending`: cancellation, or launch recovery after a crash mid-send; neither
  ///   counts as a further attempt.
  /// - `sending -> retryWaiting` / `-> deadLetter` / `-> needsResolution`: the outcomes of a send
  ///   (transient failure, permanent failure, conflict discovered concurrently with the response).
  /// - `retryWaiting -> sending`: the next attempt. `retryWaiting -> needsResolution`: a conflict
  ///   found while waiting.
  /// - `needsResolution -> pending`: resolved and re-queued. `needsResolution -> deadLetter`:
  ///   resolved by discarding.
  /// - `deadLetter -> pending`: a surfaced user action (retry / re-authenticate / refresh
  ///   metadata) re-queues it.
  ///
  /// Every other pair is illegal, including self-transitions and shortcuts such as
  /// `pending -> deadLetter` or `deadLetter -> sending` that skip a send attempt.
  static let legalTransitions: [OutboxOperationState: Set<OutboxOperationState>] = [
    .pending: [.sending, .needsResolution],
    .sending: [.pending, .retryWaiting, .deadLetter, .needsResolution],
    .retryWaiting: [.sending, .needsResolution],
    .needsResolution: [.pending, .deadLetter],
    .deadLetter: [.pending],
  ]

  // MARK: - Transitions

  /// Applies a state transition, throwing `OutboxStoreError.illegalTransition` if `to` is not
  /// reachable from the row's current state (see `legalTransitions`). Entering `sending` records
  /// an attempt; leaving `deadLetter` (or entering any state other than `deadLetter`) clears the
  /// prior dead-letter reason so it never lingers past its relevance.
  @discardableResult
  public func transition(
    operationId: Int64,
    to newState: OutboxOperationState,
    nextAttemptAt: Date? = nil,
    deadLetterReason: String? = nil
  ) throws -> OutboxOperationRecord {
    try database.write { db in
      try Self.transition(
        db,
        operationId: operationId,
        to: newState,
        nextAttemptAt: nextAttemptAt,
        deadLetterReason: deadLetterReason)
    }
  }

  @discardableResult
  public func transitionAsync(
    operationId: Int64,
    to newState: OutboxOperationState,
    nextAttemptAt: Date? = nil,
    deadLetterReason: String? = nil
  ) async throws -> OutboxOperationRecord {
    try await database.writeAsync { db in
      try Self.transition(
        db,
        operationId: operationId,
        to: newState,
        nextAttemptAt: nextAttemptAt,
        deadLetterReason: deadLetterReason)
    }
  }

  private static func transition(
    _ db: Database,
    operationId: Int64,
    to newState: OutboxOperationState,
    nextAttemptAt: Date?,
    deadLetterReason: String?
  ) throws -> OutboxOperationRecord {
    guard var record = try OutboxOperationRecord.fetchOne(db, key: operationId) else {
      throw OutboxStoreError.operationNotFound(operationId)
    }
    guard Self.legalTransitions[record.state]?.contains(newState) == true else {
      throw OutboxStoreError.illegalTransition(from: record.state, to: newState)
    }
    guard record.deadLetterReason != Self.quarantinedItemDeadLetterReason else {
      throw OutboxStoreError.illegalTransition(from: record.state, to: newState)
    }

    if newState == .sending {
      record.attempts += 1
    }
    record.state = newState
    record.nextAttemptAt = nextAttemptAt
    record.deadLetterReason = newState == .deadLetter ? deadLetterReason : nil
    try record.update(db)
    return record
  }

  // MARK: - Acknowledgement

  /// Deletes the operation only together with `updatingLocalState`'s write to the local
  /// authoritative state, in one transaction.
  public func acknowledge(
    operationId: Int64,
    updatingLocalState: @Sendable (Database) throws -> Void
  ) throws {
    try database.write { db in
      try Self.acknowledge(
        db, operationId: operationId, updatingLocalState: updatingLocalState)
    }
  }

  public func acknowledgeAsync(
    operationId: Int64,
    updatingLocalState: @Sendable (Database) throws -> Void
  ) async throws {
    try await database.writeAsync { db in
      try Self.acknowledge(
        db, operationId: operationId, updatingLocalState: updatingLocalState)
    }
  }

  private static func acknowledge(
    _ db: Database,
    operationId: Int64,
    updatingLocalState: @Sendable (Database) throws -> Void
  ) throws {
    guard let record = try OutboxOperationRecord.fetchOne(db, key: operationId) else {
      throw OutboxStoreError.operationNotFound(operationId)
    }
    try updatingLocalState(db)
    _ = try record.delete(db)
  }

  // MARK: - Queries

  /// A single operation by id, regardless of state. Used by `ResolutionCenter` to re-check
  /// idempotency before acting on a dead-letter/skew row a caller may have fetched a while ago.
  public func fetchOperation(id: Int64) throws -> OutboxOperationRecord? {
    try database.read { db in try OutboxOperationRecord.fetchOne(db, key: id) }
  }

  public func fetchOperationAsync(id: Int64) async throws -> OutboxOperationRecord? {
    try await database.readAsync { db in try OutboxOperationRecord.fetchOne(db, key: id) }
  }

  /// Every `deadLetter`-state operation for this account, across every kind. Input to
  /// `ResolutionCenter`'s dead-letter enumeration.
  public func fetchDeadLetters(accountId: Int64) throws -> [OutboxOperationRecord] {
    try database.read { db in try Self.fetchDeadLetters(db, accountId: accountId) }
  }

  public func fetchDeadLettersAsync(accountId: Int64) async throws -> [OutboxOperationRecord] {
    try await database.readAsync { db in try Self.fetchDeadLetters(db, accountId: accountId) }
  }

  private static func fetchDeadLetters(
    _ db: Database, accountId: Int64
  ) throws -> [OutboxOperationRecord] {
    try OutboxOperationRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("state") == OutboxOperationState.deadLetter.rawValue)
      .filter(
        Column("deadLetterReason") == nil
          || Column("deadLetterReason") != Self.quarantinedItemDeadLetterReason
      )
      .fetchAll(db)
  }

  /// Every `localSessionUpload` row currently held `needsResolution` (skew confirmations). Input to
  /// `ResolutionCenter`'s skew enumeration.
  public func fetchHeldLocalSessionUploads(accountId: Int64) throws -> [OutboxOperationRecord] {
    try database.read { db in try Self.fetchHeldLocalSessionUploads(db, accountId: accountId) }
  }

  public func fetchHeldLocalSessionUploadsAsync(
    accountId: Int64
  ) async throws -> [OutboxOperationRecord] {
    try await database.readAsync { db in
      try Self.fetchHeldLocalSessionUploads(db, accountId: accountId)
    }
  }

  private static func fetchHeldLocalSessionUploads(
    _ db: Database, accountId: Int64
  ) throws -> [OutboxOperationRecord] {
    try OutboxOperationRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("operationKind") == OutboxOperationKind.localSessionUpload.rawValue)
      .filter(Column("state") == OutboxOperationState.needsResolution.rawValue)
      .fetchAll(db)
  }

  /// Queued (unsent) operations for one entity, oldest `localSequence` first, the order the
  /// drain loop must preserve per entity. `id` (insertion order) is an explicit secondary sort:
  /// a `sessionClose` row can tie an already-queued `sessionSync` row's `localSequence` (an
  /// immediate close reuses the session's `lastLocalSequence` rather than minting a new one),
  /// and the secondary key makes "close waits behind earlier sync rows" deterministic.
  public func fetchQueued(accountId: Int64, entityKey: String) throws -> [OutboxOperationRecord] {
    return try database.read { db in
      try OutboxOperationRecord
        .fetchAll(
          db,
          sql: """
            SELECT outboxOperation.*
            FROM outboxOperation
            WHERE outboxOperation.accountId = ?
              AND outboxOperation.entityKey = ?
              AND outboxOperation.state IN (?, ?)
              AND \(Self.outboundWorkItemEligibilitySQL)
            ORDER BY outboxOperation.localSequence, outboxOperation.id
            """,
          arguments: [accountId, entityKey, Self.queuedStateValues[0], Self.queuedStateValues[1]])
    }
  }

  /// Every entity key with at least one queued (`pending`/`retryWaiting`) operation for this
  /// account, each listed once regardless of how many queued rows it has. The drain loop uses this
  /// to discover its keyed queues without enumerating operations directly.
  public func distinctQueuedEntityKeys(accountId: Int64) throws -> [String] {
    return try database.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT DISTINCT outboxOperation.entityKey
          FROM outboxOperation
          WHERE outboxOperation.accountId = ?
            AND outboxOperation.state IN (?, ?)
            AND outboxOperation.operationKind != ?
            AND \(Self.outboundWorkItemEligibilitySQL)
          """,
        arguments: [
          accountId, Self.queuedStateValues[0], Self.queuedStateValues[1],
          OutboxOperationKind.localSessionUpload.rawValue,
        ])
    }
  }

  /// Every queued (`pending`/`retryWaiting`) `localSessionUpload` operation for this account,
  /// oldest `localSequence` first, capped at `limit`: the bounded-batch input for
  /// `OutboxDrainer`'s `local-all` requests (API-CONVENTIONS.md rule 10).
  ///
  /// With `dueBy`, only rows whose `nextAttemptAt` is absent or not after it. The filter must run
  /// before `LIMIT`, or a full window of backed-off rows hides every newer due row.
  public func fetchQueuedLocalSessionUploads(
    accountId: Int64, limit: Int, dueBy: Date? = nil
  ) throws -> [OutboxOperationRecord] {
    return try database.read { db in
      var arguments: StatementArguments = [
        accountId, OutboxOperationKind.localSessionUpload.rawValue,
        Self.queuedStateValues[0], Self.queuedStateValues[1],
      ]
      var dueSQL = ""
      if let dueBy {
        dueSQL = "AND (outboxOperation.nextAttemptAt IS NULL OR outboxOperation.nextAttemptAt <= ?)"
        arguments += [dueBy]
      }
      arguments += [limit]
      return
        try OutboxOperationRecord
        .fetchAll(
          db,
          sql: """
            SELECT outboxOperation.*
            FROM outboxOperation
            WHERE outboxOperation.accountId = ?
              AND outboxOperation.operationKind = ?
              AND outboxOperation.state IN (?, ?)
              AND \(Self.outboundWorkItemEligibilitySQL)
              \(dueSQL)
            ORDER BY outboxOperation.localSequence, outboxOperation.id
            LIMIT ?
            """,
          arguments: arguments)
    }
  }
}
