import Foundation
import TestSupport
import Testing

@testable import ABSApi

@Suite("Login lifecycle")
struct LoginTests {
  @Test("applies custom headers to the pre-auth status probe")
  func appliesCustomHeadersToStatusProbe() async throws {
    let customHeaders = try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    let server = try ABSServerConfig(
      url: #require(URL(string: "https://books.example.test/abs")),
      customHeaders: customHeaders)
    let response = HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: Data(#"{"serverVersion":"2.0.0"}"#.utf8)
    )
    let http = FakeHTTPClient(responses: [response])
    let client = ABSClient(server: server, httpClient: http, tokenStore: InMemoryTokenStore())

    #expect(try await client.fetchServerStatus().serverVersion == "2.0.0")
    #expect(http.requests[0].headers["X-Proxy-Token"] == "proxy-secret")
  }

  @Test("posts credentials to the unprefixed login route, stores tokens, and releases password")
  func logsInAndStoresSession() async throws {
    let server = try ABSServerConfig(
      url: #require(URL(string: "https://books.example.test/abs")),
      customHeaders: try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    )
    let response = HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: try Fixtures.data(named: "login-response")
    )
    let http = FakeHTTPClient(responses: [response])
    let store = InMemoryTokenStore()
    let client = ABSClient(server: server, httpClient: http, tokenStore: store)
    let credentials = LoginCredentials(username: "fixture-user", password: "fixture-password")

    let session = try await client.login(credentials: credentials)

    #expect(http.requests.count == 1)
    #expect(http.requests[0].method == .post)
    #expect(http.requests[0].url.path == "/abs/login")
    #expect(http.requests[0].url.path.contains("/api/") == false)
    #expect(http.requests[0].headers["x-return-tokens"] == "true")
    #expect(http.requests[0].headers["X-Proxy-Token"] == "proxy-secret")
    #expect(http.requests[0].headers["Authorization"] == nil)
    #expect(credentials.isPasswordReleased)
    #expect(session.userID == "user_fixture")
    #expect(session.defaultLibraryID == "library_book_fixture")
    #expect(session.accessExpiry == nil)

    let account = try TokenAccount(server: server, userID: session.userID)
    let stored = try #require(try store.load(for: account))
    #expect(stored.accessToken == "<redacted>")
    #expect(stored.refreshToken == "<redacted>")
  }

  @Test("validates an API token through /api/me, falls back to the library list, and stores no refresh token")
  func logsInWithAPIToken() async throws {
    let server = try ABSServerConfig(
      url: #require(URL(string: "https://books.example.test")),
      customHeaders: try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    )
    let http = FakeHTTPClient(
      responses: [
        HTTPResponse(statusCode: 200, headers: [:], body: try Fixtures.data(named: "me-profile-response")),
        HTTPResponse(statusCode: 200, headers: [:], body: try Fixtures.data(named: "libraries-response")),
      ]
    )
    let store = InMemoryTokenStore()
    let client = ABSClient(server: server, httpClient: http, tokenStore: store)
    let credentials = APITokenCredentials(token: "api-token-canary")

    let session = try await client.login(apiToken: credentials)

    #expect(credentials.isTokenReleased)
    #expect(session.userID == "user_fixture")
    #expect(session.defaultLibraryID == "library_book_fixture")
    #expect(session.accessExpiry == nil)
    #expect(http.requests.map(\.url.path) == ["/api/me", "/api/libraries"])
    #expect(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer api-token-canary" })
    #expect(http.requests.allSatisfy { $0.headers["X-Proxy-Token"] == "proxy-secret" })

    let account = try TokenAccount(server: server, userID: session.userID)
    let stored = try #require(try store.load(for: account))
    #expect(stored.accessToken == "api-token-canary")
    #expect(stored.refreshToken == nil)
  }

  @Test("does not store an API token when the fallback library lookup fails")
  func apiTokenLibraryLookupFailureDoesNotPersistToken() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let http = FakeHTTPClient(
      responses: [
        HTTPResponse(statusCode: 200, headers: [:], body: try Fixtures.data(named: "me-profile-response")),
        HTTPResponse(statusCode: 500, headers: [:], body: Data()),
      ]
    )
    let store = InMemoryTokenStore()
    let client = ABSClient(server: server, httpClient: http, tokenStore: store)
    let credentials = APITokenCredentials(token: "api-token-canary")

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.login(apiToken: credentials)
    }

    let account = try TokenAccount(server: server, userID: "user_fixture")
    #expect(try store.load(for: account) == nil)
    #expect(credentials.isTokenReleased)
  }

  @Test("an API-token validation 401 uses the ordinary unauthorized error and releases the token")
  func rejectsInvalidAPITokenAsUnauthorized() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let client = ABSClient(
      server: server,
      httpClient: FakeHTTPClient(responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())]),
      tokenStore: InMemoryTokenStore()
    )
    let credentials = APITokenCredentials(token: "invalid-api-token")

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.login(apiToken: credentials)
    }
    #expect(credentials.isTokenReleased)
  }

  @Test("rejects a password login response without a refresh token")
  func rejectsLoginWithoutRefreshToken() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let response = HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: Data(#"{"user":{"id":"user_fixture","accessToken":"access"}}"#.utf8)
    )
    let client = ABSClient(
      server: server,
      httpClient: FakeHTTPClient(responses: [response]),
      tokenStore: InMemoryTokenStore()
    )
    let credentials = LoginCredentials(username: "fixture-user", password: "fixture-password")

    await #expect(throws: APIError.decoding) {
      _ = try await client.login(credentials: credentials)
    }
    #expect(credentials.isPasswordReleased)
  }

  @Test("unknown fields and null optional fields do not break login decoding")
  func decodesLossyOptionalFields() async throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "login-response")) as? [String: Any]
    )
    var user = try #require(object["user"] as? [String: Any])
    user["email"] = NSNull()
    user["coverPath"] = NSNull()
    user["futureField"] = ["unknown": true]
    object["user"] = user
    object["futureTopLevelField"] = "ignored"

    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let response = HTTPResponse(
      statusCode: 200,
      headers: [:],
      body: try JSONSerialization.data(withJSONObject: object)
    )
    let client = ABSClient(
      server: server,
      httpClient: FakeHTTPClient(responses: [response]),
      tokenStore: InMemoryTokenStore()
    )

    let session = try await client.login(
      credentials: LoginCredentials(username: "fixture-user", password: "fixture-password")
    )

    #expect(session.userID == "user_fixture")
  }

  @Test("extracts the access-token expiry from the fixture response")
  func extractsAccessExpiry() async throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "login-response")) as? [String: Any]
    )
    var user = try #require(object["user"] as? [String: Any])
    let payload = Data(#"{"exp":1700000000,"userId":"user_fixture"}"#.utf8)
    let accessToken =
      [Data(#"{"alg":"none","typ":"JWT"}"#.utf8), payload]
      .map(base64URLEncoded)
      .joined(separator: ".") + ".signature"
    user["accessToken"] = accessToken
    object["user"] = user

    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let response = HTTPResponse(
      statusCode: 200,
      headers: [:],
      body: try JSONSerialization.data(withJSONObject: object)
    )
    let client = ABSClient(
      server: server,
      httpClient: FakeHTTPClient(responses: [response]),
      tokenStore: InMemoryTokenStore()
    )

    let session = try await client.login(
      credentials: LoginCredentials(username: "fixture-user", password: "fixture-password")
    )

    #expect(session.accessExpiry == Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test("commit is one-shot across copied prepared sessions")
  func commitIsOneShotAcrossSessionCopies() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let store = InMemoryTokenStore()
    let client = ABSClient(
      server: server,
      httpClient: FakeHTTPClient(responses: [try makePasswordLoginResponse()]),
      tokenStore: store
    )
    let session = try await client.prepareLogin(
      credentials: LoginCredentials(username: "fixture-user", password: "fixture-password"))
    let copy = session

    try await client.commitLogin(session)
    await #expect(throws: APIError.decoding) {
      try await client.commitLogin(copy)
    }

    #expect(try store.load(for: session.account)?.accessToken == "new-access")
  }

  @Test("discard is idempotent and invalidates every prepared-session copy")
  func discardInvalidatesEverySessionCopy() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let store = InMemoryTokenStore()
    let client = ABSClient(
      server: server,
      httpClient: FakeHTTPClient(responses: [try makePasswordLoginResponse()]),
      tokenStore: store
    )
    let session = try await client.prepareLogin(
      credentials: LoginCredentials(username: "fixture-user", password: "fixture-password"))
    let copy = session

    await client.discardLogin(session)
    await client.discardLogin(copy)
    await #expect(throws: APIError.decoding) {
      try await client.commitLogin(copy)
    }

    #expect(try store.load(for: session.account) == nil)
  }

  @Test("a failed token save leaves the prepared session retryable")
  func failedSaveLeavesPreparedSessionRetryable() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let store = FakeTokenStoring()
    store.stubSaveFailure(FakeTokenStoring.Failure(), times: 1)
    let client = ABSClient(
      server: server,
      httpClient: FakeHTTPClient(responses: [try makePasswordLoginResponse()]),
      tokenStore: store
    )
    let credentials = LoginCredentials(username: "fixture-user", password: "fixture-password")
    let session = try await client.prepareLogin(credentials: credentials)

    await #expect(throws: FakeTokenStoring.Failure()) {
      try await client.commitLogin(session)
    }
    try await client.commitLogin(session)

    #expect(credentials.isPasswordReleased)
    #expect(try store.load(for: session.account)?.accessToken == "new-access")
  }

  @Test("a publicly initialized session cannot be committed")
  func publicSessionCannotBeCommitted() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let client = ABSClient(server: server, httpClient: FakeHTTPClient(), tokenStore: store)
    let session = LoginSession(
      account: account,
      userID: account.userID,
      defaultLibraryID: nil,
      accessExpiry: nil
    )

    await #expect(throws: APIError.decoding) {
      try await client.commitLogin(session)
    }
    #expect(try store.load(for: account) == nil)
  }

  @Test("ordinary login updates an existing cached authenticated client")
  func loginUpdatesExistingAuthenticatedClient() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let oldTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let store = InMemoryTokenStore()
    try store.save(oldTokens, for: account)
    let http = FakeHTTPClient(
      responses: [
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
        try makePasswordLoginResponse(),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      ]
    )
    let client = ABSClient(server: server, httpClient: http, tokenStore: store)
    let request = try RequestBuilder(server: server).makeRequest(
      method: .get, path: "/items", routeTemplate: "/items")

    _ = try await client.authenticatedSend(request, account: account, initialTokens: oldTokens)
    _ = try await client.login(
      credentials: LoginCredentials(username: "fixture-user", password: "fixture-password"))
    _ = try await client.authenticatedSend(request, account: account, initialTokens: oldTokens)

    #expect(http.requests.last?.headers["Authorization"] == "Bearer new-access")
  }
}

private func base64URLEncoded(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .trimmingCharacters(in: CharacterSet(charactersIn: "="))
}

@Suite("Logout lifecycle")
struct LogoutTests {
  @Test("an empty-store logout evicts a terminal client before a later login")
  func emptyStoreLogoutEvictsCachedClient() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let oldTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let store = InMemoryTokenStore()
    let http = FakeHTTPClient(
      responses: [
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
        try makePasswordLoginResponse(),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      ]
    )
    let client = ABSClient(server: server, httpClient: http, tokenStore: store)
    let request = try RequestBuilder(server: server).makeRequest(
      method: .get, path: "/items", routeTemplate: "/items")

    _ = try await client.authenticatedSend(request, account: account, initialTokens: oldTokens)
    try await client.logout(for: account)
    let session = try await client.login(
      credentials: LoginCredentials(username: "fixture-user", password: "fixture-password"))
    _ = try await client.authenticatedSend(
      request,
      account: session.account,
      initialTokens: try #require(try store.load(for: session.account))
    )

    #expect(http.requests.last?.headers["Authorization"] == "Bearer new-access")
  }

  @Test("clears stored headers even when no tokens remain")
  func clearsHeadersWithoutTokens() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test/abs")))
    let http = FakeHTTPClient()
    let tokenStore = InMemoryTokenStore()
    let headerStore = InMemoryCustomHeaderStore()
    let client = ABSClient(
      server: server,
      httpClient: http,
      tokenStore: tokenStore,
      customHeaderStore: headerStore)
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try headerStore.save(try CustomHeaders(["X-Proxy-Token": "proxy-secret"]), for: server.baseURL)

    try await client.logout(for: account)

    #expect(http.requests.isEmpty)
    #expect(try headerStore.load(for: server.baseURL) == nil)
  }

  @Test("a namespace-account logout clears its tokens and leaves every URL-keyed header item alone")
  func namespaceLogoutLeavesHeadersToTheLifecycle() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test/abs")))
    let http = FakeHTTPClient(
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())]
    )
    let tokenStore = InMemoryTokenStore()
    let headerStore = InMemoryCustomHeaderStore()
    let client = ABSClient(
      server: server,
      httpClient: http,
      tokenStore: tokenStore,
      customHeaderStore: headerStore)
    let account = try TokenAccount(credentialNamespace: "account:fixture-uuid", userID: "user_fixture")
    try tokenStore.save(TokenPair(accessToken: "access", refreshToken: "refresh-secret"), for: account)
    try headerStore.save(try CustomHeaders(["X-Proxy-Token": "proxy-secret"]), for: server.baseURL)

    try await client.logout(for: account)

    #expect(http.requests.count == 1)
    #expect(try tokenStore.load(for: account) == nil)
    #expect(try headerStore.load(for: server.baseURL)?.headers["X-Proxy-Token"] == "proxy-secret")
  }

  @Test("sends the refresh token to the unprefixed logout route and clears local tokens")
  func logsOut() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test/abs")))
    let http = FakeHTTPClient(
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())]
    )
    let store = InMemoryTokenStore()
    let client = ABSClient(server: server, httpClient: http, tokenStore: store)
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(TokenPair(accessToken: "access", refreshToken: "refresh-secret"), for: account)

    try await client.logout(for: account)

    #expect(http.requests.count == 1)
    #expect(http.requests[0].url.path == "/abs/logout")
    #expect(http.requests[0].url.path.contains("/api/") == false)
    #expect(http.requests[0].headers["x-refresh-token"] == "refresh-secret")
    #expect(try store.load(for: account) == nil)
  }

  @Test("omits the refresh header but still clears a no-refresh account locally")
  func logsOutNoRefreshAccount() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test/abs")))
    let http = FakeHTTPClient(
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())]
    )
    let store = InMemoryTokenStore()
    let client = ABSClient(server: server, httpClient: http, tokenStore: store)
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(TokenPair(accessToken: "api-access", refreshToken: nil), for: account)

    try await client.logout(for: account)

    #expect(http.requests.count == 1)
    #expect(http.requests[0].headers["x-refresh-token"] == nil)
    #expect(try store.load(for: account) == nil)
  }

  @Test("clears local tokens when the server logout fails")
  func clearsTokensAfterLogoutFailure() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let http = FakeHTTPClient(failure: FakeHTTPClientError(message: "offline"))
    let store = InMemoryTokenStore()
    let client = ABSClient(server: server, httpClient: http, tokenStore: store)
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(TokenPair(accessToken: "access", refreshToken: "refresh-secret"), for: account)

    await #expect(throws: FakeHTTPClientError.self) {
      try await client.logout(for: account)
    }

    #expect(try store.load(for: account) == nil)
  }
}

private func makePasswordLoginResponse() throws -> HTTPResponse {
  let body = try JSONSerialization.data(
    withJSONObject: [
      "user": [
        "id": "user_fixture",
        "accessToken": "new-access",
        "refreshToken": "new-refresh",
      ],
      "userDefaultLibraryId": NSNull(),
    ]
  )
  return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}
