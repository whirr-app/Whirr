import Foundation
import GRDB

extension PlaybackSessionStore {
  // MARK: - Session lifecycle

  /// Starts a new online session for `accountId`. A `clientSessionId` collision quarantines the
  /// existing row (its own write, committed before this throws) rather than overwriting it or
  /// crashing on the unique-constraint violation; a second `active` session for the same account
  /// is refused by the schema's partial unique index (SchemaV1.swift) and reported as a typed
  /// error instead of a raw `DatabaseError`.
  @discardableResult
  public func startSession(
    accountId: Int64,
    clientSessionId: String,
    itemId: Int64,
    podcastEpisodeId: Int64? = nil,
    duration: Double? = nil,
    startedAt: Date,
    isOffline: Bool = false
  ) throws -> PlaybackSessionRecord {
    let hadDuplicate = try database.write { db -> Bool in
      try Self.quarantineDuplicateClientSession(db, clientSessionId: clientSessionId)
    }
    if hadDuplicate {
      throw PlaybackSessionStoreError.duplicateClientSessionId(clientSessionId)
    }

    return try database.write { db in
      try Self.insertSession(
        db,
        accountId: accountId,
        clientSessionId: clientSessionId,
        itemId: itemId,
        podcastEpisodeId: podcastEpisodeId,
        duration: duration,
        startedAt: startedAt,
        isOffline: isOffline)
    }
  }

  @discardableResult
  public func startSessionAsync(
    accountId: Int64,
    clientSessionId: String,
    itemId: Int64,
    podcastEpisodeId: Int64? = nil,
    duration: Double? = nil,
    startedAt: Date,
    isOffline: Bool = false
  ) async throws -> PlaybackSessionRecord {
    let hadDuplicate = try await database.writeAsync { db -> Bool in
      try Self.quarantineDuplicateClientSession(db, clientSessionId: clientSessionId)
    }
    if hadDuplicate {
      throw PlaybackSessionStoreError.duplicateClientSessionId(clientSessionId)
    }

    return try await database.writeAsync { db in
      try Self.insertSession(
        db,
        accountId: accountId,
        clientSessionId: clientSessionId,
        itemId: itemId,
        podcastEpisodeId: podcastEpisodeId,
        duration: duration,
        startedAt: startedAt,
        isOffline: isOffline)
    }
  }

  /// The account/device's single locally-active online session, if any. Used to find the old
  /// session on relaunch before opening a replacement.
  public func fetchActiveSession(accountId: Int64) throws -> PlaybackSessionRecord? {
    try database.read { db in try Self.fetchActiveSession(db, accountId: accountId) }
  }

  public func fetchActiveSessionAsync(accountId: Int64) async throws -> PlaybackSessionRecord? {
    try await database.readAsync { db in try Self.fetchActiveSession(db, accountId: accountId) }
  }

  /// True while `itemId`'s active local session has an unacknowledged `sessionSync`/`sessionClose`
  /// outbox row. A live session's ticks land under its own entity key
  /// (`session:<clientSessionId>`), so `MediaProgressDAO.hasUnacknowledgedLocalOperation`'s
  /// item-keyed check cannot see them. SyncEngine's library-pull merge (`progressOutcome`) adds
  /// this check, so a pull landing mid-session (even between a tick's persistence and its
  /// acknowledgement) is protected: `ProgressMergePolicy.resolve` rejects the incoming observation
  /// while true, then reverts to its timestamp/tie-break comparison.
  public func hasUnacknowledgedSessionWrite(accountId: Int64, itemId: Int64) throws -> Bool {
    try database.read { db in
      guard
        let session =
          try PlaybackSessionRecord
          .filter(Column("accountId") == accountId)
          .filter(Column("itemId") == itemId)
          .filter(Column("isOffline") == false)
          .filter(Column("state") == PlaybackSessionState.active.rawValue)
          .fetchOne(db),
        let sessionId = session.id
      else { return false }

      let states: [String] = [
        OutboxOperationState.pending.rawValue,
        OutboxOperationState.sending.rawValue,
        OutboxOperationState.retryWaiting.rawValue,
        OutboxOperationState.needsResolution.rawValue,
      ]
      return
        try OutboxOperationRecord
        .filter(Column("playbackSessionId") == sessionId)
        .filter(states.contains(Column("state")))
        .fetchCount(db) > 0
    }
  }

  public func hasUnacknowledgedSessionWriteAsync(accountId: Int64, itemId: Int64) async throws -> Bool {
    try await database.readAsync { db in
      guard
        let session =
          try PlaybackSessionRecord
          .filter(Column("accountId") == accountId)
          .filter(Column("itemId") == itemId)
          .filter(Column("isOffline") == false)
          .filter(Column("state") == PlaybackSessionState.active.rawValue)
          .fetchOne(db),
        let sessionId = session.id
      else { return false }

      let states: [String] = [
        OutboxOperationState.pending.rawValue,
        OutboxOperationState.sending.rawValue,
        OutboxOperationState.retryWaiting.rawValue,
        OutboxOperationState.needsResolution.rawValue,
      ]
      return
        try OutboxOperationRecord
        .filter(Column("playbackSessionId") == sessionId)
        .filter(states.contains(Column("state")))
        .fetchCount(db) > 0
    }
  }

  /// The account/device's single locally-active offline session, if any. The local-session
  /// analogue of `fetchActiveSession`, used to resume a still-open local session across a relaunch
  /// (nothing server-side to reconcile, so the row's presence is the recovery) and to find the
  /// local session a switch to a different item must freeze and close first.
  public func fetchActiveOfflineSession(accountId: Int64) throws -> PlaybackSessionRecord? {
    try database.read { db in try Self.fetchActiveOfflineSession(db, accountId: accountId) }
  }

  public func fetchActiveOfflineSessionAsync(accountId: Int64) async throws -> PlaybackSessionRecord? {
    try await database.readAsync { db in try Self.fetchActiveOfflineSession(db, accountId: accountId) }
  }

  /// True while `itemId` has a currently-active local (offline) session for this account.
  /// A local session's ticks never create an outbox row (rule 10), so
  /// `hasUnacknowledgedSessionWrite` cannot see it. This is the equivalent guard for offline
  /// sessions: the server has not observed this position while the session is open, so a
  /// foreground library pull must not overwrite it.
  public func hasActiveOfflineSession(accountId: Int64, itemId: Int64) throws -> Bool {
    try database.read { db in
      try PlaybackSessionRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("itemId") == itemId)
        .filter(Column("isOffline") == true)
        .filter(Column("state") == PlaybackSessionState.active.rawValue)
        .fetchCount(db) > 0
    }
  }

  public func hasActiveOfflineSessionAsync(accountId: Int64, itemId: Int64) async throws -> Bool {
    try await database.readAsync { db in
      try PlaybackSessionRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("itemId") == itemId)
        .filter(Column("isOffline") == true)
        .filter(Column("state") == PlaybackSessionState.active.rawValue)
        .fetchCount(db) > 0
    }
  }

  public func fetchSession(id: Int64) throws -> PlaybackSessionRecord? {
    try database.read { db in try PlaybackSessionRecord.fetchOne(db, key: id) }
  }

  public func fetchSessionAsync(id: Int64) async throws -> PlaybackSessionRecord? {
    try await database.readAsync { db in try PlaybackSessionRecord.fetchOne(db, key: id) }
  }

  public func fetchSession(clientSessionId: String) throws -> PlaybackSessionRecord? {
    try database.read { db in
      try PlaybackSessionRecord.filter(Column("clientSessionId") == clientSessionId).fetchOne(db)
    }
  }

  /// Persist-id-first seam: records the server's session id the moment `/play` returns `200`, as
  /// its own write ahead of any track mapping or preparation. No outbox row, since this only
  /// corrects the row `startSession` inserted and needs no server acknowledgement of its own.
  @discardableResult
  public func setServerSessionId(sessionId: Int64, serverSessionId: String) throws -> PlaybackSessionRecord {
    try database.write { db in
      try Self.setServerSessionId(db, sessionId: sessionId, serverSessionId: serverSessionId)
    }
  }

  @discardableResult
  public func setServerSessionIdAsync(
    sessionId: Int64, serverSessionId: String
  ) async throws -> PlaybackSessionRecord {
    try await database.writeAsync { db in
      try Self.setServerSessionId(db, sessionId: sessionId, serverSessionId: serverSessionId)
    }
  }

  /// Freezes where this session began on the book's global timeline. A separate write after the
  /// insert, as with `setServerSessionId`: both start paths learn the resume position only after
  /// the row exists (online merges `/play`'s `currentTime` against local progress, local reads
  /// local progress), and neither may delay the persist-id-first insert. Written once at open
  /// time and never ticked.
  @discardableResult
  public func setStartPosition(sessionId: Int64, startPosition: Double) throws -> PlaybackSessionRecord {
    try database.write { db in
      try Self.setStartPosition(db, sessionId: sessionId, startPosition: startPosition)
    }
  }

  @discardableResult
  public func setStartPositionAsync(
    sessionId: Int64, startPosition: Double
  ) async throws -> PlaybackSessionRecord {
    try await database.writeAsync { db in
      try Self.setStartPosition(db, sessionId: sessionId, startPosition: startPosition)
    }
  }

  private static func quarantineDuplicateClientSession(
    _ db: Database, clientSessionId: String
  ) throws -> Bool {
    guard
      var existing =
        try PlaybackSessionRecord
        .filter(Column("clientSessionId") == clientSessionId)
        .fetchOne(db)
    else {
      return false
    }
    existing.state = .quarantined
    try existing.update(db)
    return true
  }

  private static func insertSession(
    _ db: Database,
    accountId: Int64,
    clientSessionId: String,
    itemId: Int64,
    podcastEpisodeId: Int64?,
    duration: Double?,
    startedAt: Date,
    isOffline: Bool
  ) throws -> PlaybackSessionRecord {
    var record = PlaybackSessionRecord(
      accountId: accountId,
      clientSessionId: clientSessionId,
      itemId: itemId,
      podcastEpisodeId: podcastEpisodeId,
      startedAt: startedAt,
      updatedAt: startedAt,
      isOffline: isOffline,
      duration: duration)
    do {
      try record.insert(db)
    } catch let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT {
      throw PlaybackSessionStoreError.activeSessionAlreadyExists(accountId: accountId)
    }
    return record
  }

  private static func fetchActiveSession(
    _ db: Database, accountId: Int64
  ) throws -> PlaybackSessionRecord? {
    try PlaybackSessionRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("isOffline") == false)
      .filter(Column("state") == PlaybackSessionState.active.rawValue)
      .fetchOne(db)
  }

  private static func fetchActiveOfflineSession(
    _ db: Database, accountId: Int64
  ) throws -> PlaybackSessionRecord? {
    try PlaybackSessionRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("isOffline") == true)
      .filter(Column("state") == PlaybackSessionState.active.rawValue)
      .fetchOne(db)
  }

  private static func setServerSessionId(
    _ db: Database, sessionId: Int64, serverSessionId: String
  ) throws -> PlaybackSessionRecord {
    guard var session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) else {
      throw PlaybackSessionStoreError.sessionNotFound(sessionId)
    }
    session.serverSessionId = serverSessionId
    try session.update(db)
    return session
  }

  private static func setStartPosition(
    _ db: Database, sessionId: Int64, startPosition: Double
  ) throws -> PlaybackSessionRecord {
    guard var session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) else {
      throw PlaybackSessionStoreError.sessionNotFound(sessionId)
    }
    session.startPosition = startPosition
    try session.update(db)
    return session
  }

}
