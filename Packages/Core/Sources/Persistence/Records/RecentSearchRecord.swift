import Foundation
import GRDB

/// One row per (account, normalised query). `RecentSearchStore` upserts on the
/// `(accountId, normalizedQuery)` unique index rather than reading before writing.
public struct RecentSearchRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "recentSearch"

  public var id: Int64?
  public var accountId: Int64
  public var normalizedQuery: String
  public var displayQuery: String
  public var lastUsedAt: Date

  public init(
    id: Int64? = nil,
    accountId: Int64,
    normalizedQuery: String,
    displayQuery: String,
    lastUsedAt: Date
  ) {
    self.id = id
    self.accountId = accountId
    self.normalizedQuery = normalizedQuery
    self.displayQuery = displayQuery
    self.lastUsedAt = lastUsedAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
