import GRDB

/// Device owned RSS Up Next row.  Its id namespace is separate from the ABS queue so a
/// source-qualified identity is required whenever the two tables are projected together.
public struct RSSListeningQueueEntryRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "rssListeningQueueEntry"

  public var id: Int64?
  public var rssEpisodeId: Int64
  public var position: Int

  public init(id: Int64? = nil, rssEpisodeId: Int64, position: Int) {
    self.id = id
    self.rssEpisodeId = rssEpisodeId
    self.position = position
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
