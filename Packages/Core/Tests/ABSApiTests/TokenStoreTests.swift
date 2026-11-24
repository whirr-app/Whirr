import Foundation
import Testing

@testable import ABSApi

private let testServerURL = URL(string: "https://books.example.test/abs///")!

private func account(server: URL = testServerURL, userID: String = "user-a") throws -> TokenAccount {
  try TokenAccount(serverURL: server, userID: userID)
}

@Suite("Token store contract")
struct TokenStoreContractTests {
  @Test("namespace accounts round-trip and stay distinct from URL accounts")
  func credentialNamespaceAccountRoundTrips() throws {
    let store = InMemoryTokenStore()
    let namespaceAccount = try TokenAccount(credentialNamespace: "account:local", userID: "user-a")
    let urlAccount = try TokenAccount(serverURL: testServerURL, userID: "user-a")
    let tokens = TokenPair(accessToken: "access", refreshToken: "refresh")

    try store.save(tokens, for: namespaceAccount)

    #expect(try store.load(for: namespaceAccount) == tokens)
    #expect(try store.load(for: urlAccount) == nil)
    #expect(namespaceAccount != urlAccount)
  }

  @Test("namespace accounts reject empty namespaces")
  func emptyCredentialNamespaceThrows() {
    #expect(throws: TokenStoreError.invalidAccount) {
      _ = try TokenAccount(credentialNamespace: "", userID: "user-a")
    }
  }

  @Test("saves, loads, overwrites, and clears tokens atomically")
  func saveLoadOverwriteAndClear() throws {
    let store = InMemoryTokenStore()
    let account = try account()
    let first = TokenPair(
      accessToken: "access-one",
      refreshToken: "refresh-one",
      accessExpiry: Date(timeIntervalSince1970: 1_000)
    )
    let replacement = TokenPair(
      accessToken: "access-two",
      refreshToken: "refresh-two",
      accessExpiry: Date(timeIntervalSince1970: 2_000)
    )

    try store.save(first, for: account)
    #expect(try store.load(for: account) == first)

    try store.save(replacement, for: account)
    #expect(try store.load(for: account) == replacement)

    try store.clear(for: account)
    #expect(try store.load(for: account) == nil)
  }

  @Test("isolates tokens by normalized server identity and user id")
  func isolatesNamespaces() throws {
    let store = InMemoryTokenStore()
    let normalized = try account()
    let sameServerDifferentUser = try account(userID: "user-b")
    let differentServer = try account(server: URL(string: "https://other.example.test/abs")!)
    let tokens = TokenPair(accessToken: "access", refreshToken: "refresh")

    try store.save(tokens, for: normalized)

    #expect(try store.load(for: sameServerDifferentUser) == nil)
    #expect(try store.load(for: differentServer) == nil)
    #expect(normalized.serverIdentity == "https://books.example.test/abs")
    #expect(normalized == (try account(server: URL(string: "HTTPS://BOOKS.EXAMPLE.TEST/abs")!)))
  }

  @Test("parses a JWT access expiry without treating it as trust validation")
  func parsesAccessExpiry() throws {
    let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
    let payload = Data(#"{"exp":1700000000,"userId":"user-a"}"#.utf8)
    let token = [header, payload].map(base64URLEncoded).joined(separator: ".") + ".signature"

    let pair = TokenPair(accessToken: token, refreshToken: "refresh")

    #expect(pair.accessExpiry == Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test("uses a nil expiry for a malformed or non-JWT access token")
  func malformedAccessExpiryIsNil() {
    #expect(TokenPair(accessToken: "not-a-jwt", refreshToken: "refresh").accessExpiry == nil)
  }

  @Test("decodes and re-encodes a payload written before refresh tokens became optional")
  func decodesLegacyTokenPairPayload() throws {
    let legacyPayload = Data(
      #"{"accessToken":"legacy-access","refreshToken":"legacy-refresh"}"#.utf8)

    let decoded = try JSONDecoder().decode(TokenPair.self, from: legacyPayload)
    #expect(
      decoded
        == TokenPair(
          accessToken: "legacy-access", refreshToken: "legacy-refresh", accessExpiry: nil))

    let roundTripped = try JSONDecoder().decode(TokenPair.self, from: JSONEncoder().encode(decoded))
    #expect(roundTripped == decoded)
  }

  @Test("round-trips a no-refresh token without persisting a refresh-token field")
  func roundTripsNoRefreshToken() throws {
    let tokens = TokenPair(accessToken: "api-access", refreshToken: nil)

    let encoded = try JSONEncoder().encode(tokens)
    let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["refreshToken"] == nil)
    #expect(try JSONDecoder().decode(TokenPair.self, from: encoded) == tokens)
  }
}

@Suite("Custom header store contract")
struct CustomHeaderStoreContractTests {
  @Test("saves, loads, overwrites, and clears headers by normalized server identity")
  func saveLoadOverwriteAndClear() throws {
    let store = InMemoryCustomHeaderStore()
    let first = try CustomHeaders(["CF-Access-Client-Id": "client-one"])
    let replacement = try CustomHeaders(["CF-Access-Client-Secret": "secret-two"])
    let equivalentURL = URL(string: "HTTPS://BOOKS.EXAMPLE.TEST:443/abs///")!
    let differentServer = URL(string: "https://other.example.test/abs")!

    try store.save(first, for: testServerURL)
    #expect(try store.load(for: equivalentURL) == first)
    #expect(try store.load(for: differentServer) == nil)

    try store.save(replacement, for: equivalentURL)
    #expect(try store.load(for: testServerURL) == replacement)

    try store.clear(for: equivalentURL)
    #expect(try store.load(for: testServerURL) == nil)
  }
}

@Suite("Keychain token queries")
struct KeychainQueryTests {
  @Test("uses the account namespace and device-only accessibility")
  func buildsSecureQuery() throws {
    let client = RecordingSecItemClient()
    let store = try KeychainTokenStore(
      serviceNamespace: "test-service-namespace",
      client: client
    )
    let account = try account()
    let first = TokenPair(accessToken: "access", refreshToken: "refresh")
    let replacement = TokenPair(accessToken: "access-2", refreshToken: "refresh-2")

    try store.save(first, for: account)
    #expect(try store.load(for: account) == first)
    try store.save(replacement, for: account)
    #expect(try store.load(for: account) == replacement)
    try store.clear(for: account)
    #expect(try store.load(for: account) == nil)

    #expect(client.lastQuery?.service == "test-service-namespace")
    #expect(client.lastQuery?.account == account.keychainAccount)
    #expect(client.lastAdded?.accessibility == .afterFirstUnlockThisDeviceOnly)
  }
}

#if canImport(Security)
  import Security

  @Suite("Keychain status classification")
  struct KeychainStatusClassificationTests {
    /// `KeychainStoreError` has no `canImport(Security)` guard, so its -34018 literal is not
    /// type-checked against the platform constant anywhere else. This is that check.
    @Test("the published missing-entitlement status matches the platform's errSecMissingEntitlement")
    func missingEntitlementStatusMatchesThePlatformConstant() {
      #expect(KeychainStoreError.missingEntitlementStatus == errSecMissingEntitlement)
      #expect(KeychainStoreError.missingEntitlementStatus == -34018)
    }

    @Test("only the missing-entitlement status reports a build-level keychain denial")
    func onlyMissingEntitlementIsABuildLevelDenial() {
      #expect(KeychainStoreError.keychainFailure(status: errSecMissingEntitlement).isMissingEntitlement)
      #expect(KeychainStoreError.keychainFailure(status: errSecInteractionNotAllowed).isMissingEntitlement == false)
      #expect(KeychainStoreError.malformedData.isMissingEntitlement == false)
      #expect(KeychainStoreError.itemNotFound.isMissingEntitlement == false)
    }
  }

  @Suite("Keychain custom header queries")
  struct KeychainCustomHeaderQueryTests {
    @Test("uses only the normalized server namespace and the token store security policy")
    func buildsSecureServerScopedQuery() throws {
      let client = RecordingSecItemClient()
      let store = try KeychainCustomHeaderStore(
        serviceNamespace: "test-header-service-namespace",
        client: client
      )
      let headers = try CustomHeaders(["CF-Access-Client-Secret": "secret"])

      try store.save(headers, for: testServerURL)
      #expect(try store.load(for: testServerURL) == headers)

      #expect(client.lastQuery?.service == "test-header-service-namespace")
      #expect(client.lastQuery?.account == "https://books.example.test/abs")
      #expect(client.lastAdded?.accessibility == .afterFirstUnlockThisDeviceOnly)

      try store.clear(for: testServerURL)
      #expect(try store.load(for: testServerURL) == nil)
    }
  }

  @Suite("Keychain custom header SecItem dictionaries")
  struct CustomHeaderSecItemQueryTests {
    private static let query = KeychainItemQuery(service: "header-svc", account: "server-id")
    private static let attributes = KeychainItemAttributes(
      service: "header-svc", account: "server-id", data: Data("headers".utf8))

    @Test("pins device-only accessibility and refuses iCloud sync on add")
    func addQueryIsDeviceOnlyAndNotSynchronizable() {
      let query = SecuritySecItemClient.addQuery(Self.attributes, query: Self.query)

      #expect(
        (query[kSecAttrAccessible] as! CFString) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
      #expect(query[kSecAttrSynchronizable] as? Bool == false)
    }

    @Test("matches synchronizable items during lookup and deletion")
    func lookupQueryMatchesSynchronizableItems() {
      let query = SecuritySecItemClient.lookupQuery(Self.query)

      #expect((query[kSecAttrSynchronizable] as? String) == (kSecAttrSynchronizableAny as String))
      #expect(query[kSecAttrService] as? String == "header-svc")
      #expect(query[kSecAttrAccount] as? String == "server-id")
    }
  }
#endif

#if canImport(Security)
  import Security

  /// A fake client never builds a `SecItem` dictionary, so the suites above do not constrain the
  /// query that reaches the Keychain. These assert on the real dictionaries.
  @Suite("Keychain SecItem dictionaries")
  struct SecItemQueryTests {
    private static let query = KeychainItemQuery(service: "svc", account: "acct")
    private static let attributes = KeychainItemAttributes(
      service: "svc", account: "acct", data: Data("token".utf8)
    )

    @Test("SECURITY.md §5: the add query pins device-only accessibility and refuses iCloud sync")
    func addQueryIsDeviceOnlyAndNotSynchronizable() {
      let query = SecuritySecItemClient.addQuery(Self.attributes, query: Self.query)

      #expect(
        (query[kSecAttrAccessible] as! CFString) == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
      // Explicit `false`, not absent: the platform default would leave the policy unstated.
      #expect(query[kSecAttrSynchronizable] as? Bool == false)
    }

    @Test("SECURITY.md §8: the lookup query matches synchronizable items so a wipe cannot miss one")
    func lookupQueryMatchesSynchronizableItems() {
      let query = SecuritySecItemClient.lookupQuery(Self.query)

      // Without `...Any`, a lookup matches only non-synchronizable items, so a synchronizable
      // entry (from a migration or an older build) would survive `clear(for:)`.
      #expect((query[kSecAttrSynchronizable] as? String) == (kSecAttrSynchronizableAny as String))
      #expect(query[kSecAttrService] as? String == "svc")
      #expect(query[kSecAttrAccount] as? String == "acct")
    }
  }
#endif

#if canImport(Security)
  @Test(
    "persists through a Keychain store reconstruction and cleans up",
    .enabled(if: ProcessInfo.processInfo.environment["ABS_RUN_KEYCHAIN_INTEGRATION"] == "1")
  )
  func keychainIntegrationRoundTrip() throws {
    let serviceNamespace = "com.abs.integration.\(UUID().uuidString)"
    let account = try account()
    let tokens = TokenPair(accessToken: "integration-access", refreshToken: "integration-refresh")
    let store = try KeychainTokenStore(serviceNamespace: serviceNamespace)

    defer { try? store.clear(for: account) }
    try store.save(tokens, for: account)

    let reconstructedStore = try KeychainTokenStore(serviceNamespace: serviceNamespace)
    #expect(try reconstructedStore.load(for: account) == tokens)
  }
#endif

private func base64URLEncoded(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .trimmingCharacters(in: CharacterSet(charactersIn: "="))
}

private final class RecordingSecItemClient: SecItemClient, @unchecked Sendable {
  private let lock = NSLock()
  private var dataByKey: [String: Data] = [:]
  private var added: KeychainItemAttributes?
  private var query: KeychainItemQuery?

  var lastAdded: KeychainItemAttributes? {
    lock.lock()
    defer { lock.unlock() }
    return added
  }

  var lastQuery: KeychainItemQuery? {
    lock.lock()
    defer { lock.unlock() }
    return query
  }

  func add(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws {
    lock.lock()
    defer { lock.unlock() }
    guard dataByKey[query.key] == nil else { throw KeychainStoreError.itemAlreadyExists }
    dataByKey[query.key] = attributes.data
    added = attributes
    self.query = query
  }

  func update(_ attributes: KeychainItemAttributes, for query: KeychainItemQuery) throws {
    lock.lock()
    defer { lock.unlock() }
    guard dataByKey[query.key] != nil else { throw KeychainStoreError.itemNotFound }
    dataByKey[query.key] = attributes.data
    self.query = query
  }

  func copyData(for query: KeychainItemQuery) throws -> Data? {
    lock.lock()
    defer { lock.unlock() }
    return dataByKey[query.key]
  }

  func delete(for query: KeychainItemQuery) throws {
    lock.lock()
    defer { lock.unlock() }
    dataByKey.removeValue(forKey: query.key)
    self.query = query
  }
}
