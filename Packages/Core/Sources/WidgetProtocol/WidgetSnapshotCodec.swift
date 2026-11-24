import Foundation

/// Encodes and decodes the snapshot file, as `WatchWireCodec` does for the Watch: validate before
/// encoding and after decoding, bound the bytes both ways, and emit sorted keys so identical
/// content is identical bytes. The publisher relies on that last property to skip a write, and a
/// timeline reload, when nothing changed.
public enum WidgetSnapshotCodec {
  private struct VersionProbe: Decodable {
    let schemaVersion: Int?
  }

  public static func encode(_ snapshot: WidgetSnapshot) throws -> Data {
    try snapshot.validate()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .deferredToDate
    let data = try encoder.encode(snapshot)
    guard data.count <= WidgetSnapshotLimits.maxEncodedBytes else { throw WidgetProtocolError.tooLarge }
    return data
  }

  /// Throws for anything the extension must not draw; the extension then shows its placeholder.
  /// A file from a newer or older app version is `unsupportedVersion`, checked before the rest
  /// of the value is decoded.
  public static func decode(_ data: Data) throws -> WidgetSnapshot {
    guard data.count <= WidgetSnapshotLimits.maxEncodedBytes else { throw WidgetProtocolError.tooLarge }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .deferredToDate
    let probe = try decoder.decode(VersionProbe.self, from: data)
    if let version = probe.schemaVersion, version != WidgetSnapshot.currentSchemaVersion {
      throw WidgetProtocolError.unsupportedVersion(version)
    }
    return try decoder.decode(WidgetSnapshot.self, from: data)
  }
}
