import Foundation
import GRDB

/// One Audiobookshelf title the phone can send to the Watch: a book, or one episode of an
/// Audiobookshelf podcast.
public struct ABSWatchCopyKey: Hashable, Sendable {
  public let itemId: String
  /// `nil` for a book.
  public let episodeId: String?

  public init(itemId: String, episodeId: String?) {
    self.itemId = itemId
    self.episodeId = episodeId.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// The stored column: '' stands for a book, so the primary key holds no NULL.
  var storedEpisodeId: String { episodeId ?? "" }
}

/// Why the Watch reported a phone-sent title as failed. The Watch's own vocabulary, in the phone's
/// terms so Persistence names no wire type (ADR 0021).
public enum ABSWatchFailureReason: String, Codable, Sendable, CaseIterable,
  DatabaseValueConvertible
{
  case httpStatus
  case insecureRedirect
  case tooLarge
  case invalidResponse
  case network
  /// The server no longer has the item or episode.
  case itemMissing
  /// The item has no audio the Watch can play.
  case noAudio
  /// The Watch could not plan the files.
  case planInvalid
}

/// The `absWatchCopy` row: one Audiobookshelf title in the signed-in account's desired set for the
/// active Watch, or the phone's removal of one.
///
/// It shares `rssWatchCopy`'s state, removal and decline vocabularies, so the two stores
/// map into one App status. `revision` starts at 1 and advances on every re-request after a
/// terminal state. A phone removal records the generation that first carried it in
/// `removalGeneration` until an inventory acknowledges that generation; a removal of a
/// title the Watch downloaded itself is a row that was never a member.
public struct ABSWatchCopy: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "absWatchCopy"

  public var accountId: Int64
  public var itemId: String
  /// '' for a book; read `key` rather than this column.
  public var episodeId: String
  public var title: String
  /// The author of a book, or the show of an episode.
  public var subtitle: String?
  public var watchInstallID: String?
  public var revision: Int64
  public var state: RSSWatchCopyState
  public var removedBy: RSSWatchCopyRemovalInitiator?
  public var removalGeneration: Int64?
  public var declineReason: RSSWatchDeclineReason?
  public var failureReason: ABSWatchFailureReason?
  /// The size the phone knew when it sent the title, if it knew one.
  public var declaredBytes: Int64?
  /// What the Watch reported holding once the title was ready.
  public var sourceBytes: Int64?
  public var requestedAt: Date
  public var updatedAt: Date
  public var failedAt: Date?

  public init(
    accountId: Int64,
    key: ABSWatchCopyKey,
    title: String,
    subtitle: String? = nil,
    watchInstallID: String? = nil,
    revision: Int64 = 1,
    state: RSSWatchCopyState,
    removedBy: RSSWatchCopyRemovalInitiator? = nil,
    removalGeneration: Int64? = nil,
    declineReason: RSSWatchDeclineReason? = nil,
    failureReason: ABSWatchFailureReason? = nil,
    declaredBytes: Int64? = nil,
    sourceBytes: Int64? = nil,
    requestedAt: Date,
    updatedAt: Date,
    failedAt: Date? = nil
  ) {
    self.accountId = accountId
    self.itemId = key.itemId
    self.episodeId = key.storedEpisodeId
    self.title = title
    self.subtitle = subtitle
    self.watchInstallID = watchInstallID
    self.revision = revision
    self.state = state
    self.removedBy = removedBy
    self.removalGeneration = removalGeneration
    self.declineReason = declineReason
    self.failureReason = failureReason
    self.declaredBytes = declaredBytes
    self.sourceBytes = sourceBytes
    self.requestedAt = requestedAt
    self.updatedAt = updatedAt
    self.failedAt = failedAt
  }

  public var key: ABSWatchCopyKey { ABSWatchCopyKey(itemId: itemId, episodeId: episodeId) }
}

/// The Audiobookshelf half of the active Watch's set row, with the storage figure both halves
/// share (one inventory carries one).
public struct ABSWatchCopySetState: Sendable, Equatable {
  public let watchInstallID: String?
  /// Bumps whenever membership, a revision or a removal changes.
  public let generation: Int64
  public let acknowledgedGeneration: Int64
  public let inventorySequence: Int64
  /// The account the last applied inventory was stamped with; `nil` after an account change until
  /// an inventory for the signed-in account arrives.
  public let inventoryAccountHash: String?
  public let budgetTotalBytes: Int64?
  public let budgetUsedBytes: Int64?
  public let lastInventoryAt: Date?

  public init(
    watchInstallID: String? = nil,
    generation: Int64 = 0,
    acknowledgedGeneration: Int64 = 0,
    inventorySequence: Int64 = 0,
    inventoryAccountHash: String? = nil,
    budgetTotalBytes: Int64? = nil,
    budgetUsedBytes: Int64? = nil,
    lastInventoryAt: Date? = nil
  ) {
    self.watchInstallID = watchInstallID
    self.generation = generation
    self.acknowledgedGeneration = acknowledgedGeneration
    self.inventorySequence = inventorySequence
    self.inventoryAccountHash = inventoryAccountHash
    self.budgetTotalBytes = budgetTotalBytes
    self.budgetUsedBytes = budgetUsedBytes
    self.lastInventoryAt = lastInventoryAt
  }
}
