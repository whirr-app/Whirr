import Foundation
import TestSupport
import Testing

@testable import ABSApi

@Suite("Public token refresh endpoint")
struct TokenRefreshEndpointTests {
  @Test("refresh stores the rotated pair and reuses it for the next authenticated call")
  func refreshRotatesStoredPairAndUpdatesCachedClient() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let account = try TokenAccount(server: server, userID: "user-1")
    let oldTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let store = InMemoryTokenStore()
    try store.save(oldTokens, for: account)
    let transport = FakeHTTPClient(
      responses: [
        refreshResponse(accessToken: "new-access", refreshToken: "new-refresh"),
        profileResponse(userID: "user-1"),
      ])
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    let refreshed = try await client.refreshTokens(for: account)
    _ = try await client.fetchUserProfile(account: account)

    #expect(refreshed == TokenPair(accessToken: "new-access", refreshToken: "new-refresh"))
    #expect(try store.load(for: account) == refreshed)
    #expect(transport.requests.map(\.url.path) == ["/auth/refresh", "/api/me"])
    #expect(transport.requests[1].headers["Authorization"] == "Bearer new-access")
  }

  @Test("a refresh 401 latches the cached client and sends no second refresh")
  func refreshUnauthorizedLatches() async throws {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let account = try TokenAccount(server: server, userID: "user-1")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "old-access", refreshToken: "old-refresh"), for: account)
    let transport = FakeHTTPClient(
      responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    await #expect(throws: APIError.unauthorized) {
      try await client.refreshTokens(for: account)
    }
    await #expect(throws: APIError.unauthorized) {
      try await client.refreshTokens(for: account)
    }

    #expect(transport.requests.count == 1)
    #expect(try store.load(for: account)?.accessToken == "old-access")
  }

  private func refreshResponse(accessToken: String, refreshToken: String) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: [:],
      body: Data(
        "{\"user\":{\"accessToken\":\"\(accessToken)\",\"refreshToken\":\"\(refreshToken)\"}}".utf8))
  }

  private func profileResponse(userID: String) -> HTTPResponse {
    HTTPResponse(
      statusCode: 200,
      headers: [:],
      body: Data("{\"id\":\"\(userID)\",\"librariesAccessible\":[]}".utf8))
  }
}
