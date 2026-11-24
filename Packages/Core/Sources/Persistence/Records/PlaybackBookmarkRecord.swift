import Foundation
import GRDB

/// At most one row per account (unique index on `accountId`): the item (and, for a podcast, the
/// episode) this device last had loaded in the player. The position lives in `mediaProgress` and
/// is joined at read time, so ordinary playback progress never rewrites this row; only switching
/// item does.
public struct PlaybackBookmarkRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "playbackBookmark"

  public var id: Int64?
  public var accountId: Int64
  public var itemId: Int64
  public var podcastEpisodeId: Int64?
  public var updatedAt: Date

  public init(
    id: Int64? = nil,
    accountId: Int64,
    itemId: Int64,
    podcastEpisodeId: Int64? = nil,
    updatedAt: Date
  ) {
    self.id = id
    self.accountId = accountId
    self.itemId = itemId
    self.podcastEpisodeId = podcastEpisodeId
    self.updatedAt = updatedAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
