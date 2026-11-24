import Foundation
import GRDB

extension MediaProgressDAO {
  // MARK: - Conflict durability + resolution

  /// Records (or refreshes) the open `needsResolution` conflict for `itemId`: the server
  /// observation the zero-position guard just rejected. The persisted `MediaProgressRecord` is
  /// left untouched: it holds the local value that stays visible pending resolution (see
  /// `ProgressMergePolicy`). This row only remembers the rejected server side for a later
  /// take-server resolution. One row per (account, item): a pull that re-detects the same
  /// conflict updates it.
  @discardableResult
  public func recordConflict(
    accountId: Int64,
    identity: MediaProgressIdentity,
    serverCurrentTime: Double,
    serverIsFinished: Bool,
    serverUpdatedAt: Date?,
    detectedAt: Date
  ) throws -> ProgressConflictRecord {
    try database.write { db in
      try Self.upsertConflict(
        db, accountId: accountId, identity: identity, serverCurrentTime: serverCurrentTime,
        serverIsFinished: serverIsFinished, serverUpdatedAt: serverUpdatedAt, detectedAt: detectedAt)
    }
  }

  @discardableResult
  public func recordConflictAsync(
    accountId: Int64,
    identity: MediaProgressIdentity,
    serverCurrentTime: Double,
    serverIsFinished: Bool,
    serverUpdatedAt: Date?,
    detectedAt: Date
  ) async throws -> ProgressConflictRecord {
    try await database.writeAsync { db in
      try Self.upsertConflict(
        db, accountId: accountId, identity: identity, serverCurrentTime: serverCurrentTime,
        serverIsFinished: serverIsFinished, serverUpdatedAt: serverUpdatedAt, detectedAt: detectedAt)
    }
  }

  /// Every currently-open progress conflict for this account, as input to
  /// `ResolutionCenter`'s enumeration.
  public func fetchOpenConflicts(accountId: Int64) throws -> [ProgressConflictRecord] {
    try database.read { db in
      try Self.fetchOpenConflicts(db, accountId: accountId)
    }
  }

  public func fetchOpenConflictsAsync(accountId: Int64) async throws -> [ProgressConflictRecord] {
    try await database.readAsync { db in
      try Self.fetchOpenConflicts(db, accountId: accountId)
    }
  }

  public func fetchConflict(id: Int64) throws -> ProgressConflictRecord? {
    try database.read { db in try ProgressConflictRecord.fetchOne(db, key: id) }
  }

  public func fetchConflictAsync(id: Int64) async throws -> ProgressConflictRecord? {
    try await database.readAsync { db in try ProgressConflictRecord.fetchOne(db, key: id) }
  }

  /// Keep-local: re-enqueues whatever the local `MediaProgressRecord` currently holds as a fresh
  /// ordinary `progress`-kind outbox operation (explicitly authorising local to win), then clears
  /// the conflict, in one transaction so the conflict is never cleared without the local value
  /// being queued. A missing local row (not expected) still clears the conflict rather than
  /// leaving it unresolvable.
  public func resolveConflictKeepingLocal(conflictId: Int64, entityKey: String) throws {
    try database.write { db in
      try Self.resolveConflictKeepingLocal(db, conflictId: conflictId, entityKey: entityKey)
    }
  }

  public func resolveConflictKeepingLocalAsync(
    conflictId: Int64, entityKey: String
  ) async throws {
    try await database.writeAsync { db in
      try Self.resolveConflictKeepingLocal(db, conflictId: conflictId, entityKey: entityKey)
    }
  }

  /// Take-server: applies the conflict's already-recorded server observation through the
  /// composite pull write, then clears the conflict, in one transaction. The ebook position is
  /// applied only when the conflict recorded a server ebook value.
  public func resolveConflictTakingServer(conflictId: Int64) throws {
    try database.write { db in
      try Self.resolveConflictTakingServer(db, conflictId: conflictId)
    }
  }

  public func resolveConflictTakingServerAsync(conflictId: Int64) async throws {
    try await database.writeAsync { db in
      try Self.resolveConflictTakingServer(db, conflictId: conflictId)
    }
  }

  private static func fetchOpenConflicts(
    _ db: Database, accountId: Int64
  ) throws -> [ProgressConflictRecord] {
    try ProgressConflictRecord.filter(Column("accountId") == accountId).fetchAll(db)
  }

  private static func resolveConflictKeepingLocal(
    _ db: Database, conflictId: Int64, entityKey: String
  ) throws {
    guard let conflict = try ProgressConflictRecord.fetchOne(db, key: conflictId) else {
      throw MediaProgressDAOError.conflictNotFound(conflictId)
    }
    let local =
      try Self.fetchProgress(
        db, accountId: conflict.accountId, identity: Self.identity(for: conflict))
    _ = try conflict.delete(db)
    guard let local else { return }

    var operation = OutboxOperationRecord(
      accountId: conflict.accountId,
      clientOperationId: UUID().uuidString,
      entityKey: entityKey,
      podcastEpisodeId: conflict.podcastEpisodeId,
      operationKind: OutboxOperationKind.progress.rawValue,
      coalescingKey: "resolution:progressConflict:\(conflictId)",
      payloadVersion: 1,
      localSequence: local.localSequence + 1,
      payloadCurrentTime: local.currentTime,
      payloadIsFinished: local.isFinished,
      payloadAccumulatedDeltaSeconds: 0)
    try OutboxStore.insertRespectingItemQuarantine(db, record: &operation)
  }

  private static func resolveConflictTakingServer(
    _ db: Database, conflictId: Int64
  ) throws {
    guard let conflict = try ProgressConflictRecord.fetchOne(db, key: conflictId) else {
      throw MediaProgressDAOError.conflictNotFound(conflictId)
    }
    _ = try Self.applyServerCompositeResolution(
      db,
      accountId: conflict.accountId,
      identity: Self.identity(for: conflict),
      currentTime: conflict.serverCurrentTime,
      isFinished: conflict.serverIsFinished,
      ebookProgress: conflict.serverEbookProgress,
      ebookLocation: conflict.serverEbookLocation,
      hideFromContinueListening: false,
      serverUpdatedAt: conflict.serverUpdatedAt,
      resolution: .init(
        audioPosition: .applyServer,
        ebookPosition: conflict.serverEbookProgress == nil ? .keepLocal : .applyServer,
        sharedFinish: .applyServer,
        continueListeningVisibility: .keepLocal))
    // The composite write already swept this identity's conflict; the delete stays explicit so the
    // resolution never depends on that side effect.
    _ = try conflict.delete(db)
  }

  private static func identity(for conflict: ProgressConflictRecord) -> MediaProgressIdentity {
    if let podcastEpisodeId = conflict.podcastEpisodeId {
      return .episode(itemId: conflict.itemId, podcastEpisodeId: podcastEpisodeId)
    }
    return .item(itemId: conflict.itemId)
  }
}
