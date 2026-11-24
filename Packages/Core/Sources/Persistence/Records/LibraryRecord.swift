import Foundation
import GRDB

/// One row per server library. `lastSeenGeneration` is stamped by whichever sync run last
/// confirmed the library exists, mirroring the item-level generation bookkeeping used for
/// deletion inference.
public struct LibraryRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
  public static let databaseTableName = "library"

  public var id: Int64?
  public var accountId: Int64
  public var serverLibraryId: String
  public var mediaType: String
  public var name: String
  public var lastSeenGeneration: Int
  /// The server has stopped listing this library. Tombstoned as with `ItemRecord.softDeleted`:
  /// `library` cascades to `item` and `download`, so deleting the row would let the next
  /// `DownloadIntegritySweep` reclaim files after a server blip.
  ///
  /// `LibraryDAO` hides these from every fan-out, so a library deleted and re-created on the
  /// server stops 404ing searches. Cleared when `refreshLibraries` upserts the library live again.
  public var softDeleted: Bool
  /// Whether this device includes the library in its catalogue and discovery scope.
  public var isIncluded: Bool
  /// Server-owned Continue Series policy. This is read-only locally and refreshed from the
  /// library-list response.
  public var onlyShowLaterBooksInContinueSeries: Bool

  public init(
    id: Int64? = nil,
    accountId: Int64,
    serverLibraryId: String,
    mediaType: String,
    name: String,
    lastSeenGeneration: Int = 0,
    softDeleted: Bool = false,
    isIncluded: Bool = true,
    onlyShowLaterBooksInContinueSeries: Bool = false
  ) {
    self.id = id
    self.accountId = accountId
    self.serverLibraryId = serverLibraryId
    self.mediaType = mediaType
    self.name = name
    self.lastSeenGeneration = lastSeenGeneration
    self.softDeleted = softDeleted
    self.isIncluded = isIncluded
    self.onlyShowLaterBooksInContinueSeries = onlyShowLaterBooksInContinueSeries
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
