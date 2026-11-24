import GRDB

/// One row per positioned show, with the account-scoped integer-position shape of
/// `ListeningQueueEntryRecord`. The composite `(accountId, itemId)` foreign key to `item`'s
/// `(accountId, id)` unique index (created with this table by `SchemaV1`'s `v14` migration) lets a
/// row cascade away when its show is deleted, not only when the whole account is.
public struct PodcastShowOrderEntryRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "podcastShowOrderEntry"

  public var id: Int64?
  public var accountId: Int64
  public var itemId: Int64
  public var position: Int

  public init(
    id: Int64? = nil,
    accountId: Int64,
    itemId: Int64,
    position: Int
  ) {
    self.id = id
    self.accountId = accountId
    self.itemId = itemId
    self.position = position
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
