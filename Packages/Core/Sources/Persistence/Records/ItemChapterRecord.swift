import GRDB

struct ItemChapterRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  static let databaseTableName = "itemChapter"

  var id: Int64?
  var accountId: Int64
  var itemId: Int64
  var position: Int
  var serverChapterId: Int
  var start: Double
  var end: Double
  var title: String?

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
