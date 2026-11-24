import Foundation
import GRDB

/// A path-shaped endpoint template such as `/api/libraries/:id/items`, never a concrete URL,
/// query string, or token (SECURITY.md, ARCHITECTURE.md).
///
/// The failable initialiser rejects a scheme/host, query string, `.` (rules out hostnames and file
/// extensions), whitespace, or any character outside the path-template charset, so the guarantee
/// is structural. A canary passed here comes back `nil`.
public struct EndpointTemplate: Sendable, Equatable, Hashable {
  public let path: String

  private static let maxLength = 128
  private static let allowedCharacters = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_/:{}")

  public init?(_ path: String) {
    guard path.isEmpty == false, path.count <= Self.maxLength else { return nil }
    guard path.hasPrefix("/") else { return nil }
    guard path.contains("://") == false else { return nil }
    guard path.contains("?") == false else { return nil }
    guard path.contains("&") == false else { return nil }
    guard path.contains("=") == false else { return nil }
    guard path.contains(".") == false else { return nil }
    guard path.contains("@") == false else { return nil }
    guard path.unicodeScalars.allSatisfy({ Self.allowedCharacters.contains($0) }) else {
      return nil
    }
    self.path = path
  }
}

extension EndpointTemplate: DatabaseValueConvertible {
  public var databaseValue: DatabaseValue { path.databaseValue }

  public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> EndpointTemplate? {
    guard let stored = String.fromDatabaseValue(dbValue) else { return nil }
    return EndpointTemplate(stored)
  }
}

extension EndpointTemplate: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    let raw = try container.decode(String.self)
    guard let template = EndpointTemplate(raw) else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Not a valid endpoint template: \(raw)")
    }
    self = template
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(path)
  }
}
