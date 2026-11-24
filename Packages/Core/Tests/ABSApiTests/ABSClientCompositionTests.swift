import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// Proves the production pipeline described in ARCHITECTURE.md:
///
///   ABSClient endpoint methods
///     → AuthenticatedHTTPClient (Bearer injection; single-flight refresh)
///     → ServerRequestGate (FIFO; at most four in flight)
///     → RedactingHTTPLogger (metadata only)
///     → URLSessionHTTPClient (a fake, here)
///
/// Exercises the internal `authenticatedSend` seam via `@testable import`. Login/logout are
/// covered in AuthenticationTests.swift.
@Suite("ABSClient composition", .timeLimit(.minutes(1)))
struct ABSClientCompositionTests {

  @Test("a single authenticated request passes through auth, gate, logging, and bounds in order")
  func fullPipelineAppliesEveryDecorator() async throws {
    let server = try ABSServerConfig(
      url: #require(URL(string: "https://books.example.test")),
      customHeaders: try CustomHeaders(["X-Proxy-Token": "proxy-secret"])
    )
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "canary-initial-access", refreshToken: "canary-initial-refresh")
    try store.save(initialTokens, for: account)

    let transport = CompositionTransport(
      autoResponse: HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"], body: Data("{}".utf8)))
    let logger = RedactingHTTPLogger()
    let client = ABSClient(server: server, httpClient: transport.client, tokenStore: store, logger: logger)

    let response = try await client.authenticatedSend(
      makeItemsRequest(server: server),
      account: account,
      initialTokens: initialTokens
    )

    #expect(response.statusCode == 200)

    let sent = transport.client.requests
    #expect(sent.count == 1)
    // AuthenticatedHTTPClient attached the Bearer header.
    #expect(sent[0].headers["Authorization"] == "Bearer canary-initial-access")
    // RequestBuilder's MIME negotiation (Accept header) survives the pipeline untouched.
    #expect(sent[0].headers["Accept"] == "application/json")
    #expect(sent[0].headers["X-Proxy-Token"] == "proxy-secret")

    // RedactingHTTPLogger recorded metadata for the request and never the token.
    let entries = await logger.formattedEntries()
    #expect(entries.count == 1)
    #expect(entries[0].contains("200"))
    #expect(entries.joined().contains("canary-initial-access") == false)

    // ServerRequestGate admitted it (bound respected for a single in-flight request).
    #expect(transport.maxInFlight <= 4)
  }

  @Test("a composed transport failure logs metadata only")
  func composedFailureLoggingRedactsTransportErrorAndBearerToken() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let accessToken = "request-token-canary"
    let initialTokens = TokenPair(accessToken: accessToken, refreshToken: "refresh-token-canary")
    try store.save(initialTokens, for: account)

    let errorDescription = "transport-error-canary"
    let transport = FakeHTTPClient(failure: FakeHTTPClientError(message: errorDescription))
    let logger = RedactingHTTPLogger()
    let client = ABSClient(server: server, httpClient: transport, tokenStore: store, logger: logger)

    await #expect(throws: FakeHTTPClientError.self) {
      _ = try await client.authenticatedSend(
        makeItemsRequest(server: server),
        account: account,
        initialTokens: initialTokens
      )
    }

    let sent = try #require(transport.requests.first)
    #expect(sent.headers["Authorization"] == "Bearer \(accessToken)")

    let entries = await logger.formattedEntries()
    #expect(entries.count == 1)
    #expect(entries[0].contains("GET"))
    #expect(entries[0].contains("/items"))
    #expect(entries[0].contains("books.example.test") == false)
    #expect(entries[0].contains("status=error"))
    // `recordFailure` accepts no error text; retain this canary as a security regression guard.
    #expect(entries.joined(separator: "\n").contains(errorDescription) == false)
    #expect(entries.joined(separator: "\n").contains(accessToken) == false)
  }

  @Test("an oversized authenticated response is still rejected by the bounded decoder")
  func boundedDecodingAppliesToAuthenticatedResponses() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "access", refreshToken: "refresh")
    try store.save(initialTokens, for: account)

    let oversized = Data(repeating: 0x61, count: 26 * 1024 * 1024)
    let transport = CompositionTransport(
      autoResponse: HTTPResponse(statusCode: 200, headers: [:], body: oversized))
    let client = ABSClient(server: server, httpClient: transport.client, tokenStore: store)

    let response = try await client.authenticatedSend(
      makeItemsRequest(server: server),
      account: account,
      initialTokens: initialTokens
    )

    #expect(response.body.count == oversized.count)
    #expect(throws: APIError.payloadTooLarge) {
      _ = try BoundedDecoder().decode([String: String].self, from: response.body, endpoint: "/items")
    }
  }

  @Test(
    "saturating the gate with five concurrent 401s completes exactly one refresh without deadlock, never exceeds four in flight, and retries re-enter FIFO"
  )
  func fiveConcurrent401sSaturateGateWithoutDeadlock() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "initial-access", refreshToken: "initial-refresh")
    try store.save(initialTokens, for: account)

    let transport = CompositionTransport()
    transport.items.hold()
    let client = ABSClient(server: server, httpClient: transport.client, tokenStore: store)
    let request = makeItemsRequest(server: server)

    let tasks = (0..<5).map { _ in
      Task { try await client.authenticatedSend(request, account: account, initialTokens: initialTokens) }
    }

    // The gate admits exactly four; the fifth queues inside ServerRequestGate.
    await waitUntil { transport.currentInFlight == 4 }
    #expect(transport.currentInFlight == 4)
    #expect(transport.maxInFlight == 4)
    #expect(transport.requestCount(routeTemplate: "/items") == 4)

    // Releasing the first four with 401 frees their permits immediately (before any refresh is
    // awaited), which is what lets the queued fifth be admitted next.
    await transport.items.waitUntilParked(count: 4)
    transport.items.releaseParked(HTTPResponse(statusCode: 401, headers: [:], body: Data()))
    await transport.items.waitUntilParked(count: 1)
    #expect(transport.requestCount(routeTemplate: "/items") == 5)
    transport.items.releaseParked(HTTPResponse(statusCode: 401, headers: [:], body: Data()))

    // All five 401s coalesce onto exactly one refresh, which itself traverses the same gate.
    await transport.refresh.waitUntilParked()
    #expect(transport.maxInFlight <= 4)
    transport.items.release(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    transport.refresh.release(
      makeRefreshResponse(accessToken: "rotated-access", refreshToken: "rotated-refresh")
    )

    for task in tasks {
      let response = try await task.value
      #expect(response.statusCode == 200)
    }

    #expect(transport.requestCount(routeTemplate: "/auth/refresh") == 1)
    #expect(transport.requestCount(routeTemplate: "/items") == 10)
    #expect(transport.maxInFlight <= 4)

    let allItemRequests = transport.client.requests.filter { $0.routeTemplate == "/items" }
    let firstWave = allItemRequests.prefix(5).map { $0.headers["Authorization"] }
    let secondWave = allItemRequests.suffix(5).map { $0.headers["Authorization"] }
    #expect(firstWave.allSatisfy { $0 == "Bearer initial-access" })
    #expect(secondWave.allSatisfy { $0 == "Bearer rotated-access" })
    #expect(try store.load(for: account)?.accessToken == "rotated-access")
  }

  // MARK: - Mutation checks: each proves a named assertion above would fail if its decorator
  // were bypassed, by actually constructing the under-composed pipeline and observing the
  // different outcome.

  @Test("bypassing AuthenticatedHTTPClient would break the Authorization-header assertion")
  func bypassingAuthDecoratorOmitsAuthorizationHeader() async throws {
    let server = try makeServer()
    let transport = CompositionTransport()
    let logger = RedactingHTTPLogger()
    let gate = ServerRequestGate()
    // Composition without AuthenticatedHTTPClient.
    let bypassed: any HTTPClienting = GatedHTTPClient(
      transport: LoggingHTTPClient(transport: transport.client, logger: logger),
      gate: gate
    )

    _ = try await bypassed.send(makeItemsRequest(server: server))

    let sent = transport.client.requests
    // `fullPipelineAppliesEveryDecorator` asserts `Authorization == "Bearer ..."`; without the
    // auth decorator there is no header at all, so that assertion would fail here.
    #expect(sent[0].headers["Authorization"] == nil)
  }

  @Test("bypassing ServerRequestGate would break the max-four-in-flight assertion")
  func bypassingGateAllowsMoreThanFourInFlight() async throws {
    let server = try makeServer()
    let account = try TokenAccount(server: server, userID: "user_fixture")
    let store = InMemoryTokenStore()
    let initialTokens = TokenPair(accessToken: "access", refreshToken: "refresh")
    try store.save(initialTokens, for: account)

    let transport = CompositionTransport()
    transport.items.hold()
    let logger = RedactingHTTPLogger()
    // No ServerRequestGate: Auth wraps Logger wraps the raw transport directly.
    let bypassed = AuthenticatedHTTPClient(
      transport: LoggingHTTPClient(transport: transport.client, logger: logger),
      requestBuilder: RequestBuilder(server: server),
      tokenStore: store,
      account: account,
      initialTokens: initialTokens
    )
    let request = makeItemsRequest(server: server)

    let tasks = (0..<5).map { _ in Task { try await bypassed.send(request) } }
    await waitUntil { transport.currentInFlight == 5 }
    // `fiveConcurrent401sSaturateGateWithoutDeadlock` asserts in-flight never exceeds four;
    // without the gate all five run concurrently, so that assertion would fail here.
    #expect(transport.currentInFlight == 5)

    transport.items.release(HTTPResponse(statusCode: 200, headers: [:], body: Data()))
    for task in tasks { _ = try await task.value }
  }

  @Test("bypassing RedactingHTTPLogger would break the log-entries-recorded assertion")
  func bypassingLoggerRecordsNoEntries() async throws {
    let server = try makeServer()
    let transport = CompositionTransport()
    let logger = RedactingHTTPLogger()
    let gate = ServerRequestGate()
    // No LoggingHTTPClient: the gate wraps the raw transport directly.
    let bypassed: any HTTPClienting = GatedHTTPClient(transport: transport.client, gate: gate)

    _ = try await bypassed.send(makeItemsRequest(server: server))

    let entries = await logger.formattedEntries()
    // `fullPipelineAppliesEveryDecorator` asserts exactly one recorded entry; without the
    // logging decorator nothing is ever recorded, so that assertion would fail here.
    #expect(entries.isEmpty)
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

private struct InFlight: Sendable {
  var current = 0
  var peak = 0
}

/// Raw transport for composition tests, built on `FakeHTTPClient`. In-flight counts are observed
/// behind the gate (only admitted calls ever reach it). `/items` answers `autoResponse` unless the
/// test holds `items`, and `/auth/refresh` always parks on `refresh` until the test releases it.
private struct CompositionTransport: Sendable {
  let client: FakeHTTPClient
  let items: TestGate<HTTPResponse>
  let refresh: TestGate<HTTPResponse>
  private let inFlight: Locked<InFlight>

  init(
    autoResponse: HTTPResponse = HTTPResponse(statusCode: 200, headers: [:], body: Data())
  ) {
    let items = TestGate<HTTPResponse>(label: "composition /items")
    let refresh = TestGate<HTTPResponse>(label: "composition /auth/refresh")
    refresh.hold()
    let inFlight = Locked(InFlight())
    self.inFlight = inFlight
    self.items = items
    self.refresh = refresh
    client = FakeHTTPClient { request in
      inFlight.withValue {
        $0.current += 1
        $0.peak = max($0.peak, $0.current)
      }
      defer { inFlight.withValue { $0.current -= 1 } }
      if request.routeTemplate == "/auth/refresh" {
        return await refresh.pass(otherwise: { autoResponse })
      }
      return await items.pass(otherwise: { autoResponse })
    }
  }

  var currentInFlight: Int { inFlight.value.current }
  var maxInFlight: Int { inFlight.value.peak }

  func requestCount(routeTemplate: String) -> Int {
    client.requests.filter { $0.routeTemplate == routeTemplate }.count
  }
}
