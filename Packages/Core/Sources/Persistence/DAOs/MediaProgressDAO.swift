import Foundation
import GRDB

/// Errors `MediaProgressDAO`'s conflict-resolution methods raise. A missing conflict row is a
/// caller error (already resolved, or never existed). Both resolution actions are meant to be
/// idempotent and relaunch-safe, so a caller that re-fetches the open-item list before acting
/// never hits this; it makes a repeated action on an already-cleared conflict a safe no-op
/// rather than a silent double-apply.
public enum MediaProgressDAOError: Error, Equatable, Sendable {
  case conflictNotFound(Int64)
  case ebookOperationRequiresItemIdentity
  case ebookPositionJSONTooLarge
  case ebookLocationTooLarge
  case invalidEbookProgress
}

/// A local progress write must name its medium and carry the complete payload for that medium.
/// This makes it impossible for an ebook position update to silently fall back to `currentTime`,
/// or for an audio update to overwrite ebook state.
public enum MediaProgressField: Sendable, Equatable {
  case audio(currentTime: Double, isFinished: Bool)
  case ebook(readingPositionJSON: String, ebookProgress: Double)
}

/// The field whose unacknowledged outbox operations should protect a pulled value. Position and
/// finish are separate because `isFinished` is shared while ebook/audio positions
/// are disjoint on the wire and in the local row.
public enum MediaProgressPendingField: Sendable, Equatable {
  case audioPosition
  case ebookPosition
  case sharedFinish
  case continueListeningVisibility
}

/// Result of an atomic ebook-position mutation. Both values were produced by the same GRDB
/// transaction; callers may inspect them without opening a second read.
public struct EbookProgressWriteResult: Sendable, Equatable {
  public let progress: MediaProgressRecord
  public let operation: OutboxOperationRecord

  public init(progress: MediaProgressRecord, operation: OutboxOperationRecord) {
    self.progress = progress
    self.operation = operation
  }
}

public typealias EbookFinishWriteResult = EbookProgressWriteResult

/// A field-scoped result produced by SyncEngine's progress merge policy. Persistence
/// owns a small boundary type rather than importing SyncEngine; the policy result is mapped to
/// this value before the one atomic database write.
public enum MediaProgressResolution: Sendable, Equatable {
  case applyServer
  case keepLocal
  case needsResolution
  case rejectStale
}

/// Independent outcomes for one server observation. Applying this value through
/// `applyServerCompositeResolutionAsync` updates every winning field in one transaction and
/// leaves losing or unresolved fields untouched.
public struct MediaProgressCompositeResolution: Sendable, Equatable {
  public let audioPosition: MediaProgressResolution
  public let ebookPosition: MediaProgressResolution
  public let sharedFinish: MediaProgressResolution
  public let continueListeningVisibility: MediaProgressResolution

  public init(
    audioPosition: MediaProgressResolution,
    ebookPosition: MediaProgressResolution,
    sharedFinish: MediaProgressResolution,
    continueListeningVisibility: MediaProgressResolution = .keepLocal
  ) {
    self.audioPosition = audioPosition
    self.ebookPosition = ebookPosition
    self.sharedFinish = sharedFinish
    self.continueListeningVisibility = continueListeningVisibility
  }
}

/// The complete local identity of one progress row. Callers must choose item or episode explicitly
/// so an omitted episode id can never silently redirect an episode operation to show-level
/// progress.
public enum MediaProgressIdentity: Sendable, Equatable {
  case item(itemId: Int64)
  case episode(itemId: Int64, podcastEpisodeId: Int64)

  public var itemId: Int64 {
    switch self {
    case .item(let itemId), .episode(let itemId, _): itemId
    }
  }

  public var podcastEpisodeId: Int64? {
    switch self {
    case .item: nil
    case .episode(_, let podcastEpisodeId): podcastEpisodeId
    }
  }
}

/// Minimal read/write access to item- and episode-scoped `MediaProgressRecord` rows. Pulls
/// use this to read the persisted state `ProgressMergePolicy` needs and apply its decision;
/// the decision itself is SyncEngine's job.
public struct MediaProgressDAO: Sendable {
  public typealias CompositeResolution = MediaProgressCompositeResolution

  /// The JSON envelope can contain two independently bounded ReaderCore strings, so its storage
  /// bound is larger than either individual string while remaining finite.
  public static let maximumEbookJSONBytes = 64 * 1024
  public static let maximumEbookStringBytes = 16 * 1024
  public static let maximumReadingPositionJSONBytes = maximumEbookJSONBytes
  public static let maximumEbookLocationBytes = maximumEbookStringBytes

  let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  // MARK: - Batched pull application

  /// One item's already-decided `applyServer` outcome from a library pull.
  public struct PulledProgressResolution: Sendable, Equatable {
    public let identity: MediaProgressIdentity
    public let currentTime: Double
    public let isFinished: Bool
    public let serverUpdatedAt: Date?

    public init(
      identity: MediaProgressIdentity, currentTime: Double, isFinished: Bool,
      serverUpdatedAt: Date?
    ) {
      self.identity = identity
      self.currentTime = currentTime
      self.isFinished = isFinished
      self.serverUpdatedAt = serverUpdatedAt
    }
  }

  /// One item's already-decided `needsResolution` outcome from a library pull.
  public struct PulledProgressConflict: Sendable, Equatable {
    public let identity: MediaProgressIdentity
    public let serverCurrentTime: Double
    public let serverIsFinished: Bool
    public let serverUpdatedAt: Date?
    public let detectedAt: Date

    public init(
      identity: MediaProgressIdentity, serverCurrentTime: Double, serverIsFinished: Bool,
      serverUpdatedAt: Date?, detectedAt: Date
    ) {
      self.identity = identity
      self.serverCurrentTime = serverCurrentTime
      self.serverIsFinished = serverIsFinished
      self.serverUpdatedAt = serverUpdatedAt
      self.detectedAt = detectedAt
    }
  }

  /// One composite server observation whose field-level decisions have already been made by
  /// `SyncEngine`. Optional position values are expected: an ebook-only `/api/me` row has no
  /// audio `currentTime`, and applying it must not fabricate an audio write.
  /// No field has a default: a defaulted `hideFromContinueListening` would be silently omitted by
  /// the batch apply (the only path a real library pull takes) and stamp `false` over a local hide
  /// once its outbox row was acknowledged. A resolution names every field it decides.
  public struct PulledCompositeResolution: Sendable, Equatable {
    public let identity: MediaProgressIdentity
    public let currentTime: Double?
    public let isFinished: Bool
    public let ebookProgress: Double?
    public let ebookLocation: String?
    public let hideFromContinueListening: Bool
    public let serverUpdatedAt: Date?
    /// The id of the server row observed for this identity, or `nil` when the complete snapshot
    /// held none. Recorded whatever the field decisions are: it names the row this device last
    /// saw, not the row whose values won.
    public let serverProgressId: String?
    public let resolution: MediaProgressCompositeResolution

    public init(
      identity: MediaProgressIdentity,
      currentTime: Double?,
      isFinished: Bool,
      ebookProgress: Double?,
      ebookLocation: String?,
      hideFromContinueListening: Bool,
      serverUpdatedAt: Date?,
      serverProgressId: String?,
      resolution: MediaProgressCompositeResolution
    ) {
      self.identity = identity
      self.currentTime = currentTime
      self.isFinished = isFinished
      self.ebookProgress = ebookProgress
      self.ebookLocation = ebookLocation
      self.hideFromContinueListening = hideFromContinueListening
      self.serverUpdatedAt = serverUpdatedAt
      self.serverProgressId = serverProgressId
      self.resolution = resolution
    }
  }

  /// A composite `needsResolution` observation. The conflict table predates ebook fields and
  /// therefore retains the audio value as its durable server-position slot; an ebook-only
  /// conflict carries the local audio value there so take-server cannot manufacture an audio
  /// reset. `serverEbookProgress` is set only when the ebook position is itself in conflict.
  public struct PulledCompositeConflict: Sendable, Equatable {
    public let identity: MediaProgressIdentity
    public let serverCurrentTime: Double?
    public let serverIsFinished: Bool
    public let serverUpdatedAt: Date?
    public let detectedAt: Date
    public let serverEbookProgress: Double?
    public let serverEbookLocation: String?

    public init(
      identity: MediaProgressIdentity,
      serverCurrentTime: Double?,
      serverIsFinished: Bool,
      serverUpdatedAt: Date?,
      detectedAt: Date,
      serverEbookProgress: Double? = nil,
      serverEbookLocation: String? = nil
    ) {
      self.identity = identity
      self.serverCurrentTime = serverCurrentTime
      self.serverIsFinished = serverIsFinished
      self.serverUpdatedAt = serverUpdatedAt
      self.detectedAt = detectedAt
      self.serverEbookProgress = serverEbookProgress
      self.serverEbookLocation = serverEbookLocation
    }
  }

  /// How an applied pull treats the stored server row id.
  public enum ServerProgressIdUpdate: Sendable, Equatable {
    /// The caller made no observation of the server row's identity.
    case unchanged
    /// The server row id seen for the identity and that row's `lastUpdate`, or `nil`s when none
    /// was seen.
    case observed(id: String?, updatedAt: Date?)
  }
}
