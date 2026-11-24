import Foundation
import GRDB

/// Operation kinds an outbox row can carry. The live-session kinds each have their own payload
/// shape under a different `payloadVersion`, sharing the `operationKind` column. Ebook position
/// and the shared item-wide finish are separate PATCH legs.
public enum OutboxOperationKind: String, Sendable {
  case progress
  case sessionSync
  case sessionClose
  /// A position-only ebook PATCH. Ebook position operations for the same `(account, item)`
  /// coalesce with each other, newest position wins; they never coalesce with an audio progress
  /// operation.
  case ebookPosition
  /// A fixed ebook reset PATCH: `{ebookProgress:0,isFinished:false}`. Superseded by
  /// `progressReset`; kept so rows queued before v71 still drain.
  case ebookReset
  /// The shared item-wide finish PATCH. It coalesces with nothing, including another shared
  /// finish operation.
  case sharedFinish
  /// A field-only progress PATCH that changes Continue Listening visibility. Hide and unhide
  /// intents for the same item/episode coalesce by rewriting this operation's payload.
  case continueListeningVisibility
  /// Enqueued once, transactionally, when a local (offline) session closes: the sole record that
  /// it is ready for the bounded `local-all` batch upload (API-CONVENTIONS.md rule 10). Never
  /// coalesced, like `sessionClose`. Reuses `OutboxSessionPayload`, as the frozen
  /// position/delta/duration mean the same here.
  case localSessionUpload
  /// A user reset of one medium, sent as a deletion of the server progress row (ADR 0011). The
  /// drain runs persisted phases (resolve the row id, delete it, restore the other medium's
  /// server-captured position), so a crash after the delete resumes at the restore. Coalesces
  /// with nothing.
  case progressReset
  /// Audiobookshelf audio bookmark writes. `entityKey` is
  /// the server item id, so they share that item's queue; the progress protections filter by kind
  /// and never see them. The three coalesce with each other on one bookmark's
  /// `(account, item, time)` key and with nothing else.
  case bookmarkCreate
  case bookmarkRename
  case bookmarkDelete

  // Descriptive aliases for callers that use the wire field's name rather than the
  // position/finish distinction. They resolve to the two canonical kinds, so they cannot create
  // a third persisted kind.
  public static var ebookProgress: Self { .ebookPosition }
  public static var ebookFinish: Self { .sharedFinish }
  public static var finish: Self { .sharedFinish }
}

/// The payload for a `progress`-kind outbox operation (`payloadVersion == 1`): the position and
/// finished flag to send, plus the listening time accumulated since the last acknowledgement.
/// SyncEngine builds the wire body; this is the durable shape coalescing operates on. `isFinished`
/// is optional because `ProgressUpdate` omits a `nil` field: a position-only row (a local
/// session's periodic mirror) must move `currentTime` without restating the flag, as an explicit
/// `false` would un-finish a row the server or another device finished.
public struct OutboxProgressPayload: Equatable, Sendable {
  public var currentTime: Double
  public var isFinished: Bool?
  public var accumulatedDeltaSeconds: Double

  public init(currentTime: Double, isFinished: Bool?, accumulatedDeltaSeconds: Double) {
    self.currentTime = currentTime
    self.isFinished = isFinished
    self.accumulatedDeltaSeconds = accumulatedDeltaSeconds
  }
}

/// The payload for a `sessionSync`/`sessionClose` outbox operation (`payloadVersion == 1`,
/// independent of `progress`'s own version numbering): the position and known duration to send,
/// plus the listening time this row itself is responsible for. `accumulatedDeltaSeconds` is
/// frozen at enqueue/coalesce time so an acknowledgement can subtract exactly this row's share
/// without touching delta a concurrent tick accrued afterward.
public struct OutboxSessionPayload: Equatable, Sendable {
  public var currentTime: Double
  public var accumulatedDeltaSeconds: Double
  public var durationSeconds: Double?

  public init(currentTime: Double, accumulatedDeltaSeconds: Double, durationSeconds: Double? = nil) {
    self.currentTime = currentTime
    self.accumulatedDeltaSeconds = accumulatedDeltaSeconds
    self.durationSeconds = durationSeconds
  }
}

/// The payload for an `ebookPosition` operation (`payloadVersion == 1`). The local Locator JSON
/// stays in `mediaProgress`; only the normalized fraction and an optional genuine EPUB CFI cross
/// the server boundary. A missing location is the ordinary case.
public struct OutboxEbookPositionPayload: Equatable, Sendable {
  public var ebookProgress: Double
  public var ebookLocation: String?

  public init(ebookProgress: Double, ebookLocation: String? = nil) {
    self.ebookProgress = ebookProgress
    self.ebookLocation = ebookLocation
  }
}

public typealias OutboxEbookProgressPayload = OutboxEbookPositionPayload

/// Errors the outbox state machine raises. Illegal transitions and unknown operation ids are
/// programmer/caller errors, not retryable server conditions.
public enum OutboxStoreError: Error, Equatable, Sendable {
  case illegalTransition(from: OutboxOperationState, to: OutboxOperationState)
  case operationNotFound(Int64)
}

/// DB-facing outbox store: transition enforcement, coalescing, launch recovery, and
/// local-sequence ordering. No network/drain logic; draining and APIError classification belong
/// to SyncEngine, and this store only tracks the state a drain loop acts on.
public struct OutboxStore: Sendable {
  let database: AppDatabase

  /// States an unacknowledged progress operation may still be coalesced into. `sending` (a
  /// response may be on the way), `needsResolution` (flagged conflict) and `deadLetter` (terminal
  /// until a user action) are excluded: merging would mutate a row something else relies on.
  static let mergeableStates: [OutboxOperationState] = [.pending, .retryWaiting]

  public init(database: AppDatabase) throws {
    self.database = database
    try Self.recoverStaleSendingRows(on: database)
  }

  /// A crash mid-send must not strand an operation in `sending` forever.
  /// Every store construction (i.e. every app launch) reverts stale `sending` rows to `pending`
  /// before anything else uses the store.
  private static func recoverStaleSendingRows(on database: AppDatabase) throws {
    try database.write { db in
      try db.execute(
        sql: "UPDATE outboxOperation SET state = ? WHERE state = ?",
        arguments: [OutboxOperationState.pending.rawValue, OutboxOperationState.sending.rawValue])
    }
  }

}
