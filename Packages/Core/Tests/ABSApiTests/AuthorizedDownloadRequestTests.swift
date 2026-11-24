import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// `ABSClient.makeAuthorizedDownloadRequest`/`renewAuthorizedDownloadRequest`: the App's
/// background-download adapter's only way to obtain a Bearer-stamped `FileDownloadRequest`
/// (see ARCHITECTURE.md) without ever holding a token itself.
@Suite("Authorized download requests", .timeLimit(.minutes(1)))
struct AuthorizedDownloadRequestTests {

  @Test("authorized transfer descriptions and reflection redact URL and headers")
  func authorizedTransferRequestIsRedacted() {
    var request = URLRequest(url: URL(string: "https://books.example.test/audio/42")!)
    request.httpMethod = "GET"
    request.setValue("Bearer CANARY-ACCESS", forHTTPHeaderField: "Authorization")
    request.setValue("proxy-secret", forHTTPHeaderField: "X-Proxy-Token")
    let transfer = AuthorizedTransferRequest(
      request: request, expectedMIMEType: "audio/mp4", expectedBytes: 42,
      itemID: "item-1", fileID: "42")

    #expect(String(describing: transfer).contains("CANARY") == false)
    #expect(String(reflecting: transfer).contains("CANARY") == false)
    #expect(String(reflecting: transfer).contains("books.example.test") == false)
    #expect(String(reflecting: transfer).contains("proxy-secret") == false)
  }

  @Test("ABS authorized transfer preserves URLRequest bytes and headers exactly")
  func absURLRequestIdentityIsPreserved() throws {
    var request = URLRequest(url: URL(string: "https://books.example.test/audio/42")!)
    request.httpMethod = "GET"
    request.timeoutInterval = 123
    request.httpShouldHandleCookies = false
    request.setValue("Bearer access-token", forHTTPHeaderField: "Authorization")
    request.setValue("proxy-secret", forHTTPHeaderField: "X-Proxy-Token")
    let transfer = AuthorizedTransferRequest(
      request: request, expectedMIMEType: "audio/mp4", expectedBytes: 42,
      redirectPolicy: .abs, itemID: "item-1", fileID: "42")

    #expect(transfer.request.url == request.url)
    #expect(transfer.request.httpMethod == request.httpMethod)
    #expect(transfer.request.timeoutInterval == request.timeoutInterval)
    #expect(transfer.request.httpShouldHandleCookies == request.httpShouldHandleCookies)
    #expect(transfer.request.allHTTPHeaderFields == request.allHTTPHeaderFields)
    #expect(transfer.redirectPolicy == .abs)
  }

  @Test("mints a request carrying the file's expected MIME/size and the current access token")
  func mintsCarriesExpectedMetadataAndCurrentAccessToken() async throws {
    let customHeaders = try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    let (client, _, account) = try makeClient(
      accessToken: "current-access", refreshToken: "current-refresh", customHeaders: customHeaders)
    let download = try FileDownloadRequest(
      itemID: "item-1", fileID: "42", expectedMIMEType: "audio/mp4", expectedSize: 123_456
    )

    let authorized = try await client.makeAuthorizedDownloadRequest(download, account: account)

    #expect(authorized.itemID == "item-1")
    #expect(authorized.fileID == "42")
    #expect(authorized.expectedMIMEType == "audio/mp4")
    #expect(authorized.expectedSize == 123_456)
    let urlRequest = authorized.makeURLRequest()
    #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer current-access")
    #expect(urlRequest.value(forHTTPHeaderField: "X-Proxy-Token") == "proxy-secret")
    #expect(urlRequest.url?.absoluteString.contains("/item-1/file/42/download") == true)
    #expect(urlRequest.timeoutInterval == 300)
  }

  @Test("disables URLSession cookie storage for a configured Cookie header")
  func disablesCookieStorageForConfiguredCookie() async throws {
    let customHeaders = try CustomHeaders(["Cookie": "session=abc"])
    let (client, _, account) = try makeClient(
      accessToken: "current-access", refreshToken: "current-refresh", customHeaders: customHeaders)
    let download = try FileDownloadRequest(
      itemID: "item-1", fileID: "42", expectedMIMEType: "audio/mp4", expectedSize: 10)

    let authorized = try await client.makeAuthorizedDownloadRequest(download, account: account)

    #expect(authorized.makeURLRequest().httpShouldHandleCookies == false)
  }

  @Test("no token appears in the URL, query, or any formatted description")
  func noTokenInURLQueryOrDescription() async throws {
    let (client, _, account) = try makeClient(
      accessToken: "CANARY-ACCESS-DO-NOT-LEAK",
      refreshToken: "CANARY-REFRESH-DO-NOT-LEAK"
    )
    let download = try FileDownloadRequest(
      itemID: "item-1", fileID: "42", expectedMIMEType: "audio/mp4", expectedSize: 10
    )

    let authorized = try await client.makeAuthorizedDownloadRequest(download, account: account)
    let urlRequest = authorized.makeURLRequest()

    #expect((urlRequest.url?.absoluteString ?? "").contains("CANARY-ACCESS-DO-NOT-LEAK") == false)
    #expect(urlRequest.url?.query == nil)
    #expect("\(authorized)".contains("CANARY-ACCESS-DO-NOT-LEAK") == false)
    #expect(String(reflecting: authorized).contains("CANARY-ACCESS-DO-NOT-LEAK") == false)
    #expect("\(authorized)".contains("CANARY-REFRESH-DO-NOT-LEAK") == false)
  }

  @Test("minting stamps a token without ever taking a ServerRequestGate permit or touching transport")
  func mintingTakesNoGatePermitOrTransportTraffic() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "access", refreshToken: "refresh"), for: account)
    // Zero canned responses: any transport.send() would throw, so a passing test with no thrown
    // error already proves minting never reached the transport. The gate assertions below are the
    // literal "fake gate asserts zero traffic" check on top of that.
    let http = FakeHTTPClient()
    let gate = ServerRequestGate()
    let client = ABSClient(server: server, httpClient: http, tokenStore: store, requestGate: gate)
    let download = try FileDownloadRequest(
      itemID: "item-1", fileID: "42", expectedMIMEType: "audio/mp4", expectedSize: 10
    )

    _ = try await client.makeAuthorizedDownloadRequest(download, account: account)

    #expect(http.requests.isEmpty)
    #expect(await gate.inFlightCount == 0)
    #expect(await gate.queuedCount == 0)
  }

  @Test("minting throws unauthorized when no tokens are stored for the account")
  func mintingWithoutStoredTokensThrowsUnauthorized() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let client = ABSClient(server: server, httpClient: FakeHTTPClient(), tokenStore: store)
    let download = try FileDownloadRequest(
      itemID: "item-1", fileID: "42", expectedMIMEType: "audio/mp4", expectedSize: 10
    )

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.makeAuthorizedDownloadRequest(download, account: account)
    }
  }

  @Test(
    "renewAuthorizedDownloadRequest runs the single-flight refresh exactly once and returns a freshly stamped request"
  )
  func renewRunsRefreshOnceAndReturnsFreshRequest() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "old-access", refreshToken: "old-refresh"), for: account)
    let transport = FakeHTTPClient(
      responses: [makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh")]
    )
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)
    let download = try FileDownloadRequest(
      itemID: "item-1", fileID: "42", expectedMIMEType: "audio/mp4", expectedSize: 10
    )

    let renewed = try await client.renewAuthorizedDownloadRequest(download, account: account)

    #expect(renewed.makeURLRequest().value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
    #expect(transport.requests.filter { $0.url.path == "/auth/refresh" }.count == 1)
    #expect(try store.load(for: account)?.accessToken == "new-access")
  }

  @Test("no-refresh renewal fails before touching the transport")
  func renewWithoutRefreshTokenFailsFast() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "api-access", refreshToken: nil), for: account)
    let transport = FakeHTTPClient()
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)
    let download = try FileDownloadRequest(
      itemID: "item-1", fileID: "42", expectedMIMEType: "audio/mp4", expectedSize: 10)

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.renewAuthorizedDownloadRequest(download, account: account)
    }

    #expect(transport.requests.isEmpty)
  }

  @Test("concurrent renewals for different files share exactly one refresh")
  func concurrentRenewalsForDifferentFilesShareOneRefresh() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(TokenPair(accessToken: "old-access", refreshToken: "old-refresh"), for: account)
    // Holds the one refresh open so three concurrent renewals provably attach to it, rather than a
    // fast fake letting the first caller finish before the others join its shared task.
    let refreshGate = TestGate<HTTPResponse>(label: "/auth/refresh")
    refreshGate.hold()
    let transport = FakeHTTPClient { _ in
      await refreshGate.pass(otherwise: {
        HTTPResponse(statusCode: 500, headers: [:], body: Data())
      })
    }
    let attachedWaiters = Locked(0)
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)
    let downloads = try (0..<3).map { index in
      try FileDownloadRequest(
        itemID: "item-1", fileID: "file-\(index)", expectedMIMEType: "audio/mp4", expectedSize: 10
      )
    }

    let tasks = downloads.map { download in
      Task {
        async let renewed = client.renewAuthorizedDownloadRequest(download, account: account)
        await refreshGate.waitUntilParked()
        attachedWaiters.withValue { $0 += 1 }
        return try await renewed
      }
    }
    await refreshGate.waitUntilParked()
    #expect(await waitUntil { attachedWaiters.value == downloads.count })
    refreshGate.release(makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh"))

    var seenFileIDs: Set<String> = []
    for task in tasks {
      let renewed = try await task.value
      #expect(renewed.makeURLRequest().value(forHTTPHeaderField: "Authorization") == "Bearer new-access")
      seenFileIDs.insert(renewed.fileID)
    }
    #expect(seenFileIDs == Set(downloads.map(\.fileID)))
    #expect(transport.requests.filter { $0.url.path == "/auth/refresh" }.count == 1)
  }

  @Test("a transport failure during refresh classifies as transport, retains tokens, without retry loops")
  func transportFailureDuringRefreshRetainsTokensWithoutRetryLoop() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.save(initialTokens, for: account)
    let transport = FakeHTTPClient(failure: FakeHTTPClientError(message: "refresh unreachable"))
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store)
    let download = try FileDownloadRequest(
      itemID: "item-1", fileID: "42", expectedMIMEType: "audio/mp4", expectedSize: 10
    )

    // API-CONVENTIONS.md rule 3a: a refresh that cannot be completed is not a rejected refresh.
    // The transport classification surfaces unchanged and tokens are retained.
    await #expect(throws: APIError.transport) {
      _ = try await client.renewAuthorizedDownloadRequest(download, account: account)
    }

    #expect(transport.requests.filter { $0.url.path == "/auth/refresh" }.count == 1)
    #expect(try store.load(for: account) == initialTokens)
  }

  @Test("the refresh token is never reachable from a minted or renewed request")
  func refreshTokenNeverReachableFromReturnedValue() async throws {
    let (client, _, account) = try makeClient(
      accessToken: "access-canary", refreshToken: "CANARY-REFRESH-DO-NOT-LEAK"
    )
    let download = try FileDownloadRequest(
      itemID: "item-1", fileID: "42", expectedMIMEType: "audio/mp4", expectedSize: 10
    )

    let authorized = try await client.makeAuthorizedDownloadRequest(download, account: account)
    let urlRequest = authorized.makeURLRequest()

    #expect((urlRequest.url?.absoluteString ?? "").contains("CANARY-REFRESH-DO-NOT-LEAK") == false)
    let headerValues = (urlRequest.allHTTPHeaderFields ?? [:]).values
    #expect(headerValues.contains(where: { (value: String) in value.contains("CANARY-REFRESH-DO-NOT-LEAK") }) == false)
    #expect("\(authorized)".contains("CANARY-REFRESH-DO-NOT-LEAK") == false)
    #expect(String(reflecting: authorized).contains("CANARY-REFRESH-DO-NOT-LEAK") == false)
  }
}

private func makeClient(
  accessToken: String,
  refreshToken: String,
  customHeaders: CustomHeaders = .none
) throws -> (client: ABSClient, http: FakeHTTPClient, account: TokenAccount) {
  try ABSClientFixture.make(
    accessToken: accessToken, refreshToken: refreshToken,
    server: try makeServer(customHeaders: customHeaders))
}

private func makeServer(customHeaders: CustomHeaders = .none) throws -> ABSServerConfig {
  try ABSServerConfig(url: URL(string: "https://books.example.test")!, customHeaders: customHeaders)
}

private func makeRefreshResponse(accessToken: String, refreshToken: String) -> HTTPResponse {
  let body = try! JSONSerialization.data(
    withJSONObject: ["user": ["accessToken": accessToken, "refreshToken": refreshToken]]
  )
  return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
}
