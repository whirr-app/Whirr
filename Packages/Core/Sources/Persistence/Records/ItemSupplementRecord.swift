import GRDB

struct ItemSupplementRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  static let databaseTableName = "itemSupplement"

  var id: Int64?
  var accountId: Int64
  var itemId: Int64
  var position: Int
  var serverFileIno: String
  var filename: String?
  var sizeBytes: Int64
  var lastViewedPage: Int?

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
