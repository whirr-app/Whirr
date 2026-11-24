import GRDB

struct EbookTOCEntryRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "ebookTOCEntry"

  var id: Int64?
  var accountId: Int64
  var itemId: Int64
  var position: Int
  var title: String
  var href: String?
  var depth: Int
  var startProgression: Double?

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
