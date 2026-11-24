/// A source-qualified item identity. Keeping the source as a case prevents an RSS identity from
/// being mistaken for an Audiobookshelf item merely because both are strings on the wire.
public enum WatchSelection: Codable, Sendable, Equatable, Hashable {
  case audiobookshelf(itemID: String, episodeID: String?)
  case nativeFeed(feedID: String, episodeID: String)

  private enum CodingKeys: String, CodingKey { case source, itemID, feedID, episodeID }
  private enum Source: String, Codable { case audiobookshelf, nativeFeed }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let source = try container.decode(Source.self, forKey: .source)
    switch source {
    case .audiobookshelf:
      let itemID = try container.decode(String.self, forKey: .itemID)
      let episodeID = try container.decodeIfPresent(String.self, forKey: .episodeID)
      guard Self.isSafeID(itemID), episodeID.map(Self.isSafeID) ?? true else {
        throw WatchProtocolCodingError.invalidSelection
      }
      self = .audiobookshelf(itemID: itemID, episodeID: episodeID)
    case .nativeFeed:
      let feedID = try container.decode(String.self, forKey: .feedID)
      let episodeID = try container.decode(String.self, forKey: .episodeID)
      guard Self.isSafeID(feedID), Self.isSafeID(episodeID) else {
        throw WatchProtocolCodingError.invalidSelection
      }
      self = .nativeFeed(feedID: feedID, episodeID: episodeID)
    }
  }

  public func encode(to encoder: Encoder) throws {
    try validate()
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .audiobookshelf(let itemID, let episodeID):
      try container.encode(Source.audiobookshelf, forKey: .source)
      try container.encode(itemID, forKey: .itemID)
      try container.encodeIfPresent(episodeID, forKey: .episodeID)
    case .nativeFeed(let feedID, let episodeID):
      try container.encode(Source.nativeFeed, forKey: .source)
      try container.encode(feedID, forKey: .feedID)
      try container.encode(episodeID, forKey: .episodeID)
    }
  }

  private static func isSafeID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= WatchProtocolVersion.maxMetadataStringBytes
      && !value.contains("://") && !value.lowercased().hasPrefix("file:")
      && !value.hasPrefix("/") && !WatchProtocolValidation.containsControlCharacter(value)
  }

  public func validate() throws {
    switch self {
    case .audiobookshelf(let itemID, let episodeID):
      guard Self.isSafeID(itemID), episodeID.map(Self.isSafeID) ?? true else {
        throw WatchProtocolCodingError.invalidSelection
      }
    case .nativeFeed(let feedID, let episodeID):
      guard Self.isSafeID(feedID), Self.isSafeID(episodeID) else {
        throw WatchProtocolCodingError.invalidSelection
      }
    }
  }
}
