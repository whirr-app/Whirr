import Foundation

public struct TokenPair: Codable, Sendable, Equatable {
  public let accessToken: String
  public let refreshToken: String?
  public let accessExpiry: Date?

  public init(accessToken: String, refreshToken: String?) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.accessExpiry = Self.parseAccessExpiry(from: accessToken)
  }

  public init(accessToken: String, refreshToken: String) {
    self.init(accessToken: accessToken, refreshToken: String?(refreshToken))
  }

  public init(accessToken: String, refreshToken: String?, accessExpiry: Date?) {
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.accessExpiry = accessExpiry
  }

  public init(accessToken: String, refreshToken: String, accessExpiry: Date?) {
    self.init(
      accessToken: accessToken,
      refreshToken: String?(refreshToken),
      accessExpiry: accessExpiry
    )
  }

  private static func parseAccessExpiry(from token: String) -> Date? {
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3 else { return nil }

    var payload = String(segments[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
    guard let data = Data(base64Encoded: payload) else { return nil }

    struct Claims: Decodable {
      let exp: Double?
    }

    guard let claims = try? JSONDecoder().decode(Claims.self, from: data),
      let expiry = claims.exp,
      expiry.isFinite
    else { return nil }
    return Date(timeIntervalSince1970: expiry)
  }
}

public enum TokenStoreError: Error, Sendable, Equatable {
  case invalidAccount
  case malformedStoredTokens
}

/// Declared outside the `canImport(Security)` section. It carries only an `OSStatus` as a plain
/// `Int32`, and callers above ABSApi classify Keychain failures with it
/// (`SyncEngine.AccountLifecycleService` turns one into the user's recovery message). Behind the
/// guard, every call site would need conditional compilation.
public enum KeychainStoreError: Error, Sendable, Equatable {
  case itemNotFound
  case itemAlreadyExists
  case malformedData
  case keychainFailure(status: Int32)

  /// `errSecMissingEntitlement`. Spelled as a literal so this type stays Security-free; the
  /// constant it must equal is asserted in `TokenStoreTests`.
  public static let missingEntitlementStatus: Int32 = -34018

  /// True only for `errSecMissingEntitlement`: the build cannot reach its Keychain access group
  /// (missing entitlement, or a provisioning profile that does not grant it). Retrying never
  /// succeeds and the user can do nothing, so it needs its own recovery message.
  public var isMissingEntitlement: Bool {
    guard case .keychainFailure(let status) = self else { return false }
    return status == Self.missingEntitlementStatus
  }
}

/// An opaque credential namespace and user id form the complete token namespace. A normalized URL
/// is also a legal value, but only for a login-session account or for reading a legacy item.
public struct TokenAccount: Sendable, Hashable, Equatable {
  /// Opaque credential namespace; a normalized URL is used only by legacy and login-session
  /// accounts.
  public let serverIdentity: String
  public let userID: String
  /// The normalized server URL for a URL-keyed account, `nil` for a namespace account. Proxy
  /// headers are keyed by URL, so a namespace account owns none and clearing by account does
  /// nothing for them; the account lifecycle clears each endpoint's headers by URL.
  public let serverURL: URL?

  /// Creates an account in the stable, server-independent credential namespace.
  public init(credentialNamespace: String, userID: String) throws {
    guard credentialNamespace.isEmpty == false, userID.isEmpty == false else {
      throw TokenStoreError.invalidAccount
    }
    serverIdentity = credentialNamespace
    self.userID = userID
    serverURL = nil
  }

  public init(serverURL: URL, userID: String) throws {
    guard userID.isEmpty == false else { throw TokenStoreError.invalidAccount }
    let identity = try Self.normalizedServerIdentity(from: serverURL)
    guard let normalized = URL(string: identity) else { throw TokenStoreError.invalidAccount }
    serverIdentity = identity
    self.userID = userID
    self.serverURL = normalized
  }

  public init(server: ABSServerConfig, userID: String) throws {
    try self.init(serverURL: server.baseURL, userID: userID)
  }

  /// A single Keychain account attribute with an unambiguous separator.
  public var keychainAccount: String { "\(serverIdentity)|\(userID)" }

  /// The server-only Keychain namespace shared by token and custom-header storage. One
  /// normalization keeps a spelling change from orphaning one credential class.
  public static func normalizedServerIdentity(from url: URL) throws -> String {
    let config = try ABSServerConfig(url: url)
    guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false),
      let scheme = components.scheme,
      let host = components.host
    else { throw TokenStoreError.invalidAccount }

    components.scheme = scheme.lowercased()
    components.host = host.lowercased()
    if (scheme.caseInsensitiveCompare("https") == .orderedSame && components.port == 443)
      || (scheme.caseInsensitiveCompare("http") == .orderedSame && components.port == 80)
    {
      components.port = nil
    }
    components.percentEncodedPath = config.pathPrefix
    components.query = nil
    components.fragment = nil
    guard let normalized = components.url else { throw TokenStoreError.invalidAccount }
    return normalized.absoluteString
  }
}

public protocol TokenStoring: Sendable {
  func save(_ tokens: TokenPair, for account: TokenAccount) throws
  func load(for account: TokenAccount) throws -> TokenPair?
  func clear(for account: TokenAccount) throws
}

public final class InMemoryTokenStore: TokenStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [TokenAccount: TokenPair] = [:]

  public init() {}

  public func save(_ tokens: TokenPair, for account: TokenAccount) throws {
    lock.lock()
    values[account] = tokens
    lock.unlock()
  }

  public func load(for account: TokenAccount) throws -> TokenPair? {
    lock.lock()
    let value = values[account]
    lock.unlock()
    return value
  }

  public func clear(for account: TokenAccount) throws {
    lock.lock()
    values.removeValue(forKey: account)
    lock.unlock()
  }
}

#if canImport(Security)
  import Security

  public enum KeychainAccessibility: Sendable, Equatable {
    case afterFirstUnlockThisDeviceOnly
  }

  public struct KeychainItemQuery: Sendable, Equatable {
    public let service: String
    public let account: String
    public let synchronizable: Bool?

    public init(service: String, account: String, synchronizable: Bool? = nil) {
      self.service = service
      self.account = account
      self.synchronizable = synchronizable
    }

    public var key: String { "\(service)\u{1f}\(account)" }
  }

  /// Carries no `synchronizable`/`backup` knobs. SECURITY.md allows no per-item choice: iCloud sync
  /// is always off and backup posture follows from the accessibility class (there is no Keychain
  /// "backup" attribute). The policy is hardcoded in the queries below and asserted against them.
  public struct KeychainItemAttributes: Sendable, Equatable {
    public let service: String
    public let account: String
    public let data: Data
    public let accessibility: KeychainAccessibility

    public init(
      service: String,
      account: String,
      data: Data,
      accessibility: KeychainAccessibility = .afterFirstUnlockThisDeviceOnly
    ) {
      self.service = service
      self.account = account
      self.data = data
      self.accessibility = accessibility
    }
  }

  public protocol SecItemClient: Sendable {
    func add(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws
    func update(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws
    func copyData(for query: KeychainItemQuery) throws -> Data?
    func delete(for query: KeychainItemQuery) throws
  }

  public final class KeychainTokenStore: TokenStoring, @unchecked Sendable {
    private let serviceNamespace: String
    private let client: SecItemClient
    private let lock = NSLock()

    public init(
      serviceNamespace: String = "com.remoteconcern.whirr.tokens",
      client: SecItemClient = SecuritySecItemClient()
    ) throws {
      guard serviceNamespace.isEmpty == false else { throw TokenStoreError.invalidAccount }
      self.serviceNamespace = serviceNamespace
      self.client = client
    }

    public func save(_ tokens: TokenPair, for account: TokenAccount) throws {
      let query = makeQuery(for: account)
      let attributes = try makeAttributes(tokens, for: account)

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

    public func load(for account: TokenAccount) throws -> TokenPair? {
      lock.lock()
      defer { lock.unlock() }
      guard let data = try client.copyData(for: makeQuery(for: account)) else { return nil }
      guard let tokens = try? JSONDecoder().decode(TokenPair.self, from: data) else {
        throw KeychainStoreError.malformedData
      }
      return tokens
    }

    public func clear(for account: TokenAccount) throws {
      lock.lock()
      defer { lock.unlock() }
      try client.delete(for: makeQuery(for: account))
    }

    private func makeQuery(for account: TokenAccount) -> KeychainItemQuery {
      KeychainItemQuery(service: serviceNamespace, account: account.keychainAccount)
    }

    private func makeAttributes(_ tokens: TokenPair, for account: TokenAccount) throws -> KeychainItemAttributes {
      guard let data = try? JSONEncoder().encode(tokens) else {
        throw TokenStoreError.malformedStoredTokens
      }
      return KeychainItemAttributes(
        service: serviceNamespace,
        account: account.keychainAccount,
        data: data
      )
    }
  }

  public final class SecuritySecItemClient: SecItemClient, @unchecked Sendable {
    public init() {}

    public func add(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws {
      let status = SecItemAdd(Self.addQuery(attributes, query: query) as CFDictionary, nil)
      try throwIfFailure(status)
    }

    public func update(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws {
      let status = SecItemUpdate(
        Self.lookupQuery(query) as CFDictionary,
        [
          kSecValueData: attributes.data,
          kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
          // The lookup matches synchronizable items too, so a legacy synced entry is migrated
          // back to device-only on the next save.
          kSecAttrSynchronizable: false,
        ] as CFDictionary
      )
      try throwIfFailure(status)
    }

    public func copyData(for query: KeychainItemQuery) throws -> Data? {
      var result: CFTypeRef?
      var matchingQuery = Self.lookupQuery(query)
      matchingQuery[kSecReturnData] = true
      matchingQuery[kSecMatchLimit] = kSecMatchLimitOne
      let status = SecItemCopyMatching(
        matchingQuery as CFDictionary,
        &result
      )
      if status == errSecItemNotFound { return nil }
      try throwIfFailure(status)
      return result as? Data
    }

    public func delete(for query: KeychainItemQuery) throws {
      let status = SecItemDelete(Self.lookupQuery(query) as CFDictionary)
      if status != errSecItemNotFound { try throwIfFailure(status) }
    }

    /// `static` and non-private only so `SecItemQueryTests` can assert on the dictionary that
    /// actually reaches the Keychain (a fake `SecItemClient` never builds one).
    static func addQuery(_ attributes: KeychainItemAttributes, query: KeychainItemQuery) -> [CFString: Any] {
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: query.service,
        kSecAttrAccount: query.account,
        kSecValueData: attributes.data,
        kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        // Explicit, not the platform default: SECURITY.md keeps tokens out of iCloud.
        kSecAttrSynchronizable: false,
      ]
    }

    static func lookupQuery(_ query: KeychainItemQuery) -> [CFString: Any] {
      [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: query.service,
        kSecAttrAccount: query.account,
        // `...Any`, not the implicit `false`: matching only non-synchronizable items would let a
        // synchronizable entry (from a migration or an older build) survive `clear(for:)`,
        // defeating SECURITY.md's "wipe Keychain entries".
        kSecAttrSynchronizable: kSecAttrSynchronizableAny,
      ]
    }

    private func throwIfFailure(_ status: OSStatus) throws {
      guard status != errSecSuccess else { return }
      if status == errSecItemNotFound { throw KeychainStoreError.itemNotFound }
      if status == errSecDuplicateItem { throw KeychainStoreError.itemAlreadyExists }
      throw KeychainStoreError.keychainFailure(status: status)
    }
  }
#endif
