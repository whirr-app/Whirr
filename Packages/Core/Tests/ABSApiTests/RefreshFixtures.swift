import Foundation
import TestSupport
import Testing

@testable import ABSApi

extension RefreshTests {
  // MARK: - Fixtures

  func makeServer() throws -> ABSServerConfig {
    try ABSServerConfig(url: URL(string: "https://books.example.test")!)
  }

  func makeItemsRequest(server: ABSServerConfig) throws -> HTTPRequest {
    try RequestBuilder(server: server).makeRequest(
      method: .get,
      path: "/items",
      routeTemplate: "/items"
    )
  }

  func makeRefreshResponse(accessToken: String, refreshToken: String) -> HTTPResponse {
    let body = try! JSONSerialization.data(
      withJSONObject: ["user": ["accessToken": accessToken, "refreshToken": refreshToken]]
    )
    return HTTPResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
  }

  func makeAccessToken(expiry: Date?) -> String {
    guard let expiry else { return "not-a-jwt" }
    let header = Data(#"{"alg":"none","typ":"JWT"}"#.utf8)
    let payload = Data(#"{"exp":\#(Int(expiry.timeIntervalSince1970)),"userId":"user_fixture"}"#.utf8)
    return [header, payload].map(base64URLEncoded).joined(separator: ".") + ".signature"
  }

  func base64URLEncoded(_ data: Data) -> String {
    data.base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .trimmingCharacters(in: CharacterSet(charactersIn: "="))
  }

  final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
      self.date = date
    }

    func now() -> Date {
      lock.lock()
      defer { lock.unlock() }
      return date
    }

    func advance(by interval: TimeInterval) {
      lock.lock()
      date = date.addingTimeInterval(interval)
      lock.unlock()
    }
  }

  // Kept: about 25 call sites in RefreshTests*.swift (outside this packet) use its per-path stub,
  // transport-failure and `requestCount` API, which FakeHTTPClient lacks.
  /// Per-path FIFO canned responses so concurrent calls to distinct endpoints (original request
  /// vs. `/auth/refresh`) can't race against each other's response order.
  actor ScriptedHTTPClient: HTTPClienting {
    private enum Outcome {
      case response(HTTPResponse)
      case transportFailure
    }

    private var queues: [String: [Outcome]] = [:]
    private(set) var requests: [HTTPRequest] = []

    func stub(path: String, responses: [HTTPResponse]) {
      queues[path, default: []].append(contentsOf: responses.map(Outcome.response))
    }

    /// Queues a thrown transport error in FIFO order with `stub(path:responses:)`, standing in for a
    /// request whose response never arrived (a timeout or dropped connection).
    func stubTransportFailure(path: String) {
      queues[path, default: []].append(.transportFailure)
    }

    func requestCount(forPath path: String) -> Int {
      requests.filter { $0.url.path == path }.count
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
      requests.append(request)
      guard var queue = queues[request.url.path], queue.isEmpty == false else {
        throw FakeHTTPClientError(message: "no stubbed response for \(request.url.path)")
      }
      let outcome = queue.removeFirst()
      queues[request.url.path] = queue
      switch outcome {
      case .response(let response): return response
      case .transportFailure: throw FakeHTTPClientError(message: "scripted transport failure")
      }
    }
  }

  /// Stands in for the unknown-outcome recovery schedule's sleep: records every requested delay and
  /// either returns at once or holds until the test releases it, so no test waits on real time.
  actor RecoverySleeper {
    private let holds: Bool
    private(set) var delays: [Duration] = []
    // The sleep is not cancellation-aware: a cancelled recovery task stays parked until released.
    private nonisolated let gate = TestGate<Void>(
      label: "RecoverySleeper sleep", ignoresCancellation: true)

    private var released = 0

    init(holds: Bool = false) {
      self.holds = holds
      if holds { gate.hold() }
    }

    func sleep(for delay: Duration) async {
      delays.append(delay)
      guard holds else { return }
      await gate.pass()
    }

    func releaseAll() async {
      // A sleep records its delay before it parks, so wait for the parks this release must free.
      let pending = delays.count - released
      if holds, pending > 0 { await gate.waitUntilParked(count: pending) }
      released = delays.count
      gate.releaseParked()
    }
  }

  // Kept: RefreshTests*.swift (outside this packet) drive its waiter count, per-path stubs and
  // throwing release; a FakeHTTPClient handler would need the same wrapper API.
  /// Blocks the `/auth/refresh` call under manual control (like BlockingLogoutHTTPClient in
  /// AuthenticationTests.swift). Makes the concurrent-401 tests deterministic: with an
  /// instantly-resolving fake, the first waiter to reach `/auth/refresh` could finish and reset the
  /// shared task before a sibling still queued behind its own 401 attaches to it. Holding the
  /// refresh open until every original request has landed removes that race without any sleep.
  actor BlockingRefreshHTTPClient: HTTPClienting {
    private var queues: [String: [HTTPResponse]] = [:]
    private(set) var requests: [HTTPRequest] = []
    private(set) var attachedRefreshWaiterCount = 0
    // The refresh is not cancellation-aware: logout must not free it, only the test's release.
    private nonisolated let refreshGate = TestGate<Result<HTTPResponse, Error>>(
      label: "BlockingRefreshHTTPClient /auth/refresh", ignoresCancellation: true)

    init() {
      refreshGate.hold()
    }

    func stub(path: String, responses: [HTTPResponse]) {
      queues[path, default: []].append(contentsOf: responses)
    }

    func requestCount(forPath path: String) -> Int {
      requests.filter { $0.url.path == path }.count
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
      requests.append(request)
      guard request.url.path == "/auth/refresh" else {
        guard var queue = queues[request.url.path], queue.isEmpty == false else {
          throw FakeHTTPClientError(message: "no stubbed response for \(request.url.path)")
        }
        let response = queue.removeFirst()
        queues[request.url.path] = queue
        return response
      }

      return try await refreshGate.pass(otherwise: { .failure(CancellationError()) }).get()
    }

    func waitUntilRefreshStarted() async {
      await refreshGate.waitUntilParked()
    }

    func attachRefreshWaiter() {
      attachedRefreshWaiterCount += 1
    }

    func releaseRefresh(with response: HTTPResponse) {
      refreshGate.releaseParked(.success(response))
    }

    func releaseRefresh(throwing error: Error) {
      refreshGate.releaseParked(.failure(error))
    }
  }

  actor RecordingRefreshAuthEvents: AuthEventObserving {
    private(set) var events: [AuthEvent] = []

    func authEvent(_ event: AuthEvent) async {
      events.append(event)
    }
  }

  /// One account, store, clock and scripted transport for the unknown-outcome recovery tests, so each
  /// test only states the responses and sleeper behaviour it is about.
  struct RecoveryFixture {
    let initialTokens = TokenPair(accessToken: "old-access", refreshToken: "old-refresh")
    let server: ABSServerConfig
    let account: TokenAccount
    let store = InMemoryTokenStore()
    let clock = RefreshTests.MutableClock(Date(timeIntervalSince1970: 1_700_000_000))
    let transport = RefreshTests.ScriptedHTTPClient()

    init() throws {
      server = try RefreshTests().makeServer()
      account = try TokenAccount(server: server, userID: "user_fixture")
      try store.save(initialTokens, for: account)
    }

    func makeClient(
      sleeper: RefreshTests.RecoverySleeper, events: any AuthEventObserving = NoOpAuthEventObserving()
    ) -> AuthenticatedHTTPClient {
      let clock = self.clock
      return AuthenticatedHTTPClient(
        transport: transport,
        requestBuilder: RequestBuilder(server: server),
        tokenStore: store,
        account: account,
        initialTokens: initialTokens,
        authEventObserving: events,
        now: { clock.now() },
        randomUnit: { 1 },
        sleep: { await sleeper.sleep(for: $0) }
      )
    }
  }
}
