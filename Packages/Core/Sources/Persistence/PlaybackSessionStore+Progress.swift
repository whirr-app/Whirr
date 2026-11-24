import Foundation
import GRDB

extension PlaybackSessionStore {
  // MARK: - Progress transaction

  /// Atomically applies `tick` to the item/episode's `MediaProgress` row, this session's
  /// position/delta/last-local-sequence, and a `sessionSync` outbox row, coalesced into an
  /// existing unsent row for the same session/segment or created fresh. A captured sequence that
  /// predates the current `MediaProgress` row is rejected before any write.
  @discardableResult
  public func recordTick(sessionId: Int64, tick: PlaybackTick) throws -> PlaybackSessionRecord {
    try recordTick(sessionId: sessionId, tick: tick, advancingSequence: false)
  }

  /// Coordinator fast path: chooses the next sequence from the session and progress rows inside
  /// the same transaction that persists the tick. This removes the per-tick progress pre-read
  /// while retaining monotonic ordering against a concurrent pull or recovered write.
  @discardableResult
  public func recordNextTick(sessionId: Int64, tick: PlaybackTick) throws -> PlaybackSessionRecord {
    try recordTick(sessionId: sessionId, tick: tick, advancingSequence: true)
  }

  private func recordTick(
    sessionId: Int64, tick: PlaybackTick, advancingSequence: Bool
  ) throws -> PlaybackSessionRecord {
    try database.write { db in
      guard var session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) else {
        throw PlaybackSessionStoreError.sessionNotFound(sessionId)
      }

      let existingProgress = try Self.fetchProgress(db, session: session)
      var acceptedTick = tick
      if advancingSequence {
        acceptedTick.localSequence =
          max(session.lastLocalSequence, existingProgress?.localSequence ?? 0) + 1
      } else if let existingProgress, acceptedTick.localSequence < existingProgress.localSequence {
        throw PlaybackSessionStoreError.staleLocalSequence(
          captured: acceptedTick.localSequence, current: existingProgress.localSequence)
      }

      var progress =
        existingProgress
        ?? MediaProgressRecord(
          accountId: session.accountId,
          itemId: session.itemId,
          podcastEpisodeId: session.podcastEpisodeId,
          currentTime: acceptedTick.globalPosition,
          isFinished: acceptedTick.isFinished,
          localSequence: acceptedTick.localSequence,
          origin: .local,
          originKey: acceptedTick.originKey)
      Self.apply(acceptedTick, to: &progress)
      try progress.save(db)

      session.globalPosition = acceptedTick.globalPosition
      session.listenedDeltaSeconds += acceptedTick.deltaSecondsSinceLastTick
      session.lastLocalSequence = acceptedTick.localSequence
      session.updatedAt = acceptedTick.now
      try session.update(db)

      _ = try outbox.enqueueSessionSync(
        in: db,
        accountId: session.accountId,
        playbackSessionId: sessionId,
        entityKey: Self.entityKey(clientSessionId: session.clientSessionId),
        coalescingKey: Self.coalescingKey(
          clientSessionId: session.clientSessionId, segmentKey: acceptedTick.segmentKey),
        localSequence: acceptedTick.localSequence,
        payload: OutboxSessionPayload(
          currentTime: acceptedTick.globalPosition,
          accumulatedDeltaSeconds: acceptedTick.deltaSecondsSinceLastTick,
          durationSeconds: session.duration),
        clientOperationId: UUID().uuidString)

      if existingProgress?.isFinished != true, acceptedTick.isFinished {
        // The item/episode columns already scope coalescing to this identity; the distinct prefix
        // keeps this assertion separate from every ordinary progress update for that identity.
        _ = try OutboxStore.enqueueProgress(
          db,
          accountId: session.accountId,
          entityKey: try Self.serverItemID(db, session: session),
          podcastEpisodeId: session.podcastEpisodeId,
          coalescingKey: "playback-finished:\(acceptedTick.segmentKey)",
          localSequence: acceptedTick.localSequence,
          payload: OutboxProgressPayload(
            currentTime: acceptedTick.globalPosition, isFinished: true, accumulatedDeltaSeconds: 0))
      }
      return session
    }
  }

  /// Atomically freezes the final unsent delta plus `closePending` on the session and enqueues a
  /// fresh `sessionClose` outbox row, never coalesced with a prior `sessionSync` row, before any
  /// network attempt is possible.
  @discardableResult
  public func close(sessionId: Int64, tick: PlaybackSessionClose) throws -> PlaybackSessionRecord {
    let snapshot = try database.read { db in try Self.fetchClosableSession(db, sessionId: sessionId) }
    let clientOperationId = UUID().uuidString
    try database.write { db in
      try Self.closeSession(
        db, snapshot: snapshot, sessionId: sessionId, tick: tick,
        clientOperationId: clientOperationId)
    }

    guard let result = try database.read({ db in try PlaybackSessionRecord.fetchOne(db, key: sessionId) })
    else {
      throw PlaybackSessionStoreError.sessionNotFound(sessionId)
    }
    return result
  }

  @discardableResult
  public func closeAsync(
    sessionId: Int64, tick: PlaybackSessionClose
  ) async throws -> PlaybackSessionRecord {
    let snapshot = try await database.readAsync { db in
      try Self.fetchClosableSession(db, sessionId: sessionId)
    }
    let clientOperationId = UUID().uuidString
    try await database.writeAsync { db in
      try Self.closeSession(
        db, snapshot: snapshot, sessionId: sessionId, tick: tick,
        clientOperationId: clientOperationId)
    }

    guard
      let result = try await database.readAsync({ db in try PlaybackSessionRecord.fetchOne(db, key: sessionId) })
    else {
      throw PlaybackSessionStoreError.sessionNotFound(sessionId)
    }
    return result
  }

  /// The local-session analogue of `recordTick`: atomically applies `tick` to `MediaProgress` and
  /// this session's position/delta/last-local-sequence. Never enqueues a session row (rule 10:
  /// listening time is reported only by the `local-all` batch enqueued at close) but mirrors
  /// position through the ordinary progress path (`enqueueLocalProgressMirror`). Duplicates
  /// `recordTick`'s body to keep the rule-10 guarantee structurally obvious.
  @discardableResult
  public func recordLocalTick(sessionId: Int64, tick: PlaybackTick) throws -> PlaybackSessionRecord {
    try database.write { db in
      guard var session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) else {
        throw PlaybackSessionStoreError.sessionNotFound(sessionId)
      }

      let existingProgress = try Self.fetchProgress(db, session: session)
      if let existingProgress, tick.localSequence < existingProgress.localSequence {
        throw PlaybackSessionStoreError.staleLocalSequence(
          captured: tick.localSequence, current: existingProgress.localSequence)
      }

      var progress =
        existingProgress
        ?? MediaProgressRecord(
          accountId: session.accountId,
          itemId: session.itemId,
          podcastEpisodeId: session.podcastEpisodeId,
          currentTime: tick.globalPosition,
          isFinished: tick.isFinished,
          localSequence: tick.localSequence,
          origin: .local,
          originKey: tick.originKey)
      Self.apply(tick, to: &progress)
      try progress.save(db)

      session.globalPosition = tick.globalPosition
      session.listenedDeltaSeconds += tick.deltaSecondsSinceLastTick
      session.lastLocalSequence = tick.localSequence
      session.updatedAt = tick.now
      try session.update(db)

      try Self.enqueueLocalProgressMirror(
        db, session: session, currentTime: tick.globalPosition, localSequence: tick.localSequence)
      if existingProgress?.isFinished != true, tick.isFinished {
        try Self.enqueueLocalFinishedAssertion(
          db, session: session, currentTime: tick.globalPosition, localSequence: tick.localSequence,
          segmentKey: tick.segmentKey)
      }
      return session
    }
  }

  /// Rule 11a: a downloaded item plays as a local session even online, and rule 10's `local-all`
  /// upload happens only at close. Without this mirror the server learns nothing during a listen,
  /// and an episode played to its end never asserts `isFinished` (which `/sync`, `/close` and
  /// `local-all` cannot carry). One coalescing key per identity overwrites an unsent mirror. The
  /// flag is `nil` so the PATCH omits `isFinished` and cannot un-finish a row finished elsewhere.
  private static func enqueueLocalProgressMirror(
    _ db: Database, session: PlaybackSessionRecord, currentTime: Double, localSequence: Int64
  ) throws {
    _ = try OutboxStore.enqueueProgress(
      db,
      accountId: session.accountId,
      entityKey: try serverItemID(db, session: session),
      podcastEpisodeId: session.podcastEpisodeId,
      coalescingKey: OutboxStore.localSessionProgressCoalescingKey,
      localSequence: localSequence,
      payload: OutboxProgressPayload(
        currentTime: currentTime, isFinished: nil, accumulatedDeltaSeconds: 0))
  }

  /// The local-session twin of `recordTick`'s finished branch: the distinct segment-keyed prefix
  /// keeps the assertion out of the position mirror's coalescing group, so a later position never
  /// overwrites (or repeats) it.
  private static func enqueueLocalFinishedAssertion(
    _ db: Database, session: PlaybackSessionRecord, currentTime: Double, localSequence: Int64,
    segmentKey: String
  ) throws {
    _ = try OutboxStore.enqueueProgress(
      db,
      accountId: session.accountId,
      entityKey: try serverItemID(db, session: session),
      podcastEpisodeId: session.podcastEpisodeId,
      coalescingKey: "\(OutboxStore.playbackFinishedCoalescingKeyPrefix)\(segmentKey)",
      localSequence: localSequence,
      payload: OutboxProgressPayload(
        currentTime: currentTime, isFinished: true, accumulatedDeltaSeconds: 0))
  }

  /// The sessionless safety net: applies `tick` to `MediaProgress` alone, for audio still playing
  /// with no session to attribute it to (the server discarded it and the replacement `/play` was
  /// unreachable, usually the same connectivity failure). `persistTick`'s "no active session"
  /// guard would otherwise drop the tick and freeze the resume position where the session died.
  ///
  /// Position only: rule 6 makes the session flow the sole channel for listening stats and a
  /// session cannot be reconstructed afterwards. The one queued row is the ordinary `progress`
  /// PATCH `markSessionGone` uses (rule 11: never an `id` field); a single coalescing key per
  /// identity collapses a run of ticks to one pending row.
  @discardableResult
  public func recordSessionlessTick(
    accountId: Int64, itemId: Int64, podcastEpisodeId: Int64?, serverItemId: String, tick: PlaybackTick
  ) throws -> MediaProgressRecord {
    try database.write { db in
      let existingProgress = try Self.fetchProgress(
        db, accountId: accountId, itemId: itemId, podcastEpisodeId: podcastEpisodeId)
      var acceptedTick = tick
      acceptedTick.localSequence = (existingProgress?.localSequence ?? 0) + 1

      var progress =
        existingProgress
        ?? MediaProgressRecord(
          accountId: accountId,
          itemId: itemId,
          podcastEpisodeId: podcastEpisodeId,
          currentTime: acceptedTick.globalPosition,
          isFinished: acceptedTick.isFinished,
          localSequence: acceptedTick.localSequence,
          origin: .local,
          originKey: acceptedTick.originKey)
      Self.apply(acceptedTick, to: &progress)
      try progress.save(db)

      _ = try OutboxStore.enqueueProgress(
        db,
        accountId: accountId,
        entityKey: serverItemId,
        podcastEpisodeId: podcastEpisodeId,
        coalescingKey: "sessionless-progress",
        localSequence: acceptedTick.localSequence,
        payload: OutboxProgressPayload(
          currentTime: acceptedTick.globalPosition, isFinished: acceptedTick.isFinished,
          accumulatedDeltaSeconds: 0))

      return progress
    }
  }

  /// Freezes a local session's final position/delta (as `close`; with no periodic send to reset
  /// against, `listenedDeltaSeconds` holds the whole-session total and this adds the last
  /// increment), moves the row to `.closedAwaitingUpload` (freeing the account's local-session
  /// slot) and enqueues one `localSessionUpload` outbox row, in one transaction. Never touches the
  /// network: rule 10's `local-all` upload is driven off that row.
  @discardableResult
  public func closeLocalSession(sessionId: Int64, tick: PlaybackSessionClose) throws -> PlaybackSessionRecord {
    let snapshot = try database.read { db in try PlaybackSessionRecord.fetchOne(db, key: sessionId) }
    guard let snapshot else {
      throw PlaybackSessionStoreError.sessionNotFound(sessionId)
    }
    let clientOperationId = UUID().uuidString
    try database.write { db in
      try Self.closeLocalSession(
        db, snapshot: snapshot, sessionId: sessionId, tick: tick,
        clientOperationId: clientOperationId)
    }

    guard let result = try database.read({ db in try PlaybackSessionRecord.fetchOne(db, key: sessionId) })
    else {
      throw PlaybackSessionStoreError.sessionNotFound(sessionId)
    }
    return result
  }

  @discardableResult
  public func closeLocalSessionAsync(
    sessionId: Int64, tick: PlaybackSessionClose
  ) async throws -> PlaybackSessionRecord {
    let snapshot = try await database.readAsync { db in
      try PlaybackSessionRecord.fetchOne(db, key: sessionId)
    }
    guard let snapshot else {
      throw PlaybackSessionStoreError.sessionNotFound(sessionId)
    }
    let clientOperationId = UUID().uuidString
    try await database.writeAsync { db in
      try Self.closeLocalSession(
        db, snapshot: snapshot, sessionId: sessionId, tick: tick,
        clientOperationId: clientOperationId)
    }

    guard
      let result = try await database.readAsync({ db in try PlaybackSessionRecord.fetchOne(db, key: sessionId) })
    else {
      throw PlaybackSessionStoreError.sessionNotFound(sessionId)
    }
    return result
  }

  private static func fetchClosableSession(
    _ db: Database, sessionId: Int64
  ) throws -> PlaybackSessionRecord {
    guard let snapshot = try PlaybackSessionRecord.fetchOne(db, key: sessionId) else {
      throw PlaybackSessionStoreError.sessionNotFound(sessionId)
    }
    if snapshot.closePending {
      throw PlaybackSessionStoreError.alreadyClosePending(sessionId)
    }
    return snapshot
  }

  private static func closeSession(
    _ db: Database,
    snapshot: PlaybackSessionRecord,
    sessionId: Int64,
    tick: PlaybackSessionClose,
    clientOperationId: String
  ) throws {
    guard var session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) else {
      throw PlaybackSessionStoreError.sessionNotFound(sessionId)
    }
    session.globalPosition = tick.globalPosition
    session.listenedDeltaSeconds += tick.deltaSecondsSinceLastSend
    session.closePending = true
    session.updatedAt = tick.now
    try session.update(db)

    var operation = OutboxOperationRecord(
      accountId: snapshot.accountId,
      clientOperationId: clientOperationId,
      entityKey: Self.entityKey(clientSessionId: snapshot.clientSessionId),
      podcastEpisodeId: nil,
      operationKind: OutboxOperationKind.sessionClose.rawValue,
      coalescingKey: Self.coalescingKey(
        clientSessionId: snapshot.clientSessionId, segmentKey: "close"),
      payloadVersion: 1,
      localSequence: tick.localSequence,
      payloadCurrentTime: tick.globalPosition,
      payloadAccumulatedDeltaSeconds: tick.deltaSecondsSinceLastSend,
      payloadDurationSeconds: snapshot.duration,
      playbackSessionId: sessionId)
    try OutboxStore.insertRespectingItemQuarantine(db, record: &operation)
  }

  private static func closeLocalSession(
    _ db: Database,
    snapshot: PlaybackSessionRecord,
    sessionId: Int64,
    tick: PlaybackSessionClose,
    clientOperationId: String
  ) throws {
    guard var session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) else {
      throw PlaybackSessionStoreError.sessionNotFound(sessionId)
    }
    session.globalPosition = tick.globalPosition
    session.listenedDeltaSeconds += tick.deltaSecondsSinceLastSend
    session.state = .closedAwaitingUpload
    session.updatedAt = tick.now
    try session.update(db)

    var operation = OutboxOperationRecord(
      accountId: snapshot.accountId,
      clientOperationId: clientOperationId,
      entityKey: Self.entityKey(clientSessionId: snapshot.clientSessionId),
      podcastEpisodeId: nil,
      operationKind: OutboxOperationKind.localSessionUpload.rawValue,
      coalescingKey: Self.coalescingKey(
        clientSessionId: snapshot.clientSessionId, segmentKey: "local-upload"),
      payloadVersion: 1,
      localSequence: tick.localSequence,
      payloadCurrentTime: tick.globalPosition,
      payloadAccumulatedDeltaSeconds: snapshot.listenedDeltaSeconds + tick.deltaSecondsSinceLastSend,
      payloadDurationSeconds: snapshot.duration,
      playbackSessionId: sessionId)
    try OutboxStore.insertRespectingItemQuarantine(db, record: &operation)

    // The close position is up to a whole tick interval ahead of the last mirrored one, and the
    // `local-all` upload it sits beside may be held for skew confirmation or retried for a long
    // time (rule 11a).
    try enqueueLocalProgressMirror(
      db, session: session, currentTime: tick.globalPosition, localSequence: tick.localSequence)
  }

  private static func entityKey(clientSessionId: String) -> String {
    "session:\(clientSessionId)"
  }

  private static func coalescingKey(clientSessionId: String, segmentKey: String) -> String {
    "session:\(clientSessionId):\(segmentKey)"
  }

  private static func apply(_ tick: PlaybackTick, to progress: inout MediaProgressRecord) {
    progress.currentTime = tick.globalPosition
    progress.isFinished = tick.isFinished
    progress.hideFromContinueListening = false
    progress.localSequence = tick.localSequence
    progress.lastActivityAt = tick.now
    progress.origin = .local
    progress.originKey = tick.originKey
  }

  private static func serverItemID(
    _ db: Database, session: PlaybackSessionRecord
  ) throws -> String {
    guard let item = try ItemRecord.fetchOne(db, key: session.itemId) else {
      // The item FK cascades the session when an item is physically deleted, so this is a
      // corrupted store rather than an ordinary miss. Throwing before the enqueue keeps the whole
      // tick uncommitted rather than half-applied.
      throw PlaybackSessionStoreError.itemNotFound(session.itemId)
    }
    return item.serverItemId
  }

  /// The identity-addressed form of `fetchProgress(_:session:)`, for the one path that has no
  /// session to address progress through.
  private static func fetchProgress(
    _ db: Database, accountId: Int64, itemId: Int64, podcastEpisodeId: Int64?
  ) throws -> MediaProgressRecord? {
    if let podcastEpisodeId {
      return
        try MediaProgressRecord
        .filter(Column("accountId") == accountId)
        .filter(Column("podcastEpisodeId") == podcastEpisodeId)
        .fetchOne(db)
    }
    return
      try MediaProgressRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("itemId") == itemId)
      .filter(Column("podcastEpisodeId") == nil)
      .fetchOne(db)
  }
}
