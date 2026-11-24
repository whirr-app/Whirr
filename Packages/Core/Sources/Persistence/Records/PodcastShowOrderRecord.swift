import GRDB

/// One row per account recording that its Your Shows are in custom order. `mode` is a plain
/// `String` because this is the storage layer, below the domain enum (`PodcastShowSortMode`).
/// An absent row means alphabetical, so only accounts that have made at least one real move hold
/// a row.
public struct PodcastShowOrderRecord: Codable, Equatable, Sendable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "podcastShowOrder"

  public var accountId: Int64
  public var mode: String

  public init(accountId: Int64, mode: String) {
    self.accountId = accountId
    self.mode = mode
  }
}
