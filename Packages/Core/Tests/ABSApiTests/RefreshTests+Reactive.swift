import Foundation
import TestSupport
import Testing

@testable import ABSApi

extension RefreshTests {
  // MARK: - Reactive refresh and retry

  @Test("a 401 refreshes with x-refresh-token, persists the rotated pair, and retries once")
  func reactiveRefreshPersistsThenRetries() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    let transport = ScriptedHTTPClient()
    await transport.stub(
      path: "/items",
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      ]
    )
    await transport.stub(
      path: "/auth/refresh",
      responses: [makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh")]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )

    let response = try await client.send(try makeItemsRequest(server: server))

    #expect(response.statusCode == 200)
    let requests = await transport.requests
    #expect(requests.map(\.url.path) == ["/items", "/auth/refresh", "/items"])
    #expect(requests[0].headers["Authorization"] == "Bearer old-access")
    #expect(requests[1].headers["x-refresh-token"] == "old-refresh")
    #expect(requests[2].headers["Authorization"] == "Bearer new-access")
    #expect(try store.load(for: account)?.accessToken == "new-access")
    #expect(try store.load(for: account)?.refreshToken == "new-refresh")
  }

  @Test("five concurrent 401s produce exactly one refresh")
  func concurrentRefreshesCoalesce() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    // The refresh call is held open until every one of the 5 originals has been dispatched
    // and observed its 401. Otherwise, with an instantly-resolving fake, the owner could finish
    // and reset the shared task before a slower sibling attaches to it.
    let transport = BlockingRefreshHTTPClient()
    await transport.stub(
      path: "/items",
      responses: Array(repeating: HTTPResponse(statusCode: 401, headers: [:], body: Data()), count: 5)
        + Array(repeating: HTTPResponse(statusCode: 200, headers: [:], body: Data()), count: 5)
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )

    let waiters = (0..<5).map { _ in
      Task {
        let request = try makeItemsRequest(server: server)
        async let response = client.send(request)
        await transport.waitUntilRefreshStarted()
        await transport.attachRefreshWaiter()
        return try await response
      }
    }
    await transport.waitUntilRefreshStarted()
    await waitUntil { await transport.requestCount(forPath: "/items") == 5 }
    #expect(await waitUntil { await transport.attachedRefreshWaiterCount == waiters.count })

    await transport.releaseRefresh(with: makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh"))

    for waiter in waiters {
      #expect(try await waiter.value.statusCode == 200)
    }

    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    let itemsRequests = (await transport.requests).filter { $0.url.path == "/items" }
    #expect(itemsRequests.count == 10)
    #expect(itemsRequests.filter { $0.headers["Authorization"] == "Bearer old-access" }.count == 5)
    #expect(itemsRequests.filter { $0.headers["Authorization"] == "Bearer new-access" }.count == 5)
    #expect(try store.load(for: account)?.accessToken == "new-access")
  }

  // MARK: - Retried request

  @Test("a retried resource request still 401 after successful rotation retains the rotated pair")
  func retriedResourceUnauthorizedRetainsRotatedTokensAndRequiresReauthentication() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    let transport = ScriptedHTTPClient()
    await transport.stub(
      path: "/items",
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
      ]
    )
    await transport.stub(
      path: "/auth/refresh",
      responses: [makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh")]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }

    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(await transport.requestCount(forPath: "/items") == 2)
    #expect(try store.load(for: account) == TokenPair(accessToken: "new-access", refreshToken: "new-refresh"))
  }

  @Test("a retried 401 surfaces unauthorized without looping into a second refresh")
  func retriedUnauthorizedDoesNotLoop() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    let transport = ScriptedHTTPClient()
    await transport.stub(
      path: "/items",
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
      ]
    )
    await transport.stub(
      path: "/auth/refresh",
      responses: [makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh")]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }

    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(await transport.requestCount(forPath: "/items") == 2)
  }

  // MARK: - Reauthentication latch

  @Test("a 401 for a no-refresh token latches without refresh traffic")
  func noRefresh401LatchesWithoutRefreshTraffic() async throws {
    let initialTokens = TokenPair(accessToken: "api-access", refreshToken: nil)
    let server = try makeServer()
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)
    let events = RecordingRefreshAuthEvents()

    let transport = ScriptedHTTPClient()
    await transport.stub(
      path: "/items", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      authEventObserving: events
    )

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }
    await #expect(throws: APIError.unauthorized) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }

    #expect(await transport.requestCount(forPath: "/items") == 1)
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 0)
    #expect(await events.events == [.reauthenticationRequired(account)])
    #expect(try store.load(for: account) == initialTokens)
  }

  @Test("a rejected refresh latches and suppresses further refresh traffic")
  func rejectedRefreshLatchesAndSuppressesFurtherRefreshTraffic() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    let transport = ScriptedHTTPClient()
    await transport.stub(
      path: "/items",
      responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())]
    )
    await transport.stub(
      path: "/auth/refresh",
      responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(await transport.requestCount(forPath: "/items") == 1)

    // Latched: a further send fails locally without any transport traffic at all.
    await #expect(throws: APIError.unauthorized) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(await transport.requestCount(forPath: "/items") == 1)

    // forceRefresh() must also respect the latch without hitting /auth/refresh again.
    await #expect(throws: APIError.unauthorized) {
      _ = try await client.forceRefresh()
    }
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
  }

  /// Every `forceRefresh` caller (audio download, EPUB download, playback renewal) reaches it only
  /// after a resource already answered 401, so for a no-refresh account that rejection is
  /// definitive and must raise recovery, not merely fail the transfer. A password account latches
  /// through the same path when its refresh is rejected; without the event a listener would get
  /// silence and never be asked to re-authenticate.
  @Test("forceRefresh fails fast for a no-refresh token and raises re-authentication")
  func forceRefreshWithoutRefreshTokenFailsFast() async throws {
    let initialTokens = TokenPair(accessToken: "api-access", refreshToken: nil)
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    try store.save(initialTokens, for: account)
    let transport = ScriptedHTTPClient()
    let events = RecordingRefreshAuthEvents()
    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      authEventObserving: events
    )

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.forceRefresh()
    }
    // A second renewal attempt must stay silent: the latch reports the transition once.
    await #expect(throws: APIError.unauthorized) {
      _ = try await client.forceRefresh()
    }

    #expect(await transport.requestCount(forPath: "/auth/refresh") == 0)
    #expect(await events.events == [.reauthenticationRequired(account)])
    #expect(try store.load(for: account) == initialTokens)
  }
}
