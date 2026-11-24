import Foundation
import GRDB

/// Whether a device uses every accessible library, awaits first-time selection, or has an
/// explicit local allowlist. Unknown stored values fail open so an upgrade never hides a
/// library because of a value introduced by a later app version.
public enum LibrarySelectionMode: String, CaseIterable, Codable, Equatable, Sendable,
  DatabaseValueConvertible
{
  case all
  case pending
  case selected

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self = Self(rawValue: try container.decode(String.self)) ?? .all
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> Self? {
    guard let rawValue = String.fromDatabaseValue(dbValue) else { return nil }
    return Self(rawValue: rawValue) ?? .all
  }
}
