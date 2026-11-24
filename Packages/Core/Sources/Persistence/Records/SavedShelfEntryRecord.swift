import Foundation
import GRDB

/// One account-scoped Saved for Later row. ABS rows carry `itemId` and optionally
/// `podcastEpisodeId`; native RSS rows carry only `rssEpisodeId`. The schema's source check and
/// partial unique indexes keep those scopes independent while preventing duplicate saves.
public struct SavedShelfEntryRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "savedShelfEntry"

  public enum Columns {
    public static let id = Column("id")
    public static let accountId = Column("accountId")
    public static let itemId = Column("itemId")
    public static let podcastEpisodeId = Column("podcastEpisodeId")
    public static let rssEpisodeId = Column("rssEpisodeId")
    public static let savedAt = Column("savedAt")
    public static let subjectTitle = Column("subjectTitle")
    public static let contextTitle = Column("contextTitle")
  }

  public var id: Int64?
  public var accountId: Int64
  public var itemId: Int64?
  public var podcastEpisodeId: Int64?
  public var rssEpisodeId: Int64?
  public var savedAt: Date
  public var subjectTitle: String
  public var contextTitle: String?

  public init(
    id: Int64? = nil,
    accountId: Int64,
    itemId: Int64? = nil,
    podcastEpisodeId: Int64? = nil,
    rssEpisodeId: Int64? = nil,
    savedAt: Date,
    subjectTitle: String = "",
    contextTitle: String? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.itemId = itemId
    self.podcastEpisodeId = podcastEpisodeId
    self.rssEpisodeId = rssEpisodeId
    self.savedAt = savedAt
    self.subjectTitle = subjectTitle
    self.contextTitle = contextTitle
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id
    container["accountId"] = accountId
    container["itemId"] = itemId
    container["podcastEpisodeId"] = podcastEpisodeId
    container["savedAt"] = savedAt
    container["subjectTitle"] = subjectTitle
    container["contextTitle"] = contextTitle
    // Only legacy migration fixtures write this column. Native runtime writes use their table.
    if let rssEpisodeId { container["rssEpisodeId"] = rssEpisodeId }
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
