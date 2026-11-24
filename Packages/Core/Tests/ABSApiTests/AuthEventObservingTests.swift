import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// The credential-free `AuthEventObserving` seam `ABSClient.production` accepts. Latch behaviour
/// is covered in `RefreshTests.swift` and token replacement in `ReauthenticationTests.swift`; this
/// file only proves when and how many times an event fires.
@Suite("Auth recovery event observing")
struct AuthEventObservingTests {
  @Test(
    "a definitive refresh rejection, and separately a retried-request-still-401, each emit exactly one reauthenticationRequired event"
  )
  func definitiveRefreshRejectionEmitsOneRecoveryRequiredEvent() async throws {
    // Scenario 1: the refresh call itself comes back 401.
    do {
      let server = try makeServer()
      let account = try TokenAccount(server: server, userID: "user_fixture")
      let store = InMemoryTokenStore()
      let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
      try store.save(initialTokens, for: account)
      let observer = RecordingAuthEventObserving()

      let transport = FakeHTTPClient(
        responses: [
          HTTPResponse(statusCode: 401, headers: [:], body: Data()),  // /items
          HTTPResponse(statusCode: 401, headers: [:], body: Data()),  // /auth/refresh -> latches
        ]
      )
      let client = AuthenticatedHTTPClient(
        transport: transport,
        requestBuilder: RequestBuilder(server: server),
        tokenStore: store,
        account: account,
        initialTokens: initialTokens,
        authEventObserving: observer
      )

      await #expect(throws: APIError.unauthorized) {
        _ = try await client.send(makeItemsRequest(server: server))
      }
      // A second call while still latched must not re-emit.
      await #expect(throws: APIError.unauthorized) {
        _ = try await client.send(makeItemsRequest(server: server))
      }

      let events = await observer.events
      #expect(events == [.reauthenticationRequired(account)])
    }

    // Scenario 2: refresh rotates successfully, but the retried resource request is still 401.
    do {
      let server = try makeServer()
      let account = try TokenAccount(server: server, userID: "user_fixture")
      let store = InMemoryTokenStore()
      let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
      try store.save(initialTokens, for: account)
      let observer = RecordingAuthEventObserving()

      let transport = FakeHTTPClient(
        responses: [
          HTTPResponse(statusCode: 401, headers: [:], body: Data()),  // /items
          makeRefreshResponse(accessToken: "new-access", refreshToken: "new-refresh"),  // /auth/refresh
          HTTPResponse(statusCode: 401, headers: [:], body: Data()),  // /items retry -> still 401
        ]
      )
      let client = AuthenticatedHTTPClient(
        transport: transport,
        requestBuilder: RequestBuilder(server: server),
        tokenStore: store,
        account: account,
        initialTokens: initialTokens,
        authEventObserving: observer
      )

      await #expect(throws: APIError.unauthorized) {
        _ = try await client.send(makeItemsRequest(server: server))
      }
      await #expect(throws: APIError.unauthorized) {
        _ = try await client.send(makeItemsRequest(server: server))
      }

      let events = await observer.events
      #expect(events == [.reauthenticationRequired(account)])
    }
  }

  @Test("refresh failures emit their credential-free diagnostic events without requesting reauthentication")
  func refreshFailuresEmitDiagnosticEventsWithoutRecoveryRequired() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")

    let unauthorized = HTTPResponse(statusCode: 401, headers: [:], body: Data())

    // Transport failure: no canned refresh response, so the fake throws for the refresh request.
    try await assertRefreshEvent(
      .refreshTransport(account), server: server, account: account,
      responses: [unauthorized])

    // 429.
    try await assertRefreshEvent(
      .refreshRateLimited(account), server: server, account: account,
      responses: [unauthorized, HTTPResponse(statusCode: 429, headers: [:], body: Data())])

    // 5xx.
    try await assertRefreshEvent(
      .refreshServerFailure(account), server: server, account: account,
      responses: [unauthorized, HTTPResponse(statusCode: 500, headers: [:], body: Data())])

    // Malformed 2xx (decoding failure).
    try await assertRefreshEvent(
      .refreshDecoding(account), server: server, account: account,
      responses: [
        unauthorized, HTTPResponse(statusCode: 200, headers: [:], body: Data("not json".utf8)),
      ])
  }

  @Test("a successful reauthentication emits reauthenticationSucceeded only after tokens are saved and installed")
  func successfulReauthenticationEmitsRecoveredAfterTokensAreInstalled() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.save(initialTokens, for: account)

    // Observes both the event and, at the moment it fires, whether the token store and cached
    // transport already reflect the replacement pair, proving install-then-event ordering.
    let observer = OrderProvingAuthEventObserving(store: store, account: account)

    let transport = FakeHTTPClient(
      responses: [
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),  // /items
        HTTPResponse(statusCode: 401, headers: [:], body: Data()),  // /auth/refresh -> latches
      ]
    )
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store, authEventObserving: observer)

    await #expect(throws: APIError.unauthorized) {
      _ = try await client.authenticatedSend(
        makeItemsRequest(server: server), account: account, initialTokens: initialTokens)
    }

    transport.enqueue(
      try makeLoginResponse(userID: "user_fixture", accessToken: "new-access", refreshToken: "new-refresh"))

    _ = try await client.reauthenticate(
      credentials: LoginCredentials(username: "fixture-user", password: "fixture-password"),
      expectedAccount: account
    )

    let events = await observer.events
    // The setup step latches the account first (a `.reauthenticationRequired` is expected there).
    // This asserts only the recovery event: one `.reauthenticationSucceeded`, recorded last.
    #expect(events.filter { $0 == .reauthenticationSucceeded(account) }.count == 1)
    #expect(events.last == .reauthenticationSucceeded(account))
    #expect(await observer.tokensWereSavedWhenEventFired == true)
  }

  // MARK: - Helpers

  private func assertRefreshEvent(
    _ expectedEvent: AuthEvent,
    server: ABSServerConfig,
    account: TokenAccount,
    responses: [HTTPResponse]
  ) async throws {
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    try store.save(initialTokens, for: account)
    let observer = RecordingAuthEventObserving()
    // One sequential flow, so queue order is request order: the `/items` 401, then the refresh.
    let transport = FakeHTTPClient(responses: responses)

    let client = AuthenticatedHTTPClient(
      transport: transport,
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens,
      authEventObserving: observer
    )

    await #expect(throws: (any Error).self) {
      _ = try await client.send(makeItemsRequest(server: server))
    }

    let events = await observer.events
    #expect(events == [expectedEvent])
  }
}

private func makeServer() throws -> ABSServerConfig {
  try ABSServerConfig(url: URL(string: "https://books.example.test")!)
}

private func makeItemsRequest(server: ABSServerConfig) -> HTTPRequest {
  try! RequestBuilder(server: server).makeRequest(method: .get, path: "/items", routeTemplate: "/items")
}

private func makeRefreshResponse(accessToken: String, refreshToken: String) -> HTTPResponse {
  let body = try! JSONSerialization.data(
    withJSONObject: ["user": ["accessToken": accessToken, "refreshToken": refreshToken]]
  )
  return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
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

private actor RecordingAuthEventObserving: AuthEventObserving {
  private(set) var events: [AuthEvent] = []

  func authEvent(_ event: AuthEvent) async {
    events.append(event)
  }
}

/// Records the event and, at the instant it arrives, whether `store`/cached transport already
/// carry the replacement pair, proving the recovered event fires only after save and install.
private actor OrderProvingAuthEventObserving: AuthEventObserving {
  private(set) var events: [AuthEvent] = []
  private(set) var tokensWereSavedWhenEventFired = false
  private let store: any TokenStoring
  private let account: TokenAccount

  init(store: any TokenStoring, account: TokenAccount) {
    self.store = store
    self.account = account
  }

  func authEvent(_ event: AuthEvent) async {
    events.append(event)
    if case .reauthenticationSucceeded = event {
      tokensWereSavedWhenEventFired = (try? store.load(for: account))?.accessToken == "new-access"
    }
  }
}
