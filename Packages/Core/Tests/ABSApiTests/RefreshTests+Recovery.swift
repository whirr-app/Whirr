import Foundation
import TestSupport
import Testing

@testable import ABSApi

extension RefreshTests {
  // MARK: - Admission backoff

  @Test("a transient refresh failure does not latch reauthentication")
  func transientRefreshFailureDoesNotLatchReauthentication() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

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
        HTTPResponse(statusCode: 500, headers: [:], body: Data()),
        makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh"),
      ]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      now: { clock.now() },
      randomUnit: { 1 }
    )

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)

    // Not latched: after the admission window, the next send tries /auth/refresh again and succeeds.
    clock.advance(by: 1.1)
    let response = try await client.send(try makeItemsRequest(server: server))
    #expect(response.statusCode == 200)
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 2)
  }

  @Test("a transient refresh failure closes refresh admission for the next request")
  func transientRefreshFailureClosesAdmission() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
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
      responses: [HTTPResponse(statusCode: 500, headers: [:], body: Data())]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      now: { clock.now() },
      randomUnit: { 1 }
    )

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }
    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }

    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(await transport.requestCount(forPath: "/items") == 2)
  }

  @Test("refresh admission opens after its backoff delay")
  func refreshBackoffOpensAfterDelay() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    let transport = ScriptedHTTPClient()
    await transport.stub(
      path: "/items",
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      ]
    )
    await transport.stub(
      path: "/auth/refresh",
      responses: [
        HTTPResponse(statusCode: 500, headers: [:], body: Data()),
        makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh"),
      ]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      now: { clock.now() },
      randomUnit: { 1 }
    )

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }
    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)

    clock.advance(by: 1.1)
    let response = try await client.send(try makeItemsRequest(server: server))

    #expect(response.statusCode == 200)
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 2)
  }

  @Test("a successful refresh resets the backoff to the first delay")
  func successfulRefreshResetsBackoff() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

    let transport = ScriptedHTTPClient()
    await transport.stub(
      path: "/items",
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      ]
    )
    await transport.stub(
      path: "/auth/refresh",
      responses: [
        HTTPResponse(statusCode: 500, headers: [:], body: Data()),
        makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh"),
        HTTPResponse(statusCode: 500, headers: [:], body: Data()),
        makeRefreshResponse(accessToken: "newer-access", refreshToken: "newer-refresh"),
      ]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      now: { clock.now() },
      randomUnit: { 1 }
    )

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }

    clock.advance(by: 1.1)
    #expect(try await client.send(makeItemsRequest(server: server)).statusCode == 200)

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }

    // A reset makes the first delay one second again, so this attempt is admitted after 1.1s.
    clock.advance(by: 1.1)
    #expect(try await client.send(makeItemsRequest(server: server)).statusCode == 200)
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 4)
  }

  @Test("same-account reauthentication resets refresh admission backoff")
  func replaceTokensResetsRefreshBackoff() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let reauthenticatedTokens = TokenPair(accessToken: "reauth-access", refreshToken: "reauth-refresh")
    let server = try makeServer()
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let store = InMemoryTokenStore()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    try store.save(initialTokens, for: account)

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
        HTTPResponse(statusCode: 500, headers: [:], body: Data()),
        makeRefreshResponse(accessToken: "rotated-access", refreshToken: "rotated-refresh"),
      ]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      now: { clock.now() },
      randomUnit: { 1 }
    )

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }
    await client.replaceTokens(reauthenticatedTokens)

    let response = try await client.send(try makeItemsRequest(server: server))

    #expect(response.statusCode == 200)
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 2)
    let requests = await transport.requests
    #expect(requests[2].headers["Authorization"] == "Bearer reauth-access")
    #expect(requests[3].headers["x-refresh-token"] == "reauth-refresh")
  }

  // MARK: - Gated refresh

  @Test("a gated proactive refresh uses the current token and proceeds")
  func gatedProactiveRefreshDegradesToCurrentTokens() async throws {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let clock = MutableClock(base)
    // `makeAccessToken` truncates `exp` to whole seconds, so a sub-second margin against the
    // default five-minute lead time is unrepresentable (it would round into the proactive window
    // and make the first send proactive too). Use an explicit short lead time instead, so the
    // token is outside the window at `base` and inside it half a second later while still valid.
    let initialTokens = TokenPair(
      accessToken: makeAccessToken(expiry: base.addingTimeInterval(1)),
      refreshToken: "old-refresh"
    )
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
      responses: [HTTPResponse(statusCode: 429, headers: [:], body: Data())]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      proactiveRefreshLeadTime: 0.5,
      now: { clock.now() },
      randomUnit: { 1 }
    )

    await #expect(throws: APIError.rateLimited) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }

    clock.advance(by: 0.5)
    let response = try await client.send(try makeItemsRequest(server: server))

    #expect(response.statusCode == 200)
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    let requests = await transport.requests
    #expect(requests[2].headers["Authorization"] == "Bearer " + initialTokens.accessToken)
  }

  @Test("a gated reactive refresh preserves the transient failure category")
  func gatedReactiveRefreshPreservesRateLimitedCategory() async throws {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server = try makeServer()
    let clock = MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
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
      responses: [HTTPResponse(statusCode: 429, headers: [:], body: Data())]
    )

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      now: { clock.now() },
      randomUnit: { 1 }
    )

    await #expect(throws: APIError.rateLimited) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }
    await #expect(throws: APIError.rateLimited) {
      _ = try await client.send(try makeItemsRequest(server: server))
    }

    #expect(await transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(await transport.requestCount(forPath: "/items") == 2)
  }

  // MARK: - Request timeout

  @Test("a refresh request waits sixty seconds before timing out")
  func refreshRequestUsesLongTimeout() async throws {
    let fixture = try RecoveryFixture()
    await fixture.transport.stub(path: "/items", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    await fixture.transport.stub(
      path: "/auth/refresh",
      responses: [makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh")]
    )
    await fixture.transport.stub(path: "/items", responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    let client = fixture.makeClient(sleeper: RecoverySleeper())

    _ = try await client.send(try makeItemsRequest(server: fixture.server))

    let refresh = try #require(await fixture.transport.requests.first { $0.url.path == "/auth/refresh" })
    #expect(refresh.timeout == 60)
  }

  // MARK: - Unknown-outcome recovery

  @Test("a refresh transport failure retries with the same refresh token and saves the recovered pair")
  func transportFailureRecoversWithSameRefreshToken() async throws {
    let fixture = try RecoveryFixture()
    await fixture.transport.stub(path: "/items", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    await fixture.transport.stubTransportFailure(path: "/auth/refresh")
    await fixture.transport.stub(
      path: "/auth/refresh",
      responses: [makeRefreshResponse(accessToken: "grace-access", refreshToken: "current-refresh")]
    )
    let sleeper = RecoverySleeper()
    let client = fixture.makeClient(sleeper: sleeper)

    await #expect(throws: APIError.transport) {
      _ = try await client.send(try makeItemsRequest(server: fixture.server))
    }

    // The retry runs without any further request and ignores the closed admission gate: the
    // server may already have rotated, and its grace window for the old token is short.
    let recovered = TokenPair(accessToken: "grace-access", refreshToken: "current-refresh")
    #expect(await waitUntil { (try? fixture.store.load(for: fixture.account)) == recovered })
    let refreshes = await fixture.transport.requests.filter { $0.url.path == "/auth/refresh" }
    #expect(refreshes.map { $0.headers["x-refresh-token"] } == ["old-refresh", "old-refresh"])
    #expect(await sleeper.delays == [.seconds(5)])

    await fixture.transport.stub(path: "/items", responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    _ = try await client.send(try makeItemsRequest(server: fixture.server))
    let last = try #require(await fixture.transport.requests.last)
    #expect(last.headers["Authorization"] == "Bearer grace-access")
  }

  @Test("unknown-outcome recovery is bounded to a schedule inside the server grace window")
  func transportFailureRecoveryIsBounded() async throws {
    let fixture = try RecoveryFixture()
    await fixture.transport.stub(path: "/items", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    for _ in 0..<5 { await fixture.transport.stubTransportFailure(path: "/auth/refresh") }
    let sleeper = RecoverySleeper()
    let client = fixture.makeClient(sleeper: sleeper)

    await #expect(throws: APIError.transport) {
      _ = try await client.send(try makeItemsRequest(server: fixture.server))
    }

    #expect(await waitUntil { await fixture.transport.requestCount(forPath: "/auth/refresh") == 5 })
    let schedule: [Duration] = [.seconds(5), .seconds(30), .seconds(120), .seconds(300)]
    #expect(await waitUntil { await sleeper.delays == schedule })
    // ABS accepts a rotated refresh token for ten minutes by default; the whole schedule fits.
    #expect(schedule.reduce(.zero, +) < .seconds(600))
    #expect(try fixture.store.load(for: fixture.account) == fixture.initialTokens)
  }

  @Test("unknown-outcome recovery stops at a definitive rejection")
  func transportFailureRecoveryStopsAtRejection() async throws {
    let fixture = try RecoveryFixture()
    await fixture.transport.stub(path: "/items", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    await fixture.transport.stubTransportFailure(path: "/auth/refresh")
    await fixture.transport.stub(
      path: "/auth/refresh", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    let sleeper = RecoverySleeper()
    let events = RecordingRefreshAuthEvents()
    let client = fixture.makeClient(sleeper: sleeper, events: events)

    await #expect(throws: APIError.transport) {
      _ = try await client.send(try makeItemsRequest(server: fixture.server))
    }

    #expect(await waitUntil { await events.events.contains(.reauthenticationRequired(fixture.account)) })
    #expect(await fixture.transport.requestCount(forPath: "/auth/refresh") == 2)
    #expect(await sleeper.delays == [.seconds(5)])
    await #expect(throws: APIError.unauthorized) {
      _ = try await client.send(try makeItemsRequest(server: fixture.server))
    }
  }

  @Test("a refresh the server answered does not start unknown-outcome recovery")
  func answeredRefreshFailureDoesNotRecover() async throws {
    let fixture = try RecoveryFixture()
    await fixture.transport.stub(path: "/items", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    await fixture.transport.stub(
      path: "/auth/refresh", responses: [HTTPResponse(statusCode: 500, headers: [:], body: Data())])
    let sleeper = RecoverySleeper(holds: true)
    let client = fixture.makeClient(sleeper: sleeper)

    await #expect(throws: APIError.serverFailure(statusCode: 500)) {
      _ = try await client.send(try makeItemsRequest(server: fixture.server))
    }

    await awaitQuiescence("unknown-outcome recovery") {
      "\(await sleeper.delays.count) sleeps, \(await fixture.transport.requestCount(forPath: "/auth/refresh")) refreshes"
    }
    #expect(await sleeper.delays.isEmpty)
    #expect(await fixture.transport.requestCount(forPath: "/auth/refresh") == 1)
  }

  @Test("a successful foreground refresh cancels pending recovery")
  func foregroundRefreshCancelsRecovery() async throws {
    let fixture = try RecoveryFixture()
    await fixture.transport.stub(
      path: "/items",
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),
        HTTPResponse(statusCode: 200, headers: [:], body: Data()),
      ]
    )
    await fixture.transport.stubTransportFailure(path: "/auth/refresh")
    await fixture.transport.stub(
      path: "/auth/refresh",
      responses: [makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh")]
    )
    let sleeper = RecoverySleeper(holds: true)
    let client = fixture.makeClient(sleeper: sleeper)

    await #expect(throws: APIError.transport) {
      _ = try await client.send(try makeItemsRequest(server: fixture.server))
    }
    #expect(await waitUntil { await sleeper.delays.count == 1 })

    fixture.clock.advance(by: 1.1)
    _ = try await client.send(try makeItemsRequest(server: fixture.server))
    await sleeper.releaseAll()

    await awaitQuiescence("unknown-outcome recovery") {
      "\(await sleeper.delays.count) sleeps, \(await fixture.transport.requestCount(forPath: "/auth/refresh")) refreshes"
    }
    #expect(await sleeper.delays.count == 1)
    #expect(await fixture.transport.requestCount(forPath: "/auth/refresh") == 2)
    #expect(
      try fixture.store.load(for: fixture.account) == TokenPair(accessToken: "new-access", refreshToken: "new-refresh"))
  }

  @Test("logout cancels pending unknown-outcome recovery")
  func logoutCancelsRecovery() async throws {
    let fixture = try RecoveryFixture()
    await fixture.transport.stub(path: "/items", responses: [HTTPResponse(statusCode: 401, headers: [:], body: Data())])
    await fixture.transport.stubTransportFailure(path: "/auth/refresh")
    await fixture.transport.stub(
      path: "/auth/refresh",
      responses: [makeRefreshResponse(accessToken: "stale-access", refreshToken: "stale-refresh")]
    )
    let sleeper = RecoverySleeper(holds: true)
    let client = fixture.makeClient(sleeper: sleeper)

    await #expect(throws: APIError.transport) {
      _ = try await client.send(try makeItemsRequest(server: fixture.server))
    }
    #expect(await waitUntil { await sleeper.delays.count == 1 })

    await client.invalidateForLogout()
    try fixture.store.clear(for: fixture.account)
    await sleeper.releaseAll()

    await awaitQuiescence("unknown-outcome recovery") {
      "\(await sleeper.delays.count) sleeps, \(await fixture.transport.requestCount(forPath: "/auth/refresh")) refreshes"
    }
    #expect(await sleeper.delays.count == 1)
    #expect(await fixture.transport.requestCount(forPath: "/auth/refresh") == 1)
    #expect(try fixture.store.load(for: fixture.account) == nil)
  }

  // MARK: - Logout fence

  @Test("logout fences a held refresh before clearing the token store")
  func logoutFencesHeldRefreshBeforeClearingTheTokenStore() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.save(initialTokens, for: account)
    let transport = BlockingRefreshHTTPClient()
    await transport.stub(
      path: "/logout", responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    let events = RecordingRefreshAuthEvents()
    let client = ABSClient(
      server: server, httpClient: transport, tokenStore: store, authEventObserving: events)
    let cached = try await client.authenticatedTransport(for: account, initialTokens: initialTokens)

    let refresh = Task { try await cached.forceRefresh() }
    await transport.waitUntilRefreshStarted()

    // The epoch fence makes logout independent of a held transport continuation. Releasing the
    // response below proves the old task cannot save or apply its rotated pair after the clear.
    let logout = Task { try? await client.logout(for: account) }
    _ = await logout.value
    #expect(try store.load(for: account) == nil)

    await transport.releaseRefresh(
      with: makeRefreshResponse(accessToken: "stale-access", refreshToken: "stale-refresh"))
    await #expect(throws: APIError.cancelled) { _ = try await refresh.value }
    #expect(try store.load(for: account) == nil)
    #expect(await events.events.isEmpty)
  }

  @Test("a client invalidated by logout can never start a new refresh")
  func invalidatedClientNeverStartsANewRefresh() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.save(initialTokens, for: account)
    let transport = BlockingRefreshHTTPClient()
    await transport.stub(
      path: "/logout", responses: [HTTPResponse(statusCode: 200, headers: [:], body: Data())])
    let events = RecordingRefreshAuthEvents()
    let client = ABSClient(
      server: server, httpClient: transport, tokenStore: store, authEventObserving: events)
    // A caller (e.g. an in-flight download renewal) can hold the cached transport across logout;
    // the epoch fence only revokes the refresh that was already running, so the invalidation flag
    // must refuse a new refresh started after the store was cleared.
    let cached = try await client.authenticatedTransport(for: account, initialTokens: initialTokens)

    try await client.logout(for: account)
    #expect(try store.load(for: account) == nil)

    await #expect(throws: APIError.cancelled) { _ = try await cached.forceRefresh() }
    #expect(await transport.requestCount(forPath: "/auth/refresh") == 0)
    #expect(try store.load(for: account) == nil)
    #expect(await events.events.isEmpty)
  }
}
