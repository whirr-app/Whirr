import Foundation
import GRDB

/// A playback session's local lifecycle state. `active` is the single current session for an
/// account/device. `quarantined` is the escape hatch for a `clientSessionId` collision.
///
/// `gone` marks a session the server no longer recognises (a `/sync` or `/close` `404`, classified
/// ahead of the generic permanent-error path). Both are excluded from every active-session
/// lookup, which frees the single active slot for a replacement. `gone` stays distinct because
/// its recovery (position preserved via the one-shot progress path, delta discarded) differs.
public enum PlaybackSessionState: String, Codable, Sendable, DatabaseValueConvertible {
  case active
  case quarantined
  case gone
  /// A completed local (offline) session, frozen and enqueued for its one `localSessionUpload`
  /// outbox row (API-CONVENTIONS rule 10) but not yet deleted, since nothing server-side has seen
  /// it. The row is removed once the `local-all` batch upload is acknowledged. Excluded from every
  /// active-session lookup (like `quarantined`/`gone`), which frees the account's single active
  /// offline session slot for a fresh local session.
  case closedAwaitingUpload
}

/// One playback session, online or offline. `clientSessionId` is the stable UUID used to
/// merge/quarantine duplicate offline sessions; `serverSessionId` is only present once the server
/// has acknowledged an online session.
///
/// `globalPosition`, `duration`, `state` and `lastLocalSequence` are persisted so book-timeline
/// position, the `/sync` duration, lifecycle state and stale-tick rejection survive a crash.
public struct PlaybackSessionRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "playbackSession"

  public var id: Int64?
  public var accountId: Int64
  public var clientSessionId: String
  public var serverSessionId: String?
  public var itemId: Int64
  public var podcastEpisodeId: Int64?
  public var startedAt: Date
  public var updatedAt: Date
  public var listenedDeltaSeconds: Double
  /// Cumulative seconds this client has confirmed the server accepted for this session. `/sync` is
  /// additive server-side and answers with no body, so this total is the only local reference a
  /// lost response can be reconciled against: compared with the session's own server-side
  /// `timeListening`, it says whether an ambiguous attempt landed or must be replayed.
  public var acknowledgedListenedSeconds: Double
  public var closePending: Bool
  public var isOffline: Bool
  /// Current position on the book's global timeline. Mirrored into `MediaProgress` but persisted
  /// here too because `/sync`'s payload is built from the session, never from a join back to
  /// `MediaProgress`.
  public var globalPosition: Double
  /// Where this session began on the book's global timeline, frozen at open time. Only a local
  /// (offline) session needs it: the `/api/session/local-all` upload is the whole object, so a
  /// missing `startTime` shows `00:00` in History. An online session's start is server-computed at
  /// `/play`. `nil` while unknown, never `0`, which would claim the start of the book.
  public var startPosition: Double?
  /// The item's known total duration at session-open time, for `/sync`'s optional `duration`
  /// field (API-CONVENTIONS.md). `nil` when unknown.
  public var duration: Double?
  public var state: PlaybackSessionState
  /// The local sequence last accepted for this session (rejects stale background player ticks),
  /// kept in step with the item/episode `MediaProgress` row's own `localSequence`.
  public var lastLocalSequence: Int64

  public init(
    id: Int64? = nil,
    accountId: Int64,
    clientSessionId: String,
    serverSessionId: String? = nil,
    itemId: Int64,
    podcastEpisodeId: Int64? = nil,
    startedAt: Date,
    updatedAt: Date,
    listenedDeltaSeconds: Double = 0,
    acknowledgedListenedSeconds: Double = 0,
    closePending: Bool = false,
    isOffline: Bool = false,
    globalPosition: Double = 0,
    duration: Double? = nil,
    startPosition: Double? = nil,
    state: PlaybackSessionState = .active,
    lastLocalSequence: Int64 = 0
  ) {
    self.id = id
    self.accountId = accountId
    self.clientSessionId = clientSessionId
    self.serverSessionId = serverSessionId
    self.itemId = itemId
    self.podcastEpisodeId = podcastEpisodeId
    self.startedAt = startedAt
    self.updatedAt = updatedAt
    self.listenedDeltaSeconds = listenedDeltaSeconds
    self.acknowledgedListenedSeconds = acknowledgedListenedSeconds
    self.closePending = closePending
    self.isOffline = isOffline
    self.globalPosition = globalPosition
    self.startPosition = startPosition
    self.duration = duration
    self.state = state
    self.lastLocalSequence = lastLocalSequence
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
