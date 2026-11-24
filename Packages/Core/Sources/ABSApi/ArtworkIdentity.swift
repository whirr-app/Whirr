import Foundation

/// Prepared artwork is account/server scoped even though compressed cover responses remain
/// naturally server-scoped by their full URL.
public struct ArtworkAccountScope: Hashable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// A caller-supplied server artwork revision. `.unversioned` is the conservative compatibility
/// value for projections that do not yet expose a verified server revision.
public struct ArtworkRevision: Hashable, Sendable {
  public static let unversioned = ArtworkRevision("unversioned")

  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  /// An ABS cover's revision is its item's server `updatedAt`. The server's resized-cover cache
  /// never revalidates against the source file and sends no validators, so this is the only signal
  /// that a cover was replaced; a rescan that sees a modified cover file moves it. Epoch
  /// milliseconds match the `ts` the ABS web client sends for the same purpose.
  public init(serverUpdatedAt: Date?) {
    guard let serverUpdatedAt else {
      self = .unversioned
      return
    }
    self.init(String(Int64((serverUpdatedAt.timeIntervalSince1970 * 1000).rounded())))
  }
}

/// The stable request identity and bounded request context for one RSS artwork resource. Equality
/// and hashing use only ADR 0004's cache identity: feed identity plus normalised artwork URL.
/// `feedURL` is request context only, used to decide whether a future feed credential may
/// accompany the first hop. Changing it cannot mint a second artwork identity.
public struct RSSArtworkSource: Hashable, Sendable {
  public let feedIdentity: String
  public let normalizedArtworkURL: String
  public let feedURL: URL?

  public var artworkURL: URL { URL(string: normalizedArtworkURL)! }

  public init?(feedIdentity: String, artworkURL: URL, feedURL: URL? = nil) {
    guard feedIdentity.isEmpty == false,
      let normalizedArtworkURL = Self.normalizedHTTPURL(artworkURL)
    else { return nil }
    if let feedURL, Self.normalizedHTTPURL(feedURL) == nil { return nil }
    self.feedIdentity = feedIdentity
    self.normalizedArtworkURL = normalizedArtworkURL
    self.feedURL = feedURL
  }

  /// Constructs the canonical serialized identity for a subscribed RSS feed without importing
  /// Persistence. Keeping this formatting at the artwork boundary prevents numeric feed ids from
  /// becoming a second cache/authentication namespace (the canonical form is `rss:<feedID>`).
  public init?(feedID: Int64, artworkURL: URL, feedURL: URL? = nil) {
    guard feedID > 0 else { return nil }
    self.init(feedIdentity: "rss:\(feedID)", artworkURL: artworkURL, feedURL: feedURL)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.feedIdentity == rhs.feedIdentity
      && lhs.normalizedArtworkURL == rhs.normalizedArtworkURL
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(feedIdentity)
    hasher.combine(normalizedArtworkURL)
  }

  private static func normalizedHTTPURL(_ url: URL) -> String? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = components.host?.lowercased(), host.isEmpty == false,
      components.user == nil, components.password == nil
    else { return nil }
    components.scheme = scheme
    components.host = host
    if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
      components.port = nil
    }
    components.fragment = nil
    return components.url?.absoluteString
  }
}

public enum ArtworkSource: Hashable, Sendable {
  case audiobookshelf(ArtworkAccountScope)
  case rss(RSSArtworkSource)
  /// Local-only identity for an item that is known to have no admissible network artwork route.
  case generated(ArtworkAccountScope)

  /// Compatibility scope for the prepared-image and palette stores. RSS uses an explicit prefix,
  /// so an ABS server string equal to the feed/url tuple still cannot collide cross-provider.
  public var cacheScope: ArtworkAccountScope {
    switch self {
    case .audiobookshelf(let scope):
      scope
    case .rss(let source):
      ArtworkAccountScope(
        "artwork:rss|\(source.feedIdentity)|\(source.normalizedArtworkURL)")
    case .generated(let scope):
      scope
    }
  }
}

public enum ArtworkVariant: Hashable, Sendable {
  case libraryThumbnail(pixelWidth: Int)
  case homeCard(pixelWidth: Int)
  case highFidelity(pixelWidth: Int)
  /// The detail cover at the width its measured shape needs; see `DetailArtworkSizing`. Unlike
  /// `.highFidelity`, the width is requested exactly rather than rounded up to a shared step.
  case detailFit(pixelWidth: Int)

  public var pixelWidth: Int {
    switch self {
    case .libraryThumbnail(let pixelWidth), .homeCard(let pixelWidth),
      .highFidelity(let pixelWidth), .detailFit(let pixelWidth):
      pixelWidth
    }
  }

  public static func libraryThumbnail(displaySize: Double, displayScale: Double) -> Self {
    .libraryThumbnail(pixelWidth: exactPixelWidth(displaySize: displaySize, displayScale: displayScale))
  }

  public static func homeCard(displaySize: Double, displayScale: Double) -> Self {
    .homeCard(pixelWidth: exactPixelWidth(displaySize: displaySize, displayScale: displayScale))
  }

  public static func highFidelity(displaySize: Double, displayScale: Double) -> Self {
    .highFidelity(
      pixelWidth: CoverRequest.quantizedWidth(
        exactPixelWidth(displaySize: displaySize, displayScale: displayScale)))
  }

  private static func exactPixelWidth(displaySize: Double, displayScale: Double) -> Int {
    max(1, Int((displaySize * displayScale).rounded()))
  }
}

public struct ArtworkKey: Hashable, Sendable {
  public let source: ArtworkSource
  public var accountScope: ArtworkAccountScope { source.cacheScope }
  public let itemID: String
  public let variant: ArtworkVariant
  public let revision: ArtworkRevision

  public init(
    accountScope: ArtworkAccountScope,
    itemID: String,
    variant: ArtworkVariant,
    revision: ArtworkRevision
  ) {
    source = .audiobookshelf(accountScope)
    self.itemID = itemID
    self.variant = variant
    self.revision = revision
  }

  public init(
    source: ArtworkSource,
    itemID: String,
    variant: ArtworkVariant,
    revision: ArtworkRevision
  ) {
    self.source = source
    self.itemID = itemID
    self.variant = variant
    self.revision = revision
  }

  public func coverRequest(format: CoverImageFormat = .webp) throws -> CoverRequest {
    guard case .audiobookshelf = source else { throw ArtworkRoutingError.providerMismatch }
    if case .detailFit(let pixelWidth) = variant {
      return try CoverRequest(
        itemID: itemID, exactWidth: pixelWidth, revision: revision, format: format)
    }
    return try CoverRequest(itemID: itemID, width: variant.pixelWidth, revision: revision, format: format)
  }
}

public enum ArtworkPriority: Int, Sendable, Comparable {
  case scrollPrefetch
  case visible
  case playbackCritical

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public protocol ArtworkDataFetching: Sendable {
  func fetch(_ key: ArtworkKey) async throws -> CoverImageResult
}

/// Provider-neutral facade surface used by views, prefetch, palette, and Now Playing. Cache reads
/// remain cache-only; `needsRefresh` lets the image pipeline periodically revalidate RSS entries
/// without changing their identity. ABS entries are never revalidated.
public protocol ArtworkServing: ArtworkDataFetching {
  var defaultSource: ArtworkSource? { get }
  func data(for key: ArtworkKey) async -> Data?
  func needsRefresh(_ key: ArtworkKey) async -> Bool
}

public enum ArtworkRoutingError: Error, Sendable, Equatable {
  case providerMismatch
}

/// Routes by the key's provider identity. It owns no cache, reachability, credentials, or outage
/// state of its own, so the two injected clients remain fully isolated.
public struct ProviderArtworkClient: ArtworkServing, Sendable {
  private let abs: any ArtworkServing
  private let rss: any ArtworkServing

  public var defaultSource: ArtworkSource? { abs.defaultSource }

  public init(abs: any ArtworkServing, rss: any ArtworkServing) {
    self.abs = abs
    self.rss = rss
  }

  public func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    switch key.source {
    case .audiobookshelf: try await abs.fetch(key)
    case .rss: try await rss.fetch(key)
    case .generated: throw APIError.notFound
    }
  }

  public func data(for key: ArtworkKey) async -> Data? {
    switch key.source {
    case .audiobookshelf: await abs.data(for: key)
    case .rss: await rss.data(for: key)
    case .generated: nil
    }
  }

  public func needsRefresh(_ key: ArtworkKey) async -> Bool {
    switch key.source {
    case .audiobookshelf: await abs.needsRefresh(key)
    case .rss: await rss.needsRefresh(key)
    case .generated: false
    }
  }
}
