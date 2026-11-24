import Foundation
import GRDB

/// One account's most recently observed server-clock offset: the estimated
/// `serverNow - localNow` computed when an authenticated response's `Date` header was received.
/// `observedAt` is that local receipt time, the ordering key `ObservedServerTimeStore` uses to
/// stop an out-of-order observation regressing a fresher one.
public struct ObservedServerTimeRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
  public static let databaseTableName = "observedServerTime"

  public var id: Int64?
  public var accountId: Int64
  public var offsetSeconds: Double
  public var observedAt: Date

  public init(id: Int64? = nil, accountId: Int64, offsetSeconds: Double, observedAt: Date) {
    self.id = id
    self.accountId = accountId
    self.offsetSeconds = offsetSeconds
    self.observedAt = observedAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
