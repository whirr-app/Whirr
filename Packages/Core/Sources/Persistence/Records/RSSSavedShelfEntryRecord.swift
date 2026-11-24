import Foundation
import GRDB

/// A device-owned Saved for Later row. It has no account relationship: native RSS
/// history is retained when an optional ABS account is removed.
public struct RSSSavedShelfEntryRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "rssSavedShelfEntry"
  public var id: Int64?
  public var rssEpisodeId: Int64
  public var savedAt: Date
  public var subjectTitle: String
  public var contextTitle: String?

  public init(
    id: Int64? = nil, rssEpisodeId: Int64, savedAt: Date,
    subjectTitle: String = "", contextTitle: String? = nil
  ) {
    self.id = id
    self.rssEpisodeId = rssEpisodeId
    self.savedAt = savedAt
    self.subjectTitle = subjectTitle
    self.contextTitle = contextTitle
  }
  public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
