import Foundation

/// The two persisted podcast sources are kept distinct all the way across the phone/Watch
/// boundary.  A show has no episode id; episodes use `WatchSelection` below.
public enum WatchBrowseShowIdentity: Codable, Sendable, Equatable, Hashable {
  case audiobookshelf(itemID: String)
  case nativeFeed(feedID: String)

  private enum CodingKeys: String, CodingKey { case source, itemID, feedID }
  private enum Source: String, Codable { case audiobookshelf, nativeFeed }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(Source.self, forKey: .source) {
    case .audiobookshelf:
      let id = try c.decode(String.self, forKey: .itemID)
      guard Self.validID(id) else { throw WatchProtocolCodingError.invalidSelection }
      self = .audiobookshelf(itemID: id)
    case .nativeFeed:
      let id = try c.decode(String.self, forKey: .feedID)
      guard Self.validID(id) else { throw WatchProtocolCodingError.invalidSelection }
      self = .nativeFeed(feedID: id)
    }
  }

  public func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .audiobookshelf(let id):
      try c.encode(Source.audiobookshelf, forKey: .source)
      try c.encode(id, forKey: .itemID)
    case .nativeFeed(let id):
      try c.encode(Source.nativeFeed, forKey: .source)
      try c.encode(id, forKey: .feedID)
    }
  }

  public func validate() throws {
    switch self {
    case .audiobookshelf(let id), .nativeFeed(let id):
      guard Self.validID(id) else { throw WatchProtocolCodingError.invalidSelection }
    }
  }

  private static func validID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= WatchProtocolVersion.maxMetadataStringBytes
      && !value.contains("://") && !value.lowercased().hasPrefix("file:")
      && !value.hasPrefix("/")
      && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }
}

/// Which persisted podcast source a show or latest-episodes request covers. A request without one
/// covers both, which is what a Watch from before this field asks for.
public enum WatchBrowseSource: String, Codable, Sendable, Equatable {
  case audiobookshelf
  case nativeFeed

  public func contains(_ show: WatchBrowseShowIdentity) -> Bool {
    switch (self, show) {
    case (.audiobookshelf, .audiobookshelf), (.nativeFeed, .nativeFeed): true
    default: false
    }
  }
}

public enum WatchBrowseScope: Codable, Sendable, Equatable {
  case latestEpisodes
  case shows
  case episodes(show: WatchBrowseShowIdentity)

  private enum CodingKeys: String, CodingKey { case kind, show }
  private enum Kind: String, Codable { case latestEpisodes, shows, episodes }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(Kind.self, forKey: .kind) {
    case .latestEpisodes: self = .latestEpisodes
    case .shows: self = .shows
    case .episodes:
      self = .episodes(show: try c.decode(WatchBrowseShowIdentity.self, forKey: .show))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .latestEpisodes: try c.encode(Kind.latestEpisodes, forKey: .kind)
    case .shows: try c.encode(Kind.shows, forKey: .kind)
    case .episodes(let show):
      try show.validate()
      try c.encode(Kind.episodes, forKey: .kind)
      try c.encode(show, forKey: .show)
    }
  }
}

public enum WatchBrowseEpisodeSort: String, Codable, Sendable, Equatable { case newest, oldest }
public enum WatchBrowsePlayedFilter: String, Codable, Sendable, Equatable { case inProgress, unplayed, all }

public enum WatchBrowseLimits {
  public static let maxPageSize = 50
  public static let maxPage = 100_000
  public static let maxWireBytes = 48 * 1024
  public static let maxErrorMessageBytes = 256
}

public struct WatchBrowseRequest: WatchWireValue, Equatable, Identifiable {
  public static let maxWireBytes = WatchBrowseLimits.maxWireBytes
  public let version: Int
  public let id: UUID
  public let accountStamp: WatchAccountStamp
  public let scope: WatchBrowseScope
  public let page: Int
  public let pageSize: Int
  public let episodeSort: WatchBrowseEpisodeSort
  public let played: WatchBrowsePlayedFilter
  /// Narrows `.shows` and `.latestEpisodes` to one source; nil covers both. `.episodes(show:)`
  /// is already source-qualified and ignores it.
  public let source: WatchBrowseSource?
  /// The phone's monotonic browse generation. A nil value starts a new browse session; subsequent
  /// pages must echo the generation returned by the previous page.
  public let generation: UInt64?

  public init(
    accountStamp: WatchAccountStamp,
    scope: WatchBrowseScope,
    page: Int = 0,
    pageSize: Int = WatchBrowseLimits.maxPageSize,
    episodeSort: WatchBrowseEpisodeSort = .newest,
    played: WatchBrowsePlayedFilter = .all,
    generation: UInt64? = nil,
    source: WatchBrowseSource? = nil,
    id: UUID = UUID()
  ) throws {
    self.version = WatchProtocolVersion.current
    self.id = id
    self.accountStamp = accountStamp
    self.scope = scope
    self.page = page
    self.pageSize = pageSize
    self.episodeSort = episodeSort
    self.played = played
    self.source = source
    self.generation = generation
    try validate()
  }

  public func validate() throws {
    try accountStamp.validate()
    guard version == WatchProtocolVersion.current, page >= 0, page <= WatchBrowseLimits.maxPage,
      pageSize > 0, pageSize <= WatchBrowseLimits.maxPageSize
    else {
      throw WatchProtocolCodingError.invalidValue
    }
    if let generation, generation == 0 { throw WatchProtocolCodingError.invalidValue }
    if case .episodes(let show) = scope { try show.validate() }
  }
}

public struct WatchBrowseShowRow: Codable, Sendable, Equatable, Identifiable {
  public let id: WatchBrowseShowIdentity
  public let title: String
  public let author: String?
  public let latestPublishedAt: Date?
  /// The show's cover revision as the phone knows it; its episodes draw the same cover.
  public let artworkRevision: String?

  public init(
    id: WatchBrowseShowIdentity, title: String, author: String? = nil, latestPublishedAt: Date? = nil,
    artworkRevision: String? = nil
  ) throws {
    self.id = id
    self.title = title
    self.author = author
    self.latestPublishedAt = latestPublishedAt
    self.artworkRevision = artworkRevision
    try validate()
  }

  public func validate() throws {
    try id.validate()
    if let artworkRevision { try WatchArtworkReference.validate(revision: artworkRevision) }
    try WatchBrowseValidation.metadata(title)
    if let author { try WatchBrowseValidation.metadata(author) }
    if let date = latestPublishedAt, !date.timeIntervalSinceReferenceDate.isFinite {
      throw WatchProtocolCodingError.invalidValue
    }
  }
}

public struct WatchBrowseEpisodeRow: Codable, Sendable, Equatable, Identifiable {
  /// Typed identity avoids collisions when opaque ids contain separator characters.
  public var id: WatchSelection { selection }
  public let selection: WatchSelection
  public let show: WatchBrowseShowIdentity
  public let showTitle: String
  public let title: String
  public let publishedAt: Date?
  public let durationSeconds: Double?
  public let progressSeconds: Double
  public let isPlayed: Bool
  /// True only when the Watch can use an Audiobookshelf episode's server playback path. Native
  /// RSS episodes and phone-only downloaded episodes remain phone-owned and must be presented as
  /// such by the Watch UI. Missing on older replies, this decodes to false for safety.
  public let watchPlayable: Bool

  /// Phone availability is independent: a native feed or phone-only download can play on the
  /// phone while remaining unavailable to the Watch's own audio engine.
  public let phonePlayable: Bool

  private enum CodingKeys: String, CodingKey {
    case selection, show, showTitle, title, publishedAt, durationSeconds, progressSeconds, isPlayed,
      phonePlayable, watchPlayable
  }

  public init(
    selection: WatchSelection, show: WatchBrowseShowIdentity, showTitle: String, title: String,
    publishedAt: Date?, durationSeconds: Double?, progressSeconds: Double = 0,
    isPlayed: Bool, phonePlayable: Bool = true, watchPlayable: Bool = false
  ) throws {
    self.selection = selection
    self.show = show
    self.showTitle = showTitle
    self.title = title
    self.publishedAt = publishedAt
    self.durationSeconds = durationSeconds
    self.progressSeconds = progressSeconds
    self.isPlayed = isPlayed
    self.phonePlayable = phonePlayable
    self.watchPlayable = watchPlayable
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.selection = try c.decode(WatchSelection.self, forKey: .selection)
    self.show = try c.decode(WatchBrowseShowIdentity.self, forKey: .show)
    self.showTitle = try c.decode(String.self, forKey: .showTitle)
    self.title = try c.decode(String.self, forKey: .title)
    self.publishedAt = try c.decodeIfPresent(Date.self, forKey: .publishedAt)
    self.durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
    self.progressSeconds = try c.decodeIfPresent(Double.self, forKey: .progressSeconds) ?? 0
    self.isPlayed = try c.decodeIfPresent(Bool.self, forKey: .isPlayed) ?? false
    self.phonePlayable = try c.decodeIfPresent(Bool.self, forKey: .phonePlayable) ?? false
    self.watchPlayable = try c.decodeIfPresent(Bool.self, forKey: .watchPlayable) ?? false
    try validate()
  }

  public func encode(to encoder: Encoder) throws {
    try validate()
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(selection, forKey: .selection)
    try c.encode(show, forKey: .show)
    try c.encode(showTitle, forKey: .showTitle)
    try c.encode(title, forKey: .title)
    try c.encodeIfPresent(publishedAt, forKey: .publishedAt)
    try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
    try c.encode(progressSeconds, forKey: .progressSeconds)
    try c.encode(isPlayed, forKey: .isPlayed)
    try c.encode(phonePlayable, forKey: .phonePlayable)
    try c.encode(watchPlayable, forKey: .watchPlayable)
  }

  public func validate() throws {
    try selection.validate()
    try show.validate()
    try WatchBrowseValidation.metadata(showTitle)
    try WatchBrowseValidation.metadata(title)
    if let date = publishedAt, !date.timeIntervalSinceReferenceDate.isFinite {
      throw WatchProtocolCodingError.invalidValue
    }
    guard progressSeconds.isFinite, progressSeconds >= 0 else { throw WatchProtocolCodingError.invalidValue }
    if let durationSeconds {
      guard durationSeconds.isFinite, durationSeconds > 0, progressSeconds <= durationSeconds else {
        throw WatchProtocolCodingError.invalidValue
      }
    }
    if case .audiobookshelf(let itemID, let episodeID) = selection {
      guard episodeID != nil else { throw WatchProtocolCodingError.invalidSelection }
      guard case .audiobookshelf(let showID) = show, itemID == showID else {
        throw WatchProtocolCodingError.invalidSelection
      }
    } else if case .nativeFeed(let feedID, _) = selection, case .nativeFeed(let showID) = show {
      guard feedID == showID, watchPlayable == false else { throw WatchProtocolCodingError.invalidSelection }
    } else {
      throw WatchProtocolCodingError.invalidSelection
    }
  }
}

public enum WatchBrowseRow: Codable, Sendable, Equatable, Identifiable {
  case show(WatchBrowseShowRow)
  case episode(WatchBrowseEpisodeRow)

  private enum CodingKeys: String, CodingKey { case kind, show, episode }
  private enum Kind: String, Codable { case show, episode }

  public var id: String {
    switch self {
    case .show(let row): return WatchBrowseIdentityToken.show(row.id)
    case .episode(let row): return WatchBrowseIdentityToken.episode(row.id)
    }
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    switch try c.decode(Kind.self, forKey: .kind) {
    case .show: self = .show(try c.decode(WatchBrowseShowRow.self, forKey: .show))
    case .episode: self = .episode(try c.decode(WatchBrowseEpisodeRow.self, forKey: .episode))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .show(let row):
      try row.validate()
      try c.encode(Kind.show, forKey: .kind)
      try c.encode(row, forKey: .show)
    case .episode(let row):
      try row.validate()
      try c.encode(Kind.episode, forKey: .kind)
      try c.encode(row, forKey: .episode)
    }
  }
}

/// A page is heterogeneous, so its `Identifiable` projection must include both the row kind and
/// every opaque identity component. Length prefixes keep valid ids containing punctuation (or
/// one another as prefixes) unambiguous; `String(describing:)` and separator joins are not wire
/// identities.
private enum WatchBrowseIdentityToken {
  static func component(_ value: String) -> String { "\(value.utf8.count)#\(value)" }

  static func show(_ value: WatchBrowseShowIdentity) -> String {
    switch value {
    case .audiobookshelf(let itemID): return "show:a:" + component(itemID)
    case .nativeFeed(let feedID): return "show:r:" + component(feedID)
    }
  }

  static func episode(_ value: WatchSelection) -> String {
    switch value {
    case .audiobookshelf(let itemID, let episodeID):
      return "episode:a:" + component(itemID) + ":" + (episodeID.map(component) ?? "-")
    case .nativeFeed(let feedID, let episodeID):
      return "episode:r:" + component(feedID) + ":" + component(episodeID)
    }
  }
}

public struct WatchBrowsePage: WatchWireValue, Equatable {
  public static let maxWireBytes = WatchBrowseLimits.maxWireBytes
  public let page: Int
  public let pageSize: Int
  public let rows: [WatchBrowseRow]
  public let nextPage: Int?
  public let isComplete: Bool
  public let generation: UInt64

  public init(page: Int, pageSize: Int, rows: [WatchBrowseRow], nextPage: Int?, isComplete: Bool, generation: UInt64)
    throws
  {
    self.page = page
    self.pageSize = pageSize
    self.rows = rows
    self.nextPage = nextPage
    self.isComplete = isComplete
    self.generation = generation
    try validate()
  }

  public func validate() throws {
    guard page >= 0, page <= WatchBrowseLimits.maxPage, pageSize > 0, pageSize <= WatchBrowseLimits.maxPageSize,
      rows.count <= pageSize, generation > 0,
      nextPage.map({ $0 > page && $0 <= WatchBrowseLimits.maxPage }) ?? true,
      !(isComplete && nextPage != nil)
    else { throw WatchProtocolCodingError.invalidValue }
    for row in rows {
      switch row {
      case .show(let x): try x.validate()
      case .episode(let x): try x.validate()
      }
    }
    guard Set(rows.map(\.id)).count == rows.count else { throw WatchProtocolCodingError.invalidValue }
    let estimate = rows.reduce(128) { total, row in total + row.id.utf8.count + 512 }
    guard estimate <= WatchBrowseLimits.maxWireBytes else { throw WatchProtocolCodingError.tooLarge }
  }
}

public enum WatchBrowseErrorCode: String, Codable, Sendable, Equatable {
  case accountUnavailable = "account_unavailable"
  case phoneUnavailable = "phone_unavailable"
  case retryable = "retryable"
  case staleGeneration = "stale_generation"
  case invalidRequest = "invalid_request"
  case unsupportedScope = "unsupported_scope"
  case noData = "no_data"
}

public struct WatchBrowseError: Codable, Sendable, Equatable, Error {
  public let code: WatchBrowseErrorCode
  public let message: String
  public let retryable: Bool
  public let retryAfterSeconds: Int?

  public init(code: WatchBrowseErrorCode, message: String, retryable: Bool, retryAfterSeconds: Int? = nil) throws {
    guard message.utf8.count <= WatchBrowseLimits.maxErrorMessageBytes,
      !message.isEmpty, !message.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      retryAfterSeconds.map({ (0...300).contains($0) }) ?? true
    else { throw WatchProtocolCodingError.invalidValue }
    self.code = code
    self.message = message
    self.retryable = retryable
    self.retryAfterSeconds = retryAfterSeconds
  }

  public var actionableMessage: String { message }
}

public enum WatchBrowseReplyStatus: String, Codable, Sendable, Equatable {
  case accepted, unavailable, retryableError
}

public struct WatchBrowseReply: WatchWireValue, Equatable {
  public static let maxWireBytes = WatchBrowseLimits.maxWireBytes
  public let version: Int
  public let requestID: UUID
  public let accountStamp: WatchAccountStamp
  public let status: WatchBrowseReplyStatus
  public let page: WatchBrowsePage?
  public let error: WatchBrowseError?

  public init(
    request: WatchBrowseRequest, status: WatchBrowseReplyStatus, page: WatchBrowsePage? = nil,
    error: WatchBrowseError? = nil
  ) throws {
    self.version = WatchProtocolVersion.current
    self.requestID = request.id
    self.accountStamp = request.accountStamp
    self.status = status
    self.page = page
    self.error = error
    try validate()
  }

  public func validate() throws {
    try accountStamp.validate()
    guard version == WatchProtocolVersion.current else { throw WatchProtocolCodingError.unsupportedVersion(version) }
    guard (status == .accepted) == (page != nil), (status == .accepted) != (error != nil) else {
      throw WatchProtocolCodingError.invalidValue
    }
    if let page { try page.validate() }
    if let error {
      _ = try WatchBrowseError(
        code: error.code, message: error.message, retryable: error.retryable, retryAfterSeconds: error.retryAfterSeconds
      )
    }
  }
}

public enum WatchBrowseTransportKey {
  public static let request = WatchTransportKey.browseRequest
  public static let reply = WatchTransportKey.browseReply
}

private enum WatchBrowseValidation {
  static func metadata(_ value: String) throws {
    guard !value.isEmpty, value.utf8.count <= WatchProtocolVersion.maxMetadataStringBytes,
      !value.contains("://"), !value.lowercased().hasPrefix("file:"), !value.hasPrefix("/"),
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw WatchProtocolCodingError.invalidValue
    }
  }
}
