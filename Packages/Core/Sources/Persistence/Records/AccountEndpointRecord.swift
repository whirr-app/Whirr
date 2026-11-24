import Foundation
import GRDB

/// One ordered, normalized address through which an account can reach its server.
public struct AccountEndpointRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "accountEndpoint"

  public var id: Int64?
  public var accountId: Int64
  public var normalizedURL: String
  public var isPreferred: Bool
  public var sortOrder: Int
  public var addedAt: Date
  public var lastReachedAt: Date?
  public var lastFailedAt: Date?

  public init(
    id: Int64? = nil,
    accountId: Int64,
    normalizedURL: String,
    isPreferred: Bool,
    sortOrder: Int,
    addedAt: Date,
    lastReachedAt: Date? = nil,
    lastFailedAt: Date? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.normalizedURL = normalizedURL
    self.isPreferred = isPreferred
    self.sortOrder = sortOrder
    self.addedAt = addedAt
    self.lastReachedAt = lastReachedAt
    self.lastFailedAt = lastFailedAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
