import Foundation

public enum FeedCredentialError: Error, Sendable, Equatable {
  case invalidAuthorization
  case invalidBasicUsername
}

/// One validated Authorization field for a private RSS feed. A sibling of `CustomHeaders`,
/// not an escape hatch through it: server proxy headers still reject Authorization, while feed
/// requests may stamp this one field at request-mint time.
public struct FeedCredential: Sendable, Equatable, Codable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let authorization: String
  /// Stable non-secret identity for request coalescing and invalidation. Never use this as proof
  /// of authenticity; it only prevents differently authorized requests from sharing a flight.
  public let fingerprint: String

  public var headerFields: [String: String] { ["Authorization": authorization] }

  public init(authorization: String) throws {
    guard HTTPHeaderFieldValidation.isValue(authorization) else {
      throw FeedCredentialError.invalidAuthorization
    }
    self.authorization = authorization
    fingerprint = HTTPFingerprint.sha256Hex(Data(authorization.utf8))
  }

  /// RFC 7617 Basic credentials. A colon in the username is ambiguous because the first colon is
  /// the user/password delimiter; the password may contain colons and either value may contain
  /// UTF-8 before the complete pair is base64 encoded into an RFC-7230-safe field value.
  public static func basic(username: String, password: String) throws -> FeedCredential {
    guard username.contains(":") == false else {
      throw FeedCredentialError.invalidBasicUsername
    }
    let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
    return try FeedCredential(authorization: "Basic \(encoded)")
  }

  public var description: String { "FeedCredential(authorization: <redacted>)" }
  public var debugDescription: String { description }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    try self.init(authorization: container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(authorization)
  }
}

public enum FeedCredentialStoreError: Error, Sendable, Equatable {
  case invalidFeedIdentity
  case malformedStoredCredential
}

/// Device-owned credential persistence keyed by the durable positive `rssFeed.id` identity.
public protocol FeedCredentialStoring: Sendable {
  func save(_ credential: FeedCredential, forFeedID feedID: Int64) throws
  func load(forFeedID feedID: Int64) throws -> FeedCredential?
  func clear(forFeedID feedID: Int64) throws
}

public final class InMemoryFeedCredentialStore: FeedCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [Int64: FeedCredential] = [:]

  public init() {}

  public func save(_ credential: FeedCredential, forFeedID feedID: Int64) throws {
    try Self.validate(feedID)
    lock.withLock { values[feedID] = credential }
  }

  public func load(forFeedID feedID: Int64) throws -> FeedCredential? {
    try Self.validate(feedID)
    return lock.withLock { values[feedID] }
  }

  public func clear(forFeedID feedID: Int64) throws {
    try Self.validate(feedID)
    lock.withLock { _ = values.removeValue(forKey: feedID) }
  }

  fileprivate static func validate(_ feedID: Int64) throws {
    guard feedID > 0 else { throw FeedCredentialStoreError.invalidFeedIdentity }
  }
}

#if canImport(Security)
  import Security

  /// Feed-only Keychain namespace. It does not share the ABS token or custom-header
  /// services, so account logout and token refresh cannot enumerate or mutate feed credentials.
  public final class KeychainFeedCredentialStore: FeedCredentialStoring, @unchecked Sendable {
    private let serviceNamespace: String
    private let client: SecItemClient
    private let lock = NSLock()

    public init(
      serviceNamespace: String = "com.remoteconcern.whirr.feed-credentials",
      client: SecItemClient = SecuritySecItemClient()
    ) throws {
      guard serviceNamespace.isEmpty == false else {
        throw FeedCredentialStoreError.invalidFeedIdentity
      }
      self.serviceNamespace = serviceNamespace
      self.client = client
    }

    public func save(_ credential: FeedCredential, forFeedID feedID: Int64) throws {
      let query = try makeQuery(feedID)
      guard let data = try? JSONEncoder().encode(credential) else {
        throw FeedCredentialStoreError.malformedStoredCredential
      }
      let attributes = KeychainItemAttributes(
        service: serviceNamespace, account: query.account, data: data)
      lock.lock()
      defer { lock.unlock() }
      do {
        try client.update(attributes, for: query)
      } catch KeychainStoreError.itemNotFound {
        do {
          try client.add(attributes, for: query)
        } catch KeychainStoreError.itemAlreadyExists {
          try client.update(attributes, for: query)
        }
      }
    }

    public func load(forFeedID feedID: Int64) throws -> FeedCredential? {
      let query = try makeQuery(feedID)
      lock.lock()
      defer { lock.unlock() }
      guard let data = try client.copyData(for: query) else { return nil }
      guard let credential = try? JSONDecoder().decode(FeedCredential.self, from: data) else {
        throw FeedCredentialStoreError.malformedStoredCredential
      }
      return credential
    }

    public func clear(forFeedID feedID: Int64) throws {
      let query = try makeQuery(feedID)
      lock.lock()
      defer { lock.unlock() }
      try client.delete(for: query)
    }

    private func makeQuery(_ feedID: Int64) throws -> KeychainItemQuery {
      try InMemoryFeedCredentialStore.validate(feedID)
      return KeychainItemQuery(service: serviceNamespace, account: "feed:\(feedID)")
    }
  }
#endif

/// Where a `FeedCredential` may travel. A feed names its own enclosures, artwork and streams, so
/// "the feed asked for it" is no evidence a URL belongs to its owner; only the origin is. The
/// credential goes to the feed's exact origin and nowhere else, on the first request and on any
/// redirect.
///
/// Lives here because every layer minting a credentialed feed request depends on `ABSApi`:
/// `PodcastFeeds`, `SyncEngine` (enclosure downloads), `AppModel` (playback streams).
/// `FeedRedirectPolicy` shares `sameOrigin` and refuses userinfo-bearing targets the same way.
public enum FeedCredentialOrigin {
  /// Exact origin equality: same scheme, same host, same effective port. Case-insensitive on the
  /// two case-insensitive components, and `nil` for anything without both.
  public static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    guard let lhsScheme = lhs.scheme?.lowercased(), let rhsScheme = rhs.scheme?.lowercased(),
      let lhsHost = lhs.host?.lowercased(), let rhsHost = rhs.host?.lowercased(),
      lhsHost == rhsHost, lhsScheme == rhsScheme,
      effectivePort(of: lhs) == effectivePort(of: rhs)
    else { return false }
    return true
  }

  /// Fail-closed admission for stamping a feed's credential onto `target`. Beyond exact origin it
  /// requires an http(s) target and refuses embedded userinfo on either URL, so a credential can
  /// never ride alongside a second set the app did not mint.
  public static func carriesCredential(feedURL: URL, target: URL) -> Bool {
    guard let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
      feedURL.user == nil, feedURL.password == nil, target.user == nil, target.password == nil
    else { return false }
    return sameOrigin(feedURL, target)
  }

  public static func effectivePort(of url: URL) -> Int? {
    if let port = url.port { return port }
    switch url.scheme?.lowercased() {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
  }
}
