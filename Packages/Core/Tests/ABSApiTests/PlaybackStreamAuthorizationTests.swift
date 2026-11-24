import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// `ABSClient.makePlaybackStreamAuthorization` is the playback adapter's only way to obtain the
/// Bearer header a direct-play stream needs (API-CONVENTIONS.md rule 6a:
/// `/api/items/{id}/file/{ino}` 401s without it). Mirrors `AuthorizedDownloadRequest`'s minting
/// contract for downloads.
@Suite("Playback stream authorization")
struct PlaybackStreamAuthorizationTests {

  /// A path-only guard would authorize any host exposing the same ABS route. A matching `/api/`
  /// path on another origin must receive nothing.
  @Test("withholds both header sets from an off-origin URL with a matching API path")
  func withholdsHeadersFromOffOriginMatchingAPIPath() async throws {
    let customHeaders = try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    let (client, _, account) = try makeStreamClient(
      accessToken: "current-access", customHeaders: customHeaders)

    let authorization = try await client.makePlaybackStreamAuthorization(account: account)

    #expect(
      authorization.httpHeaderFields(
        for: URL(string: "https://attacker.example.test/api/items/item_1/file/42")!
      ).isEmpty)
  }

  @Test("stamps the account's current access token as a Bearer header field")
  func stampsCurrentAccessTokenAsBearer() async throws {
    let customHeaders = try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    let (client, _, account) = try makeStreamClient(
      accessToken: "current-access", customHeaders: customHeaders)

    let authorization = try await client.makePlaybackStreamAuthorization(account: account)

    #expect(
      authorization.httpHeaderFields(
        for: URL(string: "https://books.example.test/api/items/item_1/file/42")!)
        == ["Authorization": "Bearer current-access", "X-Proxy-Token": "proxy-secret"])
  }

  /// A transcoded session's `/hls/{sessionId}/output.m3u8` is mounted outside the `/api`
  /// middleware and served without auth, so the Bearer must not travel with it. ARCHITECTURE.md
  /// D19 forces direct play, so this is an unprotected boundary rather than a live leak. Pin both
  /// sides.
  @Test("withholds the Bearer header from a transcoded HLS resource")
  func withholdsBearerFromTranscodedHLSResource() async throws {
    let (client, _, account) = try makeStreamClient(accessToken: "current-access")

    let authorization = try await client.makePlaybackStreamAuthorization(account: account)

    #expect(
      authorization.httpHeaderFields(
        for: URL(string: "https://books.example.test/hls/session_1/output.m3u8")!
      ).isEmpty)
  }

  @Test("sends proxy headers on a same-origin transcoded HLS resource without a Bearer")
  func sendsProxyHeadersToSameOriginHLSResource() async throws {
    let customHeaders = try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    let (client, _, account) = try makeStreamClient(
      accessToken: "current-access", customHeaders: customHeaders)

    let authorization = try await client.makePlaybackStreamAuthorization(account: account)
    let fields = authorization.httpHeaderFields(
      for: URL(string: "https://books.example.test/hls/session_1/output.m3u8")!
    )

    #expect(fields == ["X-Proxy-Token": "proxy-secret"])
    #expect(fields["Authorization"] == nil)
  }

  @Test("treats an omitted default port as the same origin")
  func treatsDefaultPortsAsSameOrigin() async throws {
    let customHeaders = try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    let (client, _, account) = try makeStreamClient(
      accessToken: "current-access", customHeaders: customHeaders)

    let authorization = try await client.makePlaybackStreamAuthorization(account: account)

    #expect(
      authorization.httpHeaderFields(
        for: URL(string: "https://books.example.test:443/api/items/item_1/file/42")!
      ) == ["Authorization": "Bearer current-access", "X-Proxy-Token": "proxy-secret"])
  }

  @Test("resolves authenticated versus unauthenticated shapes beneath a server path prefix")
  func honoursServerPathPrefixWhenDecidingAuthorization() async throws {
    let server = try ABSServerConfig(url: URL(string: "https://host.example.test/audiobooks")!)
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "prefixed-access", refreshToken: "refresh"), for: account)
    let client = ABSClient(server: server, httpClient: FakeHTTPClient(), tokenStore: store)

    let authorization = try await client.makePlaybackStreamAuthorization(account: account)

    #expect(
      authorization.httpHeaderFields(
        for: URL(string: "https://host.example.test/audiobooks/api/items/item_1/file/42")!)
        == ["Authorization": "Bearer prefixed-access"])
    #expect(
      authorization.httpHeaderFields(
        for: URL(string: "https://host.example.test/audiobooks/hls/session_1/output.m3u8")!
      )
      .isEmpty)
  }

  /// A local session plays an app-container file URL, which needs no headers and must never be
  /// handed a Bearer just because it shares the tuple shape of a streamed track.
  @Test("withholds the Bearer header from a non-server file URL")
  func withholdsBearerFromFileURL() async throws {
    let (client, _, account) = try makeStreamClient(accessToken: "current-access")

    let authorization = try await client.makePlaybackStreamAuthorization(account: account)

    #expect(
      authorization.httpHeaderFields(for: URL(fileURLWithPath: "/tmp/book.m4b")).isEmpty)
  }

  @Test("no token appears in any formatted description")
  func noTokenInDescription() async throws {
    let customHeaders = try CustomHeaders(["X-Proxy-Token": "CANARY-PROXY-DO-NOT-LEAK"])
    let (client, _, account) = try makeStreamClient(
      accessToken: "CANARY-ACCESS-DO-NOT-LEAK",
      refreshToken: "CANARY-REFRESH-DO-NOT-LEAK",
      customHeaders: customHeaders)

    let authorization = try await client.makePlaybackStreamAuthorization(account: account)

    #expect("\(authorization)".contains("X-Proxy-Token"))
    #expect(String(reflecting: authorization).contains("X-Proxy-Token"))
    #expect("\(authorization)".contains("CANARY-ACCESS-DO-NOT-LEAK") == false)
    #expect(String(reflecting: authorization).contains("CANARY-ACCESS-DO-NOT-LEAK") == false)
    #expect("\(authorization)".contains("CANARY-PROXY-DO-NOT-LEAK") == false)
    #expect(String(reflecting: authorization).contains("CANARY-PROXY-DO-NOT-LEAK") == false)
    #expect("\(authorization)".contains("CANARY-REFRESH-DO-NOT-LEAK") == false)
    #expect(String(reflecting: authorization).contains("CANARY-REFRESH-DO-NOT-LEAK") == false)
  }

  @Test("the refresh token is never reachable from a minted authorization")
  func refreshTokenNeverReachable() async throws {
    let (client, _, account) = try makeStreamClient(
      accessToken: "access-canary", refreshToken: "CANARY-REFRESH-DO-NOT-LEAK")

    let authorization = try await client.makePlaybackStreamAuthorization(account: account)

    let values = authorization.httpHeaderFields(
      for: URL(string: "https://books.example.test/api/items/item_1/file/42")!
    ).values
    #expect(values.contains(where: { (value: String) in value.contains("CANARY-REFRESH-DO-NOT-LEAK") }) == false)
  }

  @Test("minting stamps a token without taking a gate permit or touching transport")
  func mintingTakesNoGatePermitOrTransportTraffic() async throws {
    let server = try makeStreamServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: account)
    let http = FakeHTTPClient()
    let gate = ServerRequestGate()
    let client = ABSClient(server: server, httpClient: http, tokenStore: store, requestGate: gate)

    _ = try await client.makePlaybackStreamAuthorization(account: account)

    #expect(http.requests.isEmpty)
    #expect(await gate.inFlightCount == 0)
    #expect(await gate.queuedCount == 0)
  }

  /// The stream half of the download queue's one-renewed-retry path
  /// (`renewAuthorizedDownloadRequest`). A Bearer stamped at `/play` time is as old as the
  /// session, and a listen outlives it, so a long listen needs a renewed header.
  @Test("renew runs the single-flight refresh exactly once and stamps the rotated token")
  func renewRunsRefreshOnceAndStampsRotatedToken() async throws {
    let customHeaders = try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    let server = try makeStreamServer(customHeaders: customHeaders)
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "old-access", refreshToken: "old-refresh"), for: account)
    let transport = FakeHTTPClient(
      responses: [makeStreamRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh")])
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    let authorization = try await client.renewPlaybackStreamAuthorization(account: account)

    #expect(
      authorization.httpHeaderFields(
        for: URL(string: "https://books.example.test/api/items/item_1/file/42")!)
        == ["Authorization": "Bearer new-access", "X-Proxy-Token": "proxy-secret"])
    #expect(transport.requests.filter { $0.url.path == "/auth/refresh" }.count == 1)
    #expect(try store.load(for: account)?.accessToken == "new-access")
  }

  @Test("no-refresh renewal fails before touching the transport")
  func renewWithoutRefreshTokenFailsFast() async throws {
    let server = try makeStreamServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "api-access", refreshToken: nil), for: account)
    let transport = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.renewPlaybackStreamAuthorization(account: account)
    }

    #expect(transport.requests.isEmpty)
  }

  /// A refresh the server definitively rejects surfaces as `.unauthorized`, the same terminal
  /// classification the download renewal path reports. It latches `AuthenticatedHTTPClient` so
  /// the recovery sheet is raised through the ordinary route. The caller must never see a
  /// stale-but-usable header instead.
  @Test("a rejected refresh surfaces as unauthorized rather than a stale header")
  func rejectedRefreshSurfacesUnauthorized() async throws {
    let server = try makeStreamServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "old-access", refreshToken: "old-refresh"), for: account)
    let transport = FakeHTTPClient(
      responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.renewPlaybackStreamAuthorization(account: account)
    }
  }

  @Test("minting throws unauthorized when no tokens are stored for the account")
  func mintingWithoutStoredTokensThrowsUnauthorized() async throws {
    let server = try makeStreamServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let client = ABSClient(server: server, httpClient: FakeHTTPClient(), tokenStore: InMemoryTokenStore())

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.makePlaybackStreamAuthorization(account: account)
    }
  }
}

private func makeStreamClient(
  accessToken: String,
  refreshToken: String = "refresh",
  customHeaders: CustomHeaders = .none
) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
  let server = try makeStreamServer(customHeaders: customHeaders)
  let account = try TokenAccount(server: server, userID: "user_fixture")
  let store = InMemoryTokenStore()
  try store.save(TokenPair(accessToken: accessToken, refreshToken: refreshToken), for: account)
  let http = FakeHTTPClient()
  return (ABSClient(server: server, httpClient: http, tokenStore: store), http, account)
}

private func makeStreamServer(customHeaders: CustomHeaders = .none) throws -> ABSServerConfig {
  try ABSServerConfig(
    url: URL(string: "https://books.example.test")!, customHeaders: customHeaders)
}

private func makeStreamRefreshResponse(accessToken: String, refreshToken: String) -> HTTPResponse {
  let body = try! JSONSerialization.data(
    withJSONObject: ["user": ["accessToken": accessToken, "refreshToken": refreshToken]])
  return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}
