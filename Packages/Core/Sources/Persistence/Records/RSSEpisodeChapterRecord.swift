import GRDB

struct RSSEpisodeChapterRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  static let databaseTableName = "rssEpisodeChapter"

  var id: Int64?
  var episodeId: Int64
  var position: Int
  var start: Double
  var end: Double
  var title: String?

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
