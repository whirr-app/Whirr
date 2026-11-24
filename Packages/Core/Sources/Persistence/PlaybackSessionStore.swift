import Foundation
import GRDB

/// Errors `PlaybackSessionStore` raises. Separates caller errors (missing rows) from the two
/// data-integrity guards: one locally-active online session per account/device, and never
/// silently reusing a `clientSessionId`.
public enum PlaybackSessionStoreError: Error, Equatable, Sendable {
  case sessionNotFound(Int64)
  /// `playbackSession.itemId` is a non-null foreign key with `ON DELETE CASCADE`, so this is an
  /// unreachable data-integrity failure rather than a normal playback outcome.
  case itemNotFound(Int64)
  /// A second online session was started for this account while another was still `active`.
  /// The caller must close or quarantine the existing session first.
  case activeSessionAlreadyExists(accountId: Int64)
  /// `clientSessionId` collided with an existing row. That row has already been moved to
  /// `PlaybackSessionState.quarantined` by the time this is thrown.
  case duplicateClientSessionId(String)
  /// A stale background player tick is rejected if its captured local sequence predates the
  /// current progress row.
  case staleLocalSequence(captured: Int64, current: Int64)
  /// `close` was called twice for the same session without an acknowledgement in between.
  case alreadyClosePending(Int64)
}

/// The result of `markSessionGone`: everything a caller needs to record a privacy-safe
/// diagnostic and, if playback is still active, request a zero-delta replacement session,
/// without reaching into `ItemRecord`/`PodcastEpisodeRecord` (Persistence internals).
/// Carries no position or delta forward. Those belong to the transaction alone (kept through
/// the one-shot progress path, discarded otherwise), never for a caller to log or reattribute.
public struct PlaybackSessionGoneOutcome: Sendable, Equatable {
  public let accountId: Int64
  public let itemServerId: String
  public let episodeServerId: String?

  public init(accountId: Int64, itemServerId: String, episodeServerId: String?) {
    self.accountId = accountId
    self.itemServerId = itemServerId
    self.episodeServerId = episodeServerId
  }
}

/// One accepted playback tick: a position/listening-time observation to apply atomically
/// to `MediaProgress`, the owning session, and its `sessionSync` outbox row.
public struct PlaybackTick: Sendable {
  /// Position on the book's global timeline.
  public var globalPosition: Double
  public var isFinished: Bool
  /// Listening time accrued since the last accepted tick for this session. Never inflated by
  /// rate or seeks.
  public var deltaSecondsSinceLastTick: Double
  /// This device's monotonic write ordering. Rejected if it predates the
  /// current `MediaProgress` row's own `localSequence`.
  public var localSequence: Int64
  /// The account's persisted client UUID, used as `MediaProgress.originKey` for local writes.
  public var originKey: String
  /// Identifies the current coalescing segment: ordinary ticks for the same
  /// segment share one key and merge into one outbox row; a seek, a finished/un-finished
  /// transition, or a close each start a new segment so they are never merged together.
  public var segmentKey: String
  public var now: Date

  public init(
    globalPosition: Double,
    isFinished: Bool,
    deltaSecondsSinceLastTick: Double,
    localSequence: Int64,
    originKey: String,
    segmentKey: String,
    now: Date
  ) {
    self.globalPosition = globalPosition
    self.isFinished = isFinished
    self.deltaSecondsSinceLastTick = deltaSecondsSinceLastTick
    self.localSequence = localSequence
    self.originKey = originKey
    self.segmentKey = segmentKey
    self.now = now
  }
}

/// The final observation closing a session: freezes the remaining unsent delta plus
/// `closePending` atomically, ahead of any network attempt.
public struct PlaybackSessionClose: Sendable {
  public var globalPosition: Double
  /// Listening time accrued since the last outbox row was created for this session, never the
  /// running session total, so acknowledging earlier `sessionSync` rows and this close row never
  /// double-counts.
  public var deltaSecondsSinceLastSend: Double
  public var localSequence: Int64
  public var now: Date

  public init(
    globalPosition: Double, deltaSecondsSinceLastSend: Double, localSequence: Int64, now: Date
  ) {
    self.globalPosition = globalPosition
    self.deltaSecondsSinceLastSend = deltaSecondsSinceLastSend
    self.localSequence = localSequence
    self.now = now
  }
}

/// DB-facing playback-session store: session lifecycle, the atomic
/// tick/close transactions, and their acknowledgement. It uses `OutboxStore` for shared lookup
/// and transition paths while keeping each store-owned transaction body available to both the
/// synchronous and asynchronous database-writer surfaces.
public struct PlaybackSessionStore: Sendable {
  let database: AppDatabase
  let outbox: OutboxStore

  public init(database: AppDatabase, outbox: OutboxStore) {
    self.database = database
    self.outbox = outbox
  }

  // MARK: - Helpers

  /// Item-level progress unless the session is for a podcast episode, mirroring
  /// `MediaProgressDAO`'s own item/episode partial-identity split.
  static func fetchProgress(_ db: Database, session: PlaybackSessionRecord) throws
    -> MediaProgressRecord?
  {
    if let episodeId = session.podcastEpisodeId {
      return
        try MediaProgressRecord
        .filter(Column("accountId") == session.accountId)
        .filter(Column("podcastEpisodeId") == episodeId)
        .fetchOne(db)
    }
    return
      try MediaProgressRecord
      .filter(Column("accountId") == session.accountId)
      .filter(Column("itemId") == session.itemId)
      .filter(Column("podcastEpisodeId") == nil)
      .fetchOne(db)
  }
}
