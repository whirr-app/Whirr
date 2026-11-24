import Foundation
import GRDB

extension PlaybackSessionStore {
  // MARK: - Session-gone recovery

  /// Resolves a session's item to its server item id, for close-ambiguity reconciliation that
  /// compares against server-side progress without reaching into `ItemRecord`.
  public func serverItemID(forSessionId sessionId: Int64) throws -> String? {
    try database.read { db in
      guard let session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) else { return nil }
      return try ItemRecord.fetchOne(db, key: session.itemId)?.serverItemId
    }
  }

  /// One transaction (API-CONVENTIONS.md rule 11): marks the session `gone` (freeing the account's
  /// active-session slot, as `quarantined` does), removes all its `sessionSync`/`sessionClose`
  /// outbox rows whatever their state, and preserves its last position and finished state through
  /// an ordinary `progress`-kind outbox row (never an `id` field). No other session's rows are
  /// touched. The unacknowledged listening delta is zeroed, not carried into the preserved
  /// position or a replacement session: only the session flow records listening stats
  /// (API-CONVENTIONS rule 6) and nothing can acknowledge it. Returns `nil` (a no-op) if the
  /// session no longer exists or its item was never pulled locally.
  @discardableResult
  public func markSessionGone(sessionId: Int64, now: Date) throws -> PlaybackSessionGoneOutcome? {
    try database.write { db in
      guard var session = try PlaybackSessionRecord.fetchOne(db, key: sessionId) else { return nil }
      guard let itemRecord = try ItemRecord.fetchOne(db, key: session.itemId) else { return nil }

      var episodeServerId: String?
      if let episodeRowId = session.podcastEpisodeId {
        episodeServerId = try PodcastEpisodeRecord.fetchOne(db, key: episodeRowId)?.serverEpisodeId
      }
      let isFinished = try Self.fetchProgress(db, session: session)?.isFinished ?? false
      let lastPosition = session.globalPosition

      // Every row for this session (sessionSync and sessionClose, any state) and no other
      // session's (`progress`-kind rows never carry this FK).
      _ = try OutboxOperationRecord.filter(Column("playbackSessionId") == sessionId).deleteAll(db)

      // Preserve the last known position/finished-state through the ordinary one-shot path
      // (`OutboxDrainer`'s `progress`-kind sender never encodes an `id`, per rule 11). A dedicated
      // coalescing key stops this write merging into, and being superseded by, an unrelated
      // pending progress mutation for the same item.
      _ = try OutboxStore.enqueueProgress(
        db,
        accountId: session.accountId,
        entityKey: itemRecord.serverItemId,
        podcastEpisodeId: session.podcastEpisodeId,
        coalescingKey: "session-gone:\(session.clientSessionId)",
        localSequence: session.lastLocalSequence,
        payload: OutboxProgressPayload(
          currentTime: lastPosition, isFinished: isFinished, accumulatedDeltaSeconds: 0))

      session.state = .gone
      session.listenedDeltaSeconds = 0
      session.closePending = false
      session.updatedAt = now
      try session.update(db)

      return PlaybackSessionGoneOutcome(
        accountId: session.accountId, itemServerId: itemRecord.serverItemId, episodeServerId: episodeServerId)
    }
  }

}
