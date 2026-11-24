import Foundation
import TestSupport
import Testing

@testable import ABSApi

@Suite("Authenticated HTTP client", .timeLimit(.minutes(1)))
struct AuthenticatedHTTPClientTests {
  @Test("preserves a custom request timeout when adding authorization")
  func preservesCustomTimeoutWhenAddingAuthorization() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let initialTokens = TokenPair(accessToken: "access-token", refreshToken: "refresh-token")
    let store = InMemoryTokenStore()
    try store.save(initialTokens, for: account)

    let transport = FakeHTTPClient(
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())]
    )
    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )
    let request = HTTPRequest(
      method: .get,
      url: try #require(URL(string: "https://books.example.test/items")),
      headers: [:],
      body: nil,
      routeTemplate: "/items",
      timeout: 42
    )

    let response = try await client.send(request)
    let sentRequest = try #require(transport.requests.first)

    #expect(response.statusCode == 200)
    #expect(sentRequest.headers["Authorization"] == "Bearer access-token")
    #expect(sentRequest.timeout == 42)
  }

  /// A client that removal never reached, such as one orphaned by an endpoint switch, can be
  /// mid-refresh when the credential is wiped. A refresh only rotates a stored pair, so its
  /// response must not write the removed account's credential back.
  @Test("a refresh completing after the store was cleared does not recreate the credential")
  func aRefreshCompletingAfterTheStoreWasClearedDoesNotRecreateIt() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let account = try TokenAccount(credentialNamespace: "account:client-a", userID: "user-a")
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let store = InMemoryTokenStore()
    try store.save(initialTokens, for: account)
    // Holds the one `/auth/refresh` response until the test releases it.
    let refreshGate = TestGate<HTTPResponse>(label: "/auth/refresh")
    refreshGate.hold()
    let transport = FakeHTTPClient { _ in
      await refreshGate.pass(otherwise: {
        HTTPResponse(statusCode: 500, headers: [:], body: Data())
      })
    }
    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )

    let refresh = Task { try await client.forceRefresh() }
    await refreshGate.waitUntilParked()
    try store.clear(for: account)
    refreshGate.release(
      HTTPResponse(
        statusCode: 200, headers: [:],
        body: Data(#"{"user":{"accessToken":"rotated-access","refreshToken":"rotated-refresh"}}"#.utf8)))

    await #expect(throws: APIError.cancelled) { _ = try await refresh.value }
    #expect(try store.load(for: account) == nil)
    #expect(transport.requests.map(\.url.path) == ["/auth/refresh"])
  }
}
