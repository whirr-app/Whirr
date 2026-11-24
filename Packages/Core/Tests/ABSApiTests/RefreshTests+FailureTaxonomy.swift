import Foundation
import TestSupport
import Testing

@testable import ABSApi

extension RefreshTests {
  // MARK: - Transport failure and cancellation

  @Test("a transport failure during refresh retains tokens and releases all waiters with the transport error")
  func refreshTransportFailureRetainsTokensAndReleasesWaitersWithTransport() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    let transport = BlockingRefreshHTTPClient()
    await transport.stub(
      path: "/items",
      responses: Array(repeating: HTTPResponse(statusCode: 401, headers: [:], body: Data()), count: 5)
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

    await transport.releaseRefresh(throwing: FakeHTTPClientError(message: "refresh unreachable"))

    for waiter in waiters {
      await #expect(throws: APIError.transport) {
        _ = try await waiter.value
      }
    }

    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(try store.load(for: account) == initialTokens)
  }

  @Test("a cancelled refresh retains tokens and surfaces cancelled")
  func refreshCancellationRetainsTokensAndSurfacesCancelled() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    let transport = BlockingRefreshHTTPClient()
    await transport.stub(
      path: "/items",
      responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )

    let waiter = Task {
      let request = try makeItemsRequest(server: server)
      async let response = client.send(request)
      await transport.waitUntilRefreshStarted()
      await transport.attachRefreshWaiter()
      return try await response
    }
    await transport.waitUntilRefreshStarted()
    #expect(await waitUntil { await transport.attachedRefreshWaiterCount == 1 })

    await transport.releaseRefresh(throwing: CancellationError())

    await #expect(throws: APIError.cancelled) {
      _ = try await waiter.value
    }

    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(try store.load(for: account) == initialTokens)
  }

  // MARK: - HTTP status taxonomy

  @Test("a 429 from refresh retains tokens and surfaces rate limited")
  func refreshRateLimitRetainsTokensAndSurfacesRateLimited() async throws {
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
      responses: [HTTPResponse(statusCode: 429, headers: [:], body: Data())]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )

    await #expect(throws: APIError.rateLimited) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }

    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(try store.load(for: account) == initialTokens)
  }

  @Test("a 403 from refresh is forbidden, non-destructive, silent, and retryable")
  func refreshForbiddenRetainsTokensDoesNotLatchOrEmitEventAndAllowsRetry() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let rotatedTokens = TokenPair(accessToken: "new-access", refreshToken: "new-refresh")
    let server = try makeServer()
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)
    let rotatedRefreshToken = try #require(rotatedTokens.refreshToken)
    let events = RecordingRefreshAuthEvents()

    let transport = ScriptedHTTPClient()
    await transport.stub(
      path: "/items",
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      ]
    )
    await transport.stub(
      path: "/auth/refresh",
      responses: [
        HTTPResponse(statusCode: 403, headers: [:], body: Data()),
        makeRefreshResponse(accessToken: rotatedTokens.accessToken, refreshToken: rotatedRefreshToken),
      ]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      authEventObserving: events
    )

    await #expect(throws: APIError.forbidden) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }

    #expect(try store.load(for: account) == initialTokens)
    #expect(await events.events.isEmpty)

    // A 403 is not a reauthentication latch: the next 401 may start another refresh.
    let response = try await client.send(try makeItemsRequest(server: server))
    #expect(response.statusCode == 200)
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 2)
    #expect(await transport.requestCount(forPath: "/items") == 3)
    #expect(try store.load(for: account) == rotatedTokens)
    #expect(await events.events.isEmpty)
  }

  @Test("a 500 from refresh retains tokens and surfaces server failure")
  func refreshServerFailureRetainsTokensAndSurfacesServerFailure() async throws {
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
      responses: [HTTPResponse(statusCode: 500, headers: [:], body: Data())]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }

    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(try store.load(for: account) == initialTokens)
  }

  @Test("a malformed 2xx refresh body retains tokens and surfaces decoding")
  func malformedRefreshSuccessRetainsTokensAndSurfacesDecoding() async throws {
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
      responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data("not json".utf8))]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )

    await #expect(throws: APIError.decoding) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }

    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(try store.load(for: account) == initialTokens)
  }

  @Test("an empty refresh token in a successful refresh body remains a decoding failure")
  func emptyRefreshTokenRetainsTokensAndSurfacesDecoding() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    let transport = ScriptedHTTPClient()
    await transport.stub(
      path: "/items", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    await transport.stub(
      path: "/auth/refresh",
      responses: [makeRefreshResponse(accessToken: "new-access", refreshToken: "")]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )

    await #expect(throws: APIError.decoding) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }

    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(try store.load(for: account) == initialTokens)
  }

  @Test("a 401 from refresh retains tokens and surfaces unauthorized")
  func refreshUnauthorizedRetainsTokensAndSurfacesUnauthorized() async throws {
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
    #expect(try store.load(for: account) == initialTokens)
  }

  // MARK: - Waiter cancellation

  @Test("cancelling one waiter does not cancel the shared refresh")
  func cancellationDoesNotCancelSharedRefresh() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    let transport = BlockingRefreshHTTPClient()
    await transport.stub(
      path: "/items",
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      ]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )

    let waiterA = Task {
      let request = try makeItemsRequest(server: server)
      async let response = client.send(request)
      await transport.waitUntilRefreshStarted()
      await transport.attachRefreshWaiter()
      return try await response
    }
    await transport.waitUntilRefreshStarted()

    let waiterB = Task {
      let request = try makeItemsRequest(server: server)
      async let response = client.send(request)
      await transport.waitUntilRefreshStarted()
      await transport.attachRefreshWaiter()
      return try await response
    }
    await waitUntil { await transport.requestCount(forPath: "/items") == 2 }
    #expect(await waitUntil { await transport.attachedRefreshWaiterCount == 2 })

    waiterA.cancel()
    await transport.releaseRefresh(with: makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh"))

    let responseB = try await waiterB.value
    #expect(responseB.statusCode == 200)
    _ = try? await waiterA.value

    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(try store.load(for: account)?.accessToken == "new-access")
  }
}
