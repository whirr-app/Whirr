import Foundation
import GRDB

/// Outbox lifecycle states. Transition enforcement lives elsewhere; this schema only stores the
/// current state as a plain string-backed enum.
public enum OutboxOperationState: String, Codable, Sendable, DatabaseValueConvertible {
  case pending
  case sending
  case retryWaiting
  case needsResolution
  case deadLetter
}

/// One queued mutation awaiting upload. `clientOperationId` is the stable
/// UUID acknowledgements are matched against; `coalescingKey` groups unsent ordinary progress
/// updates that may be merged; `localSequence` orders drain within one entity.
public struct OutboxOperationRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "outboxOperation"

  public var id: Int64?
  public var accountId: Int64
  public var clientOperationId: String
  public var entityKey: String
  /// Local episode FK for ordinary progress identity. Session rows retain their identity through
  /// `playbackSessionId` and leave this nil.
  public var podcastEpisodeId: Int64?
  public var operationKind: String
  public var coalescingKey: String
  public var payloadVersion: Int
  public var localSequence: Int64
  public var attempts: Int
  public var nextAttemptAt: Date?
  public var state: OutboxOperationState
  // The versioned payload for `progress`-kind operations. Nullable because other operation kinds
  // define their own payload shape under a different `payloadVersion`/`operationKind` rather than
  // reusing these columns.
  public var payloadCurrentTime: Double?
  public var payloadIsFinished: Bool?
  public var payloadAccumulatedDeltaSeconds: Double?
  // Ebook position operations carry their own versioned wire fields (v21). They do not reuse the
  // audio `payloadCurrentTime`/`payloadIsFinished` columns, which would make them
  // indistinguishable from an audio patch at the drain boundary.
  public var payloadEbookProgress: Double?
  public var payloadEbookLocation: String?
  // `sessionSync`/`sessionClose` reuse `payloadCurrentTime`/`payloadAccumulatedDeltaSeconds` above
  // but add their own optional `/sync` duration field, plus an explicit FK to the
  // `playbackSession` row they belong to (never inferred from `entityKey`, a plain string).
  public var payloadDurationSeconds: Double?
  // Nullable field-only progress payload for Continue Listening visibility.
  public var payloadHideFromContinueListening: Bool?
  public var playbackSessionId: Int64?
  public var deadLetterReason: String?
  // v71: a `progressReset` operation's medium (`ProgressResetMedium`), its persisted send phase
  // (`ProgressResetPhase`), and the server's audio fraction captured before the delete. The
  // captured other-medium position reuses `payloadCurrentTime` (ebook reset) or
  // `payloadEbookProgress`/`payloadEbookLocation` (audio reset).
  public var payloadResetMedium: String?
  public var payloadResetPhase: String?
  public var payloadRestoreProgress: Double?
  // v87: a bookmark operation's `(entityKey, time)` key and, for a create or rename, its title.
  // `time` is the exact double the server matches on; see `AudioBookmarkMigration`.
  public var payloadBookmarkTime: Double?
  public var payloadBookmarkTitle: String?

  public init(
    id: Int64? = nil,
    accountId: Int64,
    clientOperationId: String,
    entityKey: String,
    podcastEpisodeId: Int64?,
    operationKind: String,
    coalescingKey: String,
    payloadVersion: Int,
    localSequence: Int64,
    attempts: Int = 0,
    nextAttemptAt: Date? = nil,
    state: OutboxOperationState = .pending,
    payloadCurrentTime: Double? = nil,
    payloadIsFinished: Bool? = nil,
    payloadAccumulatedDeltaSeconds: Double? = nil,
    payloadEbookProgress: Double? = nil,
    payloadEbookLocation: String? = nil,
    payloadDurationSeconds: Double? = nil,
    payloadHideFromContinueListening: Bool? = nil,
    playbackSessionId: Int64? = nil,
    deadLetterReason: String? = nil,
    payloadResetMedium: String? = nil,
    payloadResetPhase: String? = nil,
    payloadRestoreProgress: Double? = nil,
    payloadBookmarkTime: Double? = nil,
    payloadBookmarkTitle: String? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.clientOperationId = clientOperationId
    self.entityKey = entityKey
    self.podcastEpisodeId = podcastEpisodeId
    self.operationKind = operationKind
    self.coalescingKey = coalescingKey
    self.payloadVersion = payloadVersion
    self.localSequence = localSequence
    self.attempts = attempts
    self.nextAttemptAt = nextAttemptAt
    self.state = state
    self.payloadCurrentTime = payloadCurrentTime
    self.payloadIsFinished = payloadIsFinished
    self.payloadAccumulatedDeltaSeconds = payloadAccumulatedDeltaSeconds
    self.payloadEbookProgress = payloadEbookProgress
    self.payloadEbookLocation = payloadEbookLocation
    self.payloadDurationSeconds = payloadDurationSeconds
    self.payloadHideFromContinueListening = payloadHideFromContinueListening
    self.playbackSessionId = playbackSessionId
    self.deadLetterReason = deadLetterReason
    self.payloadResetMedium = payloadResetMedium
    self.payloadResetPhase = payloadResetPhase
    self.payloadRestoreProgress = payloadRestoreProgress
    self.payloadBookmarkTime = payloadBookmarkTime
    self.payloadBookmarkTitle = payloadBookmarkTitle
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
