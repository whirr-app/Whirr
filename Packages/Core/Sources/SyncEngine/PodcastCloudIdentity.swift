import CryptoKit
import Foundation
import Persistence

/// Versioned, opaque identifiers used in PodcastState record names.
public enum PodcastCloudIdentity {
  public static let version = "v1"
  public static let subscriptionNamespace = "com.remoteconcern.whirr.subscription.v1"
  public static let recordNameUUIDNamespace = "com.remoteconcern.whirr.recordname.uuid.v1"
  public static let recordNameDigestNamespace = "com.remoteconcern.whirr.recordname.digest.v1"
  public static let keyringRecordName = "v1.keyring"
  public static let initialGenerationNamespace = "com.remoteconcern.whirr.generation.v1"
  public static let legacyMutationNamespace = "com.remoteconcern.whirr.migration.mutation.v1"

  /// The author token every backfilled follow stamp carries instead of a real installation UUID.
  ///
  /// The nil UUID, for two properties a derived value would hold only in practice. It is the
  /// lexicographic minimum of the UUID string space, so a device's own mutation wins a tie-break
  /// against a backfilled stamp on the same millisecond and counter (user action beats
  /// bookkeeping). Its version nibble is zero, which no minted (version 4) identity can produce,
  /// so no installation can author under it.
  public static let migrationAuthorInstallationUUID = "00000000-0000-0000-0000-000000000000"

  public static func normalizedFeedURL(_ raw: String) -> String? {
    PodcastFeedIdentity.normalized(raw)
  }

  public static func subscriptionUUID(feedURL: String) -> UUID? {
    guard let normalized = normalizedFeedURL(feedURL) else { return nil }
    return derivedUUID(namespace: subscriptionNamespace, component: normalized)
  }

  /// A first follow's generation. Derived rather than minted so two offline devices that follow the
  /// same feed for the first time agree on the generation as well as the identity; an explicit
  /// re-follow leaves this derivation behind and mints a fresh generation instead.
  public static func initialGenerationUUID(subscriptionUUID: UUID) -> UUID {
    derivedUUID(namespace: initialGenerationNamespace, component: subscriptionUUID.uuidString.lowercased())
  }

  /// The mutation UUID a backfilled follow stamp carries. Derived from the subscription so a
  /// repeated backfill of the same feed is the same mutation rather than a new one.
  public static func legacyMutationUUID(subscriptionUUID: UUID) -> UUID {
    derivedUUID(namespace: legacyMutationNamespace, component: subscriptionUUID.uuidString.lowercased())
  }

  public static let seedMutationNamespace = "com.remoteconcern.whirr.seed.mutation.v1"

  /// The mutation UUID of a value first published from local state with no accepted cloud value:
  /// derived from what the record is and what it says, so the same facts seed the same stamp on
  /// every device and every re-run, and two different values never share one.
  public static func seedMutationUUID(recordName: String, value: String) -> UUID {
    derivedUUID(namespace: seedMutationNamespace, component: recordName + "\u{0}" + value)
  }

  private static func derivedUUID(namespace: String, component: String) -> UUID {
    let digest = SHA256.hash(data: lengthPrefixed(namespace) + lengthPrefixed(component))
    var bytes = Array(digest.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x80  // version 8
    bytes[8] = (bytes[8] & 0x3f) | 0x80  // RFC 4122 variant
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10],
        bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  public static func episodeDigest(identityKey: String) -> String {
    SHA256.hash(data: Data(identityKey.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// Structural names admit only the fixed V1 types and canonical opaque components.
  public static func recordName(
    kind: String, components: [String], key: PodcastCloudRecordNameKey
  ) throws -> String {
    let uuidCount: Int
    let needsDigest: Bool
    switch kind {
    case "globals", "bookmark":
      guard components.isEmpty else { throw RecordNameError.invalid }
      return "v1.\(kind)"
    case "keyring":
      guard components.isEmpty else { throw RecordNameError.invalid }
      return keyringRecordName
    case "sub": (uuidCount, needsDigest) = (1, false)
    case "settings": (uuidCount, needsDigest) = (2, false)
    case "state", "saved", "identity": (uuidCount, needsDigest) = (2, true)
    default: throw RecordNameError.invalid
    }
    guard components.count == uuidCount + (needsDigest ? 1 : 0) else {
      throw RecordNameError.invalid
    }
    for component in components.prefix(uuidCount) {
      guard let uuid = UUID(uuidString: component), uuid.uuidString.lowercased() == component else {
        throw RecordNameError.invalid
      }
    }
    if needsDigest {
      let digest = components[uuidCount]
      guard digest.utf8.count == 64,
        digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { throw RecordNameError.invalid }
    }
    let keyedComponents = components.enumerated().map { index, component in
      if index < uuidCount {
        keyedUUID(component, key: key)
      } else {
        keyedDigest(component, key: key)
      }
    }
    let name = "v1.\(kind)." + keyedComponents.joined(separator: ".")
    guard name.utf8.count <= 255 else { throw RecordNameError.invalid }
    return name
  }
  public enum RecordNameError: Error, Sendable, Equatable { case invalid }

  private static func keyedUUID(_ component: String, key: PodcastCloudRecordNameKey) -> String {
    let mac = HMAC<SHA256>.authenticationCode(
      for: lengthPrefixed(recordNameUUIDNamespace) + lengthPrefixed(component),
      using: SymmetricKey(data: key.bytes))
    var bytes = Array(mac.prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x80  // version 8
    bytes[8] = (bytes[8] & 0x3f) | 0x80  // RFC 4122 variant
    let uuid = UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10],
        bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
    return uuid.uuidString.lowercased()
  }

  private static func keyedDigest(_ component: String, key: PodcastCloudRecordNameKey) -> String {
    let mac = HMAC<SHA256>.authenticationCode(
      for: lengthPrefixed(recordNameDigestNamespace) + lengthPrefixed(component),
      using: SymmetricKey(data: key.bytes))
    return mac.map { String(format: "%02x", $0) }.joined()
  }

  private static func lengthPrefixed(_ value: String) -> Data {
    let bytes = Data(value.utf8)
    var length = UInt64(bytes.count).bigEndian
    return Data(bytes: &length, count: MemoryLayout<UInt64>.size) + bytes
  }
}
