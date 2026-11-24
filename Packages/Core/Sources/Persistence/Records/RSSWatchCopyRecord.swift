import Foundation
import GRDB

/// What the phone wants the active Watch to hold for one episode, or what it last heard about it.
/// The Watch is authoritative about storage: only an inventory entry moves a row to `delivered`.
public enum RSSWatchCopyState: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
  /// In the desired set and offered; the Watch has not reported on this copy yet.
  case wanted
  /// The Watch is signed out, or cannot take copies, so it is re-sent after sign-in.
  case waitingForWatch
  /// The offer is out and the Watch is downloading the enclosure itself. Its inventory refines
  /// this with the live state and progress; only a `ready` entry makes the copy `delivered`.
  case sending
  /// The Watch reported the copy ready in its inventory: the only evidence of delivery.
  case delivered
  case removed
  case declined
  /// The Watch reported a failed download. Retryable: `request` bumps the revision.
  case failed
}

/// Who removed a copy. Present exactly when `state == .removed`.
public enum RSSWatchCopyRemovalInitiator: String, Codable, Sendable, CaseIterable,
  DatabaseValueConvertible
{
  case phone
  case watch
}

/// Why the Watch declined a copy. Present exactly when `state == .declined`.
public enum RSSWatchDeclineReason: String, Codable, Sendable, CaseIterable,
  DatabaseValueConvertible
{
  case storageFull
  case invalid
  case signedOut
}

/// The `rssWatchCopy` row: one episode's entry in the desired set for the active Watch.
///
/// `revision` starts at 1 and advances on every re-request after a terminal state, so the Watch can
/// tell a re-send from a late duplicate. `sourceBytes` is the admitted copy's byte count from the
/// Watch's `ready` inventory, and `nil` until it reports one. `requestedAt` orders the next offer,
/// newest first.
public struct RSSWatchCopy: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "rssWatchCopy"

  public var episodeId: Int64
  /// The Watch install this row was last offered to; `nil` until the first inventory names one.
  public var watchInstallID: String?
  public var revision: Int64
  public var state: RSSWatchCopyState
  public var removedBy: RSSWatchCopyRemovalInitiator?
  public var declineReason: RSSWatchDeclineReason?
  public var sourceBytes: Int64?
  public var requestedAt: Date
  public var updatedAt: Date
  public var failedAt: Date?

  public init(
    episodeId: Int64,
    watchInstallID: String? = nil,
    revision: Int64 = 1,
    state: RSSWatchCopyState,
    removedBy: RSSWatchCopyRemovalInitiator? = nil,
    declineReason: RSSWatchDeclineReason? = nil,
    sourceBytes: Int64? = nil,
    requestedAt: Date,
    updatedAt: Date,
    failedAt: Date? = nil
  ) {
    self.episodeId = episodeId
    self.watchInstallID = watchInstallID
    self.revision = revision
    self.state = state
    self.removedBy = removedBy
    self.declineReason = declineReason
    self.sourceBytes = sourceBytes
    self.requestedAt = requestedAt
    self.updatedAt = updatedAt
    self.failedAt = failedAt
  }
}

/// The `rssWatchCopySet` row: the active Watch's identity, the desired-set generation, and what
/// its last inventory reported. One per device: the set belongs to the active Watch.
public struct RSSWatchCopySetRecord: Codable, Equatable, Sendable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "rssWatchCopySet"
  public static let singletonID: Int64 = 1

  public var id: Int64
  public var watchInstallID: String?
  /// Bumps whenever membership, a revision or a removal changes.
  public var generation: Int64
  public var acknowledgedGeneration: Int64
  public var inventorySequence: Int64
  public var acceptsCopies: Bool?
  public var budgetTotalBytes: Int64?
  public var budgetUsedBytes: Int64?
  public var lastInventoryAt: Date?

  public init(
    id: Int64 = RSSWatchCopySetRecord.singletonID,
    watchInstallID: String? = nil,
    generation: Int64 = 0,
    acknowledgedGeneration: Int64 = 0,
    inventorySequence: Int64 = 0,
    acceptsCopies: Bool? = nil,
    budgetTotalBytes: Int64? = nil,
    budgetUsedBytes: Int64? = nil,
    lastInventoryAt: Date? = nil
  ) {
    self.id = id
    self.watchInstallID = watchInstallID
    self.generation = generation
    self.acknowledgedGeneration = acknowledgedGeneration
    self.inventorySequence = inventorySequence
    self.acceptsCopies = acceptsCopies
    self.budgetTotalBytes = budgetTotalBytes
    self.budgetUsedBytes = budgetUsedBytes
    self.lastInventoryAt = lastInventoryAt
  }
}
