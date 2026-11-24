import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// `ABSClient.reauthenticate`, the atomic same-account token-replacement operation
/// (API-CONVENTIONS.md rule 4a). Distinct from the ordinary login/logout lifecycle in
/// `AuthenticationTests.swift` and the in-`AuthenticatedHTTPClient` rejection latch in
/// `RefreshTests.swift`.
@Suite("Same-account reauthentication", .timeLimit(.minutes(1)))
struct ReauthenticationTests {
  @Test("a successful same-account reauthentication replaces tokens and clears the latch")
  func sameAccountReauthenticationReplacesTokensAndClearsLatch() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.save(initialTokens, for: account)

    let transport = FakeHTTPClient(
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
      ]
    )
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    // Drive the cached per-account transport into the rejection latch first.
    await #expect(throws: APIError.unauthorized) {
      _ = try await client.authenticatedSend(
        makeItemsRequest(server: server),
        account: account,
        initialTokens: initialTokens
      )
    }

    transport.enqueue(
      try makeLoginResponse(userID: "user_fixture", accessToken: "new-access", refreshToken: "new-refresh")
    )

    let replaced = try await client.reauthenticate(
      credentials: LoginCredentials(username: "fixture-user", password: "fixture-password"),
      expectedAccount: account
    )

    #expect(replaced.accessToken == "new-access")
    #expect(try store.load(for: account)?.accessToken == "new-access")
    #expect(try store.load(for: account)?.refreshToken == "new-refresh")

    // The latch is clear and the cached transport now uses the replacement pair immediately.
    transport.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    let response = try await client.authenticatedSend(
      makeItemsRequest(server: server),
      account: account,
      initialTokens: initialTokens
    )
    #expect(response.statusCode == 200)
    #expect(transport.requests.last?.headers["Authorization"] == "Bearer new-access")
  }

  @Test("an API-token reauthentication replaces the no-refresh pair after the same-account check")
  func apiTokenReauthenticationReplacesTokens() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-api-token", refreshToken: nil)
    try store.save(initialTokens, for: account)
    let transport = FakeHTTPClient(
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 200, headers: [:], body: try Fixtures.data(named: "me-profile-response")),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      ]
    )
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.authenticatedSend(
        makeItemsRequest(server: server), account: account, initialTokens: initialTokens)
    }

    let credentials = APITokenCredentials(token: "new-api-token")
    let replaced = try await client.reauthenticate(apiToken: credentials, expectedAccount: account)

    #expect(credentials.isTokenReleased)
    #expect(replaced == TokenPair(accessToken: "new-api-token", refreshToken: nil))
    #expect(try store.load(for: account) == replaced)

    let response = try await client.authenticatedSend(
      makeItemsRequest(server: server), account: account, initialTokens: initialTokens)
    #expect(response.statusCode == 200)
    #expect(transport.requests.last?.headers["Authorization"] == "Bearer new-api-token")
  }

  @Test("an API-token reauthentication for a different user is a non-mutating mismatch")
  func differentUserAPITokenReauthenticationDoesNotMutate() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-api-token", refreshToken: nil)
    try store.save(initialTokens, for: account)
    let otherProfile: [String: Any] = [
      "id": "user_other",
      "username": "other-user",
      "type": "user",
      "isActive": true,
      "isLocked": false,
      "librariesAccessible": [String](),
      "permissions": [String: Any](),
    ]
    let otherProfileData = try JSONSerialization.data(withJSONObject: otherProfile)
    let transport = FakeHTTPClient(
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: otherProfileData)])
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)
    let credentials = APITokenCredentials(token: "other-api-token")

    await #expect(throws: ReauthenticationError.accountMismatch) {
      _ = try await client.reauthenticate(
        apiToken: credentials, expectedAccount: account)
    }

    #expect(credentials.isTokenReleased)
    #expect(try store.load(for: account) == initialTokens)
    // The token is the other user's own API key, not a session this attempt created, so it is
    // not this app's to revoke: no `/logout` follows the `/api/me` check.
    #expect(transport.requests.count == 1)
  }

  /// ABS creates a live session for whoever signed in before Whirr can check who that was. Nothing
  /// local keeps the refused pair, so the session is revoked rather than left valid on the server
  /// until its refresh token expires.
  @Test("a different returned user's new server session is revoked with its own refresh token")
  func differentUserReauthenticationRevokesTheReturnedSession() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.save(initialTokens, for: account)
    let transport = FakeHTTPClient(
      responses: [
        try makeLoginResponse(userID: "user_other", accessToken: "other-access", refreshToken: "other-refresh"),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      ]
    )
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    await #expect(throws: ReauthenticationError.accountMismatch) {
      _ = try await client.reauthenticate(
        credentials: LoginCredentials(username: "fixture-user", password: "fixture-password"),
        expectedAccount: account
      )
    }

    #expect(transport.requests.count == 2)
    let revocation = try #require(transport.requests.last)
    #expect(revocation.method == .post)
    #expect(revocation.routeTemplate == "/logout")
    #expect(revocation.headers["x-refresh-token"] == "other-refresh")
    #expect(revocation.headers["Authorization"] == nil)
    #expect(try store.load(for: account) == initialTokens)
  }

  @Test("a failed revocation still reports the mismatch and leaves the stored pair alone")
  func failedRevocationStillReportsTheMismatch() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.save(initialTokens, for: account)
    let transport = FakeHTTPClient(
      responses: [
        try makeLoginResponse(userID: "user_other", accessToken: "other-access", refreshToken: "other-refresh"),
        HTTPResponse(statusCode: 500, headers: [:], body: Data()),
      ]
    )
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    await #expect(throws: ReauthenticationError.accountMismatch) {
      _ = try await client.reauthenticate(
        credentials: LoginCredentials(username: "fixture-user", password: "fixture-password"),
        expectedAccount: account
      )
    }

    #expect(transport.requests.count == 2)
    #expect(try store.load(for: account) == initialTokens)
  }

  @Test("rejects a password reauthentication response without a non-empty refresh token")
  func reauthenticationRequiresRefreshToken() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.save(initialTokens, for: account)
    let transport = FakeHTTPClient(
      responses: [
        try makeLoginResponse(userID: "user_fixture", accessToken: "new-access", refreshToken: "")
      ]
    )
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    await #expect(throws: APIError.decoding) {
      _ = try await client.reauthenticate(
        credentials: LoginCredentials(username: "fixture-user", password: "fixture-password"),
        expectedAccount: account
      )
    }

    #expect(try store.load(for: account) == initialTokens)
  }

  @Test("a different returned user does not persist returned tokens or touch the cached transport")
  func differentUserReauthenticationDoesNotPersistReturnedTokens() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.save(initialTokens, for: account)

    let transport = FakeHTTPClient(
      responses: [
        HTTPResponse(statusCode: 200, headers: [:], body: Data())
      ]
    )
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    // Establish the cached authenticated transport for this account with the initial pair.
    let firstResponse = try await client.authenticatedSend(
      makeItemsRequest(server: server),
      account: account,
      initialTokens: initialTokens
    )
    #expect(firstResponse.statusCode == 200)

    transport.enqueue(
      try makeLoginResponse(userID: "user_other", accessToken: "other-access", refreshToken: "other-refresh")
    )

    await #expect(throws: ReauthenticationError.accountMismatch) {
      _ = try await client.reauthenticate(
        credentials: LoginCredentials(username: "fixture-user", password: "fixture-password"),
        expectedAccount: account
      )
    }

    #expect(try store.load(for: account) == initialTokens)

    // The cached transport's tokens are untouched: the next send still uses the original pair.
    transport.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    let secondResponse = try await client.authenticatedSend(
      makeItemsRequest(server: server),
      account: account,
      initialTokens: initialTokens
    )
    #expect(secondResponse.statusCode == 200)
    #expect(transport.requests.last?.headers["Authorization"] == "Bearer old-access")
  }

  @Test("a failed reauthentication leaves the original pair and latch untouched")
  func failedReauthenticationLeavesOriginalPairAndLatchUntouched() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.save(initialTokens, for: account)

    let transport = FakeHTTPClient(
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),  // /items
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),  // /auth/refresh -> latches
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),  // /login -> bad credentials
      ]
    )
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.authenticatedSend(
        makeItemsRequest(server: server),
        account: account,
        initialTokens: initialTokens
      )
    }

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.reauthenticate(
        credentials: LoginCredentials(username: "fixture-user", password: "wrong-password"),
        expectedAccount: account
      )
    }

    #expect(try store.load(for: account) == initialTokens)

    // Still latched: no further network traffic, and it keeps failing locally.
    await #expect(throws: APIError.unauthorized) {
      _ = try await client.authenticatedSend(
        makeItemsRequest(server: server),
        account: account,
        initialTokens: initialTokens
      )
    }
    #expect(transport.requests.count == 3)
  }

  @Test("concurrent waiters use the replacement pair only after the atomic token-store save completes")
  func concurrentWaitersUseReplacementPairOnlyAfterAtomicSave() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = BlockingSaveTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.seed(initialTokens, for: account)

    let transport = FakeHTTPClient(
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
      ]
    )
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    // Latch the account's cached transport with a definitive rejection.
    await #expect(throws: APIError.unauthorized) {
      _ = try await client.authenticatedSend(
        makeItemsRequest(server: server),
        account: account,
        initialTokens: initialTokens
      )
    }

    // Capture the cached per-account actor while `ABSClient`'s own actor is free, so it can be
    // probed once `reauthenticate()` below holds that actor inside a blocking token-store save.
    // Calling back into `ABSClient` then would deadlock: it could not be scheduled until the save
    // it waits to observe returns.
    let cachedTransport = try await client.authenticatedTransport(for: account, initialTokens: initialTokens)

    transport.enqueue(
      try makeLoginResponse(userID: "user_fixture", accessToken: "new-access", refreshToken: "new-refresh")
    )
    store.arm()

    let reauth = Task {
      try await client.reauthenticate(
        credentials: LoginCredentials(username: "fixture-user", password: "fixture-password"),
        expectedAccount: account
      )
    }

    #expect(await waitUntil { store.saveStarted })
    let requestsBeforeLatchCheck = transport.requests.count

    // While the save is still blocked, the latch has not been cleared: the cached transport still
    // fails locally, and generates no additional network traffic.
    await #expect(throws: APIError.unauthorized) {
      _ = try await cachedTransport.send(makeItemsRequest(server: server))
    }
    #expect(transport.requests.count == requestsBeforeLatchCheck)

    store.releaseSaveCall()
    let replaced = try await reauth.value
    #expect(replaced.accessToken == "new-access")

    transport.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    let response = try await cachedTransport.send(makeItemsRequest(server: server))
    #expect(response.statusCode == 200)
    #expect(transport.requests.last?.headers["Authorization"] == "Bearer new-access")
  }

  @Test("explicit logout still clears tokens after a same-account replacement")
  func explicitLogoutStillClearsReplacementTokens() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.save(initialTokens, for: account)

    let transport = FakeHTTPClient(
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        try makeLoginResponse(userID: "user_fixture", accessToken: "new-access", refreshToken: "new-refresh"),
      ]
    )
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.authenticatedSend(
        makeItemsRequest(server: server),
        account: account,
        initialTokens: initialTokens
      )
    }

    _ = try await client.reauthenticate(
      credentials: LoginCredentials(username: "fixture-user", password: "fixture-password"),
      expectedAccount: account
    )
    #expect(try store.load(for: account)?.accessToken == "new-access")

    transport.enqueue(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    try await client.logout(for: account)

    #expect(try store.load(for: account) == nil)
    #expect(transport.requests.last?.headers["x-refresh-token"] == "new-refresh")
  }

  @Test("reauthentication fences a held refresh from overwriting the newer pair")
  func reauthenticationFencesHeldRefreshFromOverwritingNewerPair() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.save(initialTokens, for: account)
    // `/auth/refresh` parks on a gate; `/login` and `/items` answer one canned response each.
    let refreshGate = TestGate<HTTPResponse>(label: "/auth/refresh")
    refreshGate.hold()
    let loginResponse = try makeLoginResponse(
      userID: "user_fixture", accessToken: "new-access", refreshToken: "new-refresh")
    let transport = FakeHTTPClient { request in
      switch request.url.path {
      case "/auth/refresh":
        return await refreshGate.pass(otherwise: {
          HTTPResponse(statusCode: 500, headers: [:], body: Data())
        })
      case "/login": return loginResponse
      case "/items": return HTTPResponse(statusCode: 200, headers: [:], body: Data())
      default: throw FakeHTTPClientError(message: "no stubbed response for \(request.url.path)")
      }
    }
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)
    let cached = try await client.authenticatedTransport(for: account, initialTokens: initialTokens)

    let refresh = Task { try await cached.forceRefresh() }
    await refreshGate.waitUntilParked()

    let replaced = try await client.reauthenticate(
      credentials: LoginCredentials(username: "fixture-user", password: "fixture-password"),
      expectedAccount: account
    )
    #expect(replaced == TokenPair(accessToken: "new-access", refreshToken: "new-refresh"))
    #expect(try store.load(for: account) == replaced)

    refreshGate.release(
      makeStaleRefreshResponse(accessToken: "stale-access", refreshToken: "stale-refresh"))
    await #expect(throws: APIError.cancelled) { _ = try await refresh.value }
    #expect(try store.load(for: account) == replaced)

    let response = try await cached.send(makeItemsRequest(server: server))
    #expect(response.statusCode == 200)
    #expect(transport.requests.last?.headers["Authorization"] == "Bearer new-access")
  }

  /// The token-store write is the one step here that can fail for a purely local reason after the
  /// server has already accepted the credentials. It carries its own case so the lifecycle layer
  /// can tell it apart from a transport failure instead of reporting "unreachable".
  @Test("a token-store write failure surfaces as a typed persistence error, not a raw store error")
  func passwordReauthenticationSurfacesTokenPersistenceFailure() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let transport = FakeHTTPClient(
      responses: [
        try makeLoginResponse(userID: "user_fixture", accessToken: "new-access", refreshToken: "new-refresh")
      ]
    )
    let tokenStore = FakeTokenStoring()
    tokenStore.stubSaveFailure(FakeTokenStoring.Failure())
    let client = ABSClient(server: server, httpClient: transport, tokenStore: tokenStore)

    let expected = ReauthenticationError.tokenPersistenceFailed(
      underlying: FakeTokenStoring.Failure())
    await #expect(throws: expected) {
      _ = try await client.reauthenticate(
        credentials: LoginCredentials(username: "rhys", password: "hunter2"), expectedAccount: account)
    }
  }

  @Test("an API-token token-store write failure surfaces the same typed persistence error")
  func apiTokenReauthenticationSurfacesTokenPersistenceFailure() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let profile: [String: Any] = [
      "id": "user_fixture",
      "username": "rhys",
      "type": "user",
      "isActive": true,
      "isLocked": false,
      "librariesAccessible": [String](),
      "permissions": [String: Any](),
    ]
    let transport = FakeHTTPClient(
      responses: [
        HTTPResponse(
          statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: profile))
      ]
    )
    let tokenStore = FakeTokenStoring()
    tokenStore.stubSaveFailure(FakeTokenStoring.Failure())
    let client = ABSClient(server: server, httpClient: transport, tokenStore: tokenStore)

    let expected = ReauthenticationError.tokenPersistenceFailed(
      underlying: FakeTokenStoring.Failure())
    await #expect(throws: expected) {
      _ = try await client.reauthenticate(
        apiToken: APITokenCredentials(token: "pasted-token"), expectedAccount: account)
    }
  }
}

private func makeServer() throws -> ABSServerConfig {
  try ABSServerConfig(url: URL(string: "https://books.example.test")!)
}

private func makeItemsRequest(server: ABSServerConfig) -> HTTPRequest {
  try! RequestBuilder(server: server).makeRequest(method: .get, path: "/items", routeTemplate: "/items")
}

private func makeLoginResponse(userID: String, accessToken: String, refreshToken: String) throws -> HTTPResponse {
  let body = try JSONSerialization.data(
    withJSONObject: [
      "user": ["id": userID, "accessToken": accessToken, "refreshToken": refreshToken],
      "userDefaultLibraryId": NSNull(),
    ]
  )
  return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}

private func makeStaleRefreshResponse(accessToken: String, refreshToken: String) -> HTTPResponse {
  let body = try! JSONSerialization.data(
    withJSONObject: ["user": ["accessToken": accessToken, "refreshToken": refreshToken]])
  return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}

/// Holds the synchronous `TokenStoring.save` boundary once armed, so a test can prove nothing
/// observes the replacement pair until that save actually completes. The test observes the
/// non-blocking `saveStarted` flag with `waitUntil`; only the narrow save-ordering hold is
/// synchronous because `TokenStoring.save` itself is synchronous.
// Kept: `TokenStoring.save` is synchronous, so holding it must block a thread on a condition,
// which the async `TestGate` cannot do.
private final class BlockingSaveTokenStore: TokenStoring, @unchecked Sendable {
  private let inner = InMemoryTokenStore()
  private let saveCondition = NSCondition()
  private let lock = NSLock()
  private var isArmed = false
  private var hasSaveStarted = false
  private var shouldReleaseSave = false

  var saveStarted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return hasSaveStarted
  }

  func seed(_ tokens: TokenPair, for account: TokenAccount) throws {
    try inner.save(tokens, for: account)
  }

  func arm() {
    lock.lock()
    isArmed = true
    lock.unlock()
  }

  func save(_ tokens: TokenPair, for account: TokenAccount) throws {
    lock.lock()
    let shouldBlock = isArmed
    lock.unlock()
    if shouldBlock {
      saveCondition.lock()
      lock.lock()
      hasSaveStarted = true
      lock.unlock()
      saveCondition.broadcast()
      while shouldReleaseSave == false {
        saveCondition.wait()
      }
      saveCondition.unlock()
    }
    try inner.save(tokens, for: account)
  }

  func load(for account: TokenAccount) throws -> TokenPair? {
    try inner.load(for: account)
  }

  func clear(for account: TokenAccount) throws {
    try inner.clear(for: account)
  }

  func releaseSaveCall() {
    saveCondition.lock()
    shouldReleaseSave = true
    saveCondition.broadcast()
    saveCondition.unlock()
  }
}
