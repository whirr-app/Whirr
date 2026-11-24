import GRDB

/// One optional row per account (`v16`): the live value `ListeningQueueStore` bumps on every
/// committed queue mutation, including `clear()` and `restore(token:)` themselves. An absent row
/// means revision `0`, as with `PodcastShowOrderRecord`.
public struct ListeningQueueRevisionRecord: Codable, Equatable, Sendable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "listeningQueueRevision"

  public var accountId: Int64
  public var revision: Int64

  public init(accountId: Int64, revision: Int64) {
    self.accountId = accountId
    self.revision = revision
  }
}
