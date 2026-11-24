import Foundation

/// Limits for pushing row covers from the phone to the Watch. Manifests and bundles travel as
/// files, which `WatchWireCodec` holds whole in memory, so both are bounded well below the Watch's
/// memory budget.
public enum WatchArtworkSyncLimits {
  public static let maxManifestCovers = 8_192
  public static let maxWantedCovers = 256
  /// Raw image bytes per bundle; base64 adds a third on the wire.
  public static let maxBundleImageBytes = 1024 * 1024
  /// The Watch discards any received file larger than this without reading it.
  public static let maxReceivedFileBytes = 2 * 1024 * 1024
}

/// Keys for the sync values. An older peer ignores keys it does not know.
public enum WatchArtworkSyncTransport {
  /// File-transfer metadata key naming which value the file holds.
  public static let fileKind = "whirr.watch.artwork.sync.kind"
  public static let manifestKind = "manifest.v1"
  public static let bundleKind = "bundle.v1"
  /// The `transferUserInfo` key carrying a `WatchArtworkWantList`.
  public static let wantList = "whirr.watch.artwork.want.v1"
}

/// One cover at one size; the unit the phone lists, the Watch asks for and the phone sends.
public struct WatchArtworkCover: Codable, Hashable, Sendable {
  public let reference: WatchArtworkReference
  public let size: WatchArtworkSize

  public init(reference: WatchArtworkReference, size: WatchArtworkSize) {
    self.reference = reference
    self.size = size
  }
}

/// Every cover the phone can serve for its catalogue account. The Watch decides what it is missing.
public struct WatchArtworkManifest: WatchWireValue, Equatable {
  public static let maxWireBytes = WatchArtworkSyncLimits.maxReceivedFileBytes
  public let version: Int
  public let id: UUID
  /// The phone's catalogue stamp; synced covers are filed under it.
  public let accountStamp: WatchAccountStamp
  /// The same account as the Watch's own sign-in would stamp it, when the phone knows it.
  public let authenticatedAccountStamp: WatchAccountStamp?
  public let covers: [WatchArtworkCover]

  public init(
    accountStamp: WatchAccountStamp, authenticatedAccountStamp: WatchAccountStamp?, covers: [WatchArtworkCover]
  ) throws {
    version = WatchProtocolVersion.current
    id = UUID()
    self.accountStamp = accountStamp
    self.authenticatedAccountStamp = authenticatedAccountStamp
    self.covers = covers
    try validate()
  }

  /// Whether a resend would tell the Watch anything new; the ID alone differs between builds.
  public func hasSameCovers(as other: WatchArtworkManifest) -> Bool {
    accountStamp == other.accountStamp && authenticatedAccountStamp == other.authenticatedAccountStamp
      && covers == other.covers
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else { throw WatchProtocolCodingError.unsupportedVersion(version) }
    try accountStamp.validate()
    try authenticatedAccountStamp?.validate()
    try WatchArtworkCover.validate(covers, limit: WatchArtworkSyncLimits.maxManifestCovers)
  }
}

/// The Watch's request for covers it lacks. An empty list asks the phone for a fresh manifest.
public struct WatchArtworkWantList: WatchWireValue, Equatable {
  /// `transferUserInfo` payloads are small by contract.
  public static let maxWireBytes = 64 * 1024
  public let version: Int
  public let id: UUID
  public let accountStamp: WatchAccountStamp
  public let manifestID: UUID?
  public let covers: [WatchArtworkCover]

  public var isManifestRequest: Bool { covers.isEmpty }

  public init(accountStamp: WatchAccountStamp, manifestID: UUID?, covers: [WatchArtworkCover]) throws {
    version = WatchProtocolVersion.current
    id = UUID()
    self.accountStamp = accountStamp
    self.manifestID = manifestID
    self.covers = covers
    try validate()
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else { throw WatchProtocolCodingError.unsupportedVersion(version) }
    try accountStamp.validate()
    try WatchArtworkCover.validate(covers, limit: WatchArtworkSyncLimits.maxWantedCovers)
  }
}

/// Part of the phone's answer to one want list. The final bundle also names the covers the phone
/// could not serve, so the Watch stops asking for them until the next manifest.
public struct WatchArtworkBundle: WatchWireValue, Equatable {
  public static let maxWireBytes = WatchArtworkSyncLimits.maxReceivedFileBytes
  public struct Entry: Codable, Equatable, Sendable {
    public let cover: WatchArtworkCover
    public let imageData: Data
    public init(cover: WatchArtworkCover, imageData: Data) {
      self.cover = cover
      self.imageData = imageData
    }
  }
  public let version: Int
  public let accountStamp: WatchAccountStamp
  public let wantListID: UUID
  public let entries: [Entry]
  public let unavailable: [WatchArtworkCover]
  public let isFinal: Bool

  public init(
    answering wantList: WatchArtworkWantList, entries: [Entry], unavailable: [WatchArtworkCover], isFinal: Bool
  ) throws {
    version = WatchProtocolVersion.current
    accountStamp = wantList.accountStamp
    wantListID = wantList.id
    self.entries = entries
    self.unavailable = unavailable
    self.isFinal = isFinal
    try validate()
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else { throw WatchProtocolCodingError.unsupportedVersion(version) }
    try accountStamp.validate()
    try WatchArtworkCover.validate(entries.map(\.cover), limit: WatchArtworkSyncLimits.maxWantedCovers)
    try WatchArtworkCover.validate(unavailable, limit: WatchArtworkSyncLimits.maxWantedCovers)
    var total = 0
    for entry in entries {
      guard !entry.imageData.isEmpty else { throw WatchProtocolCodingError.invalidValue }
      guard entry.imageData.count <= WatchArtworkReply.maxImageBytes else { throw WatchProtocolCodingError.tooLarge }
      total += entry.imageData.count
    }
    guard total <= WatchArtworkSyncLimits.maxBundleImageBytes else { throw WatchProtocolCodingError.tooLarge }
  }
}

extension WatchArtworkCover {
  static func validate(_ covers: [WatchArtworkCover], limit: Int) throws {
    guard covers.count <= limit else { throw WatchProtocolCodingError.tooLarge }
    guard Set(covers).count == covers.count else { throw WatchProtocolCodingError.invalidValue }
    for cover in covers { try cover.reference.validate() }
  }
}
