/// Identifies whether a podcast source comes from an ABS item or a device-owned RSS feed.
/// Its serialized item-id form exists only at boundaries such as deep-link tokens and artwork
/// keys; routing should use the validated identity instead. Reservation of the `rss:` namespace
/// against server-minted ids is enforced at sync ingest.
public struct PodcastSourceIdentity: Hashable, Sendable {
  /// Exhaustive projection of an already-validated identity. Callers cannot turn an arbitrary
  /// projection into an identity without passing through the failable factories below.
  public enum Source: Hashable, Sendable {
    case abs(itemId: String)
    case rss(feedId: Int64)
  }

  private let storage: Source

  /// The reserved item-id namespace for RSS-native shows.
  public static let reservedPrefix = "rss:"

  /// Validated construction for a server-owned item identity. Empty ids and every case variant of
  /// the device-owned namespace fail closed.
  public static func abs(itemId: String) -> Self? {
    guard itemId.isEmpty == false, hasReservedPrefix(itemId) == false else { return nil }
    return Self(storage: .abs(itemId: itemId))
  }

  /// Validated construction for a device-owned feed identity. SQLite row ids are positive, and a
  /// non-positive value has no canonical serialized form.
  public static func rss(feedId: Int64) -> Self? {
    guard feedId > 0 else { return nil }
    return Self(storage: .rss(feedId: feedId))
  }

  /// True when `id` carries the reserved prefix, compared case-insensitively.
  /// Ingest guards use this broader check so `RSS:`/`Rss:` variants cannot slip past the
  /// reservation even though only lowercase `rss:` is a valid encoding.
  public static func hasReservedPrefix(_ id: String) -> Bool {
    id.lowercased().hasPrefix(Self.reservedPrefix)
  }

  /// Strict compatibility decode of the serialized item-id form already persisted in routes,
  /// queue identities, artwork keys, and bookmarks.
  ///
  /// Lowercase `rss:` plus canonical positive Int64 digits decodes to `.rss`. A malformed id with
  /// the reserved prefix, or an empty id, is rejected; all others decode to `.abs`.
  public init?(itemId: String) {
    if Self.hasReservedPrefix(itemId) {
      guard itemId.hasPrefix(Self.reservedPrefix) else { return nil }
      let digits = itemId.dropFirst(Self.reservedPrefix.count)
      guard
        digits.isEmpty == false,
        digits.first != "0",
        digits.allSatisfy({ $0.isASCII && $0.isNumber }),
        let feedId = Int64(digits),
        let identity = Self.rss(feedId: feedId)
      else { return nil }
      self = identity
      return
    }

    guard let identity = Self.abs(itemId: itemId) else { return nil }
    self = identity
  }

  /// Exhaustive routing projection of the private validated storage.
  public var source: Source { storage }

  public var rssFeedId: Int64? {
    guard case .rss(let feedId) = storage else { return nil }
    return feedId
  }

  public var absItemId: String? {
    guard case .abs(let itemId) = storage else { return nil }
    return itemId
  }

  /// The serialized compatibility form: ABS passes the id through; RSS encodes `rss:<feedId>`.
  public var itemId: String {
    switch storage {
    case .abs(let itemId): itemId
    case .rss(let feedId): "\(Self.reservedPrefix)\(feedId)"
    }
  }

  private init(storage: Source) {
    self.storage = storage
  }
}
