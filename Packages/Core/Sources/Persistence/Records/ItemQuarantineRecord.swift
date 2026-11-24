import Foundation
import GRDB

/// Detached audit marker for a server item whose identity collided with a device-owned namespace.
/// `itemId` is not a foreign key: the invalid item may be reaped after all legitimate
/// local references disappear, while this privacy-safe marker remains until account removal.
public struct ItemQuarantineRecord: Codable, Equatable, Sendable, FetchableRecord, TableRecord {
  public static let databaseTableName = "itemQuarantine"

  public let itemId: Int64
  public let accountId: Int64
  public let serverItemId: String
  public let reason: String
  public let quarantinedAt: Date
  public let terminalizedOperationCount: Int
}
