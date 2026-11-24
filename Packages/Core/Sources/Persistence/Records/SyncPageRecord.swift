import Foundation
import GRDB

/// One fetched-and-applied page within a `SyncRunRecord`. A page and its checkpoint apply in the
/// same transaction as the rows it upserts, so a crash between pages resumes or restarts cleanly
/// and never half-applies a page.
public struct SyncPageRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
  public static let databaseTableName = "syncPage"

  public var id: Int64?
  public var accountId: Int64
  public var syncRunId: Int64
  public var pageNumber: Int
  public var itemCount: Int
  public var fetchedAt: Date
  public var resultCategory: String?

  public init(
    id: Int64? = nil,
    accountId: Int64,
    syncRunId: Int64,
    pageNumber: Int,
    itemCount: Int,
    fetchedAt: Date,
    resultCategory: String? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.syncRunId = syncRunId
    self.pageNumber = pageNumber
    self.itemCount = itemCount
    self.fetchedAt = fetchedAt
    self.resultCategory = resultCategory
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
