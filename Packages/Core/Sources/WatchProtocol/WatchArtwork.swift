import Foundation

/// Covers belong to a book or show, so episodes share their parent's identity.
/// No server address or credential crosses this boundary. Unversioned peers revalidate by age.
public struct WatchArtworkReference: Codable, Hashable, Sendable {
  public let source: WatchBrowseShowIdentity
  public let revision: String
  /// The revision of a cover the phone has never dated; such a cover is refreshed by age.
  public static let unversioned = "unversioned"

  public init(selection: WatchSelection, revision: String = WatchArtworkReference.unversioned) {
    switch selection {
    case .audiobookshelf(let id, _): source = .audiobookshelf(itemID: id)
    case .nativeFeed(let id, _): source = .nativeFeed(feedID: id)
    }
    self.revision = revision
  }

  public init(source: WatchBrowseShowIdentity, revision: String = WatchArtworkReference.unversioned) {
    self.source = source
    self.revision = revision
  }

  public func validate() throws {
    switch source {
    case .audiobookshelf(let id): try WatchSelection.audiobookshelf(itemID: id, episodeID: nil).validate()
    case .nativeFeed(let id): try WatchSelection.nativeFeed(feedID: id, episodeID: "cover").validate()
    }
    try Self.validate(revision: revision)
  }

  /// A revision is an opaque cache token from the phone: never a URL, never unbounded.
  static func validate(revision: String) throws {
    guard !revision.isEmpty, revision.utf8.count <= 128,
      !revision.contains("://"), !revision.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw WatchProtocolCodingError.invalidValue }
  }
}

public enum WatchArtworkSize: String, Codable, Hashable, Sendable {
  case row, player
  public var pixelWidth: Int { self == .row ? 96 : 320 }
}

public struct WatchArtworkRequest: WatchWireValue, Equatable, Hashable {
  public static let maxWireBytes = 8 * 1024
  public let version: Int
  public let id: UUID
  public let accountStamp: WatchAccountStamp
  public let reference: WatchArtworkReference
  public let size: WatchArtworkSize

  public init(accountStamp: WatchAccountStamp, reference: WatchArtworkReference, size: WatchArtworkSize) {
    version = WatchProtocolVersion.current
    id = UUID()
    self.accountStamp = accountStamp
    self.reference = reference
    self.size = size
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else { throw WatchProtocolCodingError.unsupportedVersion(version) }
    try accountStamp.validate()
    try reference.validate()
  }
}

public struct WatchArtworkReply: WatchWireValue, Equatable {
  public static let maxWireBytes = 60 * 1024
  public static let maxImageBytes = 40 * 1024
  public let version: Int
  public let requestID: UUID
  public let accountStamp: WatchAccountStamp
  public let reference: WatchArtworkReference
  public let size: WatchArtworkSize
  public let imageData: Data?

  public init(request: WatchArtworkRequest, imageData: Data?) {
    version = WatchProtocolVersion.current
    requestID = request.id
    accountStamp = request.accountStamp
    reference = request.reference
    size = request.size
    self.imageData = imageData
  }

  public func matches(_ request: WatchArtworkRequest) -> Bool {
    requestID == request.id && accountStamp == request.accountStamp
      && reference == request.reference && size == request.size
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else { throw WatchProtocolCodingError.unsupportedVersion(version) }
    try accountStamp.validate()
    try reference.validate()
    guard (imageData?.count ?? 0) <= Self.maxImageBytes else { throw WatchProtocolCodingError.tooLarge }
  }
}
