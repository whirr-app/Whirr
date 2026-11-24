import Foundation

/// A value admitted through the bounded paired-device JSON boundary.
public protocol WatchWireValue: Codable, Sendable {
  static var maxWireBytes: Int { get }
  func validate() throws
}

public enum WatchWireCodec {
  private struct VersionProbe: Decodable {
    let version: Int?
  }

  /// Dates travel as `Date`'s own Double seconds-since-reference-date (`.deferredToDate`), which is exact
  /// for every finite `Date` and lets setup compare challenge expiries by equality.
  public static func encode<Value: WatchWireValue>(_ value: Value) throws -> Data {
    try value.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .deferredToDate
    let data = try encoder.encode(value)
    guard data.count <= Value.maxWireBytes else { throw WatchProtocolCodingError.tooLarge }
    return data
  }

  public static func decode<Value: WatchWireValue>(_ type: Value.Type, from data: Data) throws -> Value {
    guard data.count <= Value.maxWireBytes else { throw WatchProtocolCodingError.tooLarge }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    let probe = try decoder.decode(VersionProbe.self, from: data)
    if let version = probe.version, version != WatchProtocolVersion.current {
      throw WatchProtocolCodingError.unsupportedVersion(version)
    }
    let value = try decoder.decode(type, from: data)
    try value.validate()
    return value
  }
}
