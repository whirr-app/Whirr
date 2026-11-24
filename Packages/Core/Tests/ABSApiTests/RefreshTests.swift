import Foundation
import TestSupport
import Testing

@testable import ABSApi

@Suite("Authenticated HTTP client refresh")
struct RefreshTests {
  // MARK: - Proactive refresh

  @Test("refreshes proactively five minutes before a valid JWT exp using an injected clock")
  func proactiveRefreshBeforeExpiry() async throws {
    let expiry = Date(timeIntervalSince1970: 1_700_000_000)
    let initialTokens = TokenPair(accessToken: makeAccessToken(expiry: expiry), refreshToken: "old-refresh")
    let server = try ABSServerConfig(
      url: #require(URL(string: "https://books.example.test")),
      customHeaders: try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    )
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    let transport = ScriptedHTTPClient()
    await transport.stub(
      path: "/auth/refresh",
      responses: [makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh")]
    )
    await transport.stub(path: "/items", responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      now: { expiry.addingTimeInterval(-4 * 60) }
    )

    let response = try await client.send(try makeItemsRequest(server: server))

    #expect(response.statusCode == 200)
    let requests = await transport.requests
    #expect(requests.map(\.url.path) == ["/auth/refresh", "/items"])
    #expect(requests[0].headers["x-refresh-token"] == "old-refresh")
    #expect(requests[0].headers["X-Proxy-Token"] == "proxy-secret")
    #expect(requests[1].headers["Authorization"] == "Bearer new-access")
    #expect(requests[1].headers["X-Proxy-Token"] == "proxy-secret")
    #expect(try store.load(for: account)?.accessToken == "new-access")
  }

  @Test("falls back to reactive refresh when the JWT exp is invalid or missing")
  func invalidExpSkipsProactiveRefresh() async throws {
    let initialTokens = TokenPair(accessToken: makeAccessToken(expiry: nil), refreshToken: "old-refresh")
    let server = try makeServer()
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    let transport = ScriptedHTTPClient()
    await transport.stub(path: "/items", responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      now: { Date(timeIntervalSince1970: 9_999_999_999) }
    )

    let response = try await client.send(try makeItemsRequest(server: server))

    #expect(response.statusCode == 200)
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 0)
  }

  @Test("an expired API token still issues its request without proactive refresh")
  func expiredNoRefreshTokenSendsRequest() async throws {
    let expiry = Date(timeIntervalSince1970: 1_700_000_000)
    let initialTokens = TokenPair(
      accessToken: makeAccessToken(expiry: expiry),
      refreshToken: nil
    )
    let server = try makeServer()
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    let transport = ScriptedHTTPClient()
    await transport.stub(
      path: "/items", responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      now: { expiry.addingTimeInterval(1) }
    )

    let response = try await client.send(try makeItemsRequest(server: server))

    #expect(response.statusCode == 200)
    let requests = await transport.requests
    #expect(requests.map(\.url.path) == ["/items"])
    #expect(requests[0].headers["Authorization"] == "Bearer \(initialTokens.accessToken)")
  }
}
