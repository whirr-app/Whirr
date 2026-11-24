import Foundation
import GRDB

/// One bounded, privacy-safe diagnostics row (ARCHITECTURE.md D16): category, status
/// class, timing, and an optional endpoint template only. Never a payload, token, or concrete
/// URL. `DiagnosticsStore` is the only writer; this record is just the storage shape.
public struct DiagnosticsEventRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "diagnosticsEvent"

  public var id: Int64?
  public var accountId: Int64
  public var category: DiagnosticsCategory
  public var statusClass: DiagnosticsStatusClass
  public var durationMilliseconds: Double
  public var endpointTemplate: EndpointTemplate?
  public var occurredAt: Date

  public init(
    id: Int64? = nil,
    accountId: Int64,
    category: DiagnosticsCategory,
    statusClass: DiagnosticsStatusClass,
    durationMilliseconds: Double,
    endpointTemplate: EndpointTemplate? = nil,
    occurredAt: Date
  ) {
    self.id = id
    self.accountId = accountId
    self.category = category
    self.statusClass = statusClass
    self.durationMilliseconds = durationMilliseconds
    self.endpointTemplate = endpointTemplate
    self.occurredAt = occurredAt
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
