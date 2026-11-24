import Foundation
import GRDB

/// Completion state of a sync run. `incomplete` covers the "finish useful upserts but do not infer
/// deletions" case; `unstablePagination` is the abort case, which never marks deletions.
public enum SyncRunState: String, Codable, Sendable, DatabaseValueConvertible {
  case running
  case completed
  case incomplete
  case unstablePagination
}

/// A durable record of one library traversal. `generation` is the value stamped onto every
/// `ItemRecord`/`PodcastEpisodeRecord` row it touches, so a completed run can identify, and a
/// second one hard-delete, rows it did not see.
public struct SyncRunRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
  public static let databaseTableName = "syncRun"

  public var id: Int64?
  public var accountId: Int64
  public var libraryId: Int64?
  public var reason: String
  public var generation: Int
  public var startedAt: Date
  public var completedAt: Date?
  public var state: SyncRunState
  /// Privacy-safe error category only, never a raw error message or payload.
  public var errorCategory: String?
  /// The sort requested for this run's item traversal. Recorded only; whether the server honours
  /// it is unconfirmed.
  public var sortRequested: String?

  public init(
    id: Int64? = nil,
    accountId: Int64,
    libraryId: Int64? = nil,
    reason: String,
    generation: Int,
    startedAt: Date,
    completedAt: Date? = nil,
    state: SyncRunState = .running,
    errorCategory: String? = nil,
    sortRequested: String? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.libraryId = libraryId
    self.reason = reason
    self.generation = generation
    self.startedAt = startedAt
    self.completedAt = completedAt
    self.state = state
    self.errorCategory = errorCategory
    self.sortRequested = sortRequested
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
