import ABSApi
import Foundation
import TestSupport
import Testing

@testable import PodcastFeeds

@Suite("Feed fetch client", .timeLimit(.minutes(1)))
struct FeedFetchClientTests {
  @Test("constructs a redacted, bounded feed request")
  func requestShape() async throws {
    let transport = scriptedTransport(responses: [.success(response())])
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/show.xml"))
    let client = FeedFetchClient(httpClient: transport)

    if case .fetched = try await client.fetch(endpoint) {} else { Issue.record("expected fetch") }

    let request = try #require(transport.requests.first)
    #expect(request.method == .get)
    #expect(
      request.headers["Accept"] == "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8")
    #expect(request.headers["Authorization"] == nil)
    #expect(request.routeTemplate == endpoint.routeTemplate)
    #expect(request.maximumResponseBytes == FeedFetchClient.maximumFeedBytes)
  }

  @Test("response equality remains based on its public payload")
  func responseEquality() async throws {
    let transport = scriptedTransport(responses: [.success(response())])
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/equality.xml"))
    let client = FeedFetchClient(httpClient: transport)

    guard case .fetched(let fetched) = try await client.fetch(endpoint) else {
      Issue.record("expected fetch")
      return
    }

    #expect(
      fetched
        == FeedFetchResponse(
          body: Data("feed".utf8), headers: ["ETag": "tag"]))
  }

  @Test("rejects an oversized body from a transport that ignores the request cap")
  func rejectsOversizedBodyFromInjectedTransport() async throws {
    let response = HTTPResponse(
      statusCode: 200, headers: [:],
      body: Data(repeating: 0x20, count: FeedFetchClient.maximumFeedBytes + 1))
    let transport = scriptedTransport(responses: [.success(response)])
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/oversized.xml"))
    let client = FeedFetchClient(httpClient: transport)

    await #expect(throws: APIError.payloadTooLarge) {
      try await client.fetch(endpoint)
    }
    #expect(transport.requests.first?.maximumResponseBytes == FeedFetchClient.maximumFeedBytes)
  }

  @Test("stamps the current feed credential when each request is minted")
  func stampsCurrentCredentialAtMintTime() async throws {
    let transport = scriptedTransport(responses: [.success(response()), .success(response())])
    let credentials = InMemoryFeedCredentialStore()
    let reference = try #require(FeedEndpoint.CredentialReference(id: "41"))
    let endpoint = try #require(
      FeedEndpoint(
        string: "https://feeds.example.test/private.xml", credentialReference: reference))
    let first = try FeedCredential.basic(username: "first", password: "secret-one")
    let second = try FeedCredential.basic(username: "second", password: "secret-two")
    try credentials.save(first, forFeedID: 41)
    let client = FeedFetchClient(httpClient: transport, credentialStore: credentials)

    _ = try await client.fetch(endpoint)
    try credentials.save(second, forFeedID: 41)
    _ = try await client.fetch(endpoint)

    let requests = transport.requests
    #expect(requests.map { $0.headers["Authorization"] } == [first.authorization, second.authorization])
    for request in requests {
      let rendered = String(reflecting: request)
      #expect(rendered.contains("secret-one") == false)
      #expect(rendered.contains("secret-two") == false)
      #expect(rendered.contains(first.authorization) == false)
      #expect(rendered.contains(second.authorization) == false)
    }
  }

  @Test("does not coalesce requests minted with different credentials")
  func credentialChangesSeparateFlights() async throws {
    let transport = scriptedTransport(responses: [.success(response()), .success(response())])
    transport.gate.hold()
    let credentials = InMemoryFeedCredentialStore()
    let reference = try #require(FeedEndpoint.CredentialReference(id: "7"))
    let endpoint = try #require(
      FeedEndpoint(string: "https://feeds.example.test/private.xml", credentialReference: reference))
    try credentials.save(try FeedCredential(authorization: "Bearer first"), forFeedID: 7)
    let client = FeedFetchClient(httpClient: transport, credentialStore: credentials)

    let first = Task { try await client.fetch(endpoint) }
    #expect(await waitUntil { transport.requests.count == 1 })
    try credentials.save(try FeedCredential(authorization: "Bearer second"), forFeedID: 7)
    let second = Task { try await client.fetch(endpoint) }
    #expect(await waitUntil { transport.requests.count == 2 })
    transport.gate.release(response())
    _ = try await first.value
    _ = try await second.value

    let requests = transport.requests
    #expect(requests.map { $0.headers["Authorization"] } == ["Bearer first", "Bearer second"])
  }

  @Test("accepts an ephemeral preview credential without a persisted feed identity")
  func ephemeralCredential() async throws {
    let transport = scriptedTransport(responses: [.success(response())])
    let client = FeedFetchClient(httpClient: transport)
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/new-private.xml"))
    let credential = try FeedCredential.basic(username: "preview", password: "only")

    _ = try await client.fetch(endpoint, credential: credential)

    #expect(transport.requests.first?.headers["Authorization"] == credential.authorization)
  }

  @Test("coalesces same URLs and separates distinct URLs")
  func coalescing() async throws {
    let transport = scriptedTransport(responses: [.success(response())])
    transport.gate.hold()
    let client = FeedFetchClient(httpClient: transport)
    let firstEndpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/one.xml"))
    let secondEndpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/two.xml"))

    let first = Task { try await client.fetch(firstEndpoint) }
    let joined = Task { try await client.fetch(firstEndpoint) }
    #expect(await waitUntil { transport.requests.count == 1 })
    transport.gate.release(response())
    if case .fetched = try await first.value {} else { Issue.record("expected fetch") }
    if case .fetched = try await joined.value {} else { Issue.record("expected fetch") }
    #expect(transport.requests.count == 1)

    if case .fetched = try await client.fetch(secondEndpoint) {} else { Issue.record("expected fetch") }
    #expect(transport.requests.count == 2)
  }

  @Test("the feed pool admits at most four transports")
  func gate() async throws {
    let transport = scriptedTransport(responses: Array(repeating: .success(response()), count: 5))
    transport.gate.hold()
    let client = FeedFetchClient(httpClient: transport)
    let endpoints = try (0..<5).map {
      try #require(FeedEndpoint(string: "https://feeds.example.test/\($0).xml"))
    }
    let tasks = endpoints.map { endpoint in Task { try await client.fetch(endpoint) } }

    #expect(await waitUntil { transport.requests.count == 4 })
    #expect(transport.maxInFlight == 4)
    transport.gate.release(response())
    #expect(await waitUntil { transport.requests.count == 5 })
    transport.gate.release(response())
    for task in tasks { _ = try await task.value }
  }

  @Test("redirect handling follows feed policy and strips cross-origin authorization")
  func redirects() throws {
    let original = try #require(URL(string: "https://feeds.example.test/show.xml"))
    let handler = FeedRedirectHandler()
    var crossOrigin = URLRequest(url: try #require(URL(string: "https://cdn.example.test/show.xml")))
    crossOrigin.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    let stripped = try #require(handler.handleRedirect(original: original, proposed: crossOrigin, hopNumber: 1))
    #expect(stripped.value(forHTTPHeaderField: "Authorization") == nil)

    var sameOrigin = URLRequest(url: try #require(URL(string: "https://feeds.example.test/next.xml")))
    sameOrigin.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    let retained = try #require(handler.handleRedirect(original: original, proposed: sameOrigin, hopNumber: 1))
    #expect(retained.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    #expect(handler.handleRedirect(original: original, proposed: sameOrigin, hopNumber: 6) == nil)
    #expect(
      handler.handleRedirect(
        original: original, proposed: URLRequest(url: try #require(URL(string: "http://feeds.example.test/next.xml"))),
        hopNumber: 1) == nil)

    // A userinfo-bearing target is never followed, even at the original origin: the app cannot
    // know which credential the redirect would present.
    var userinfo = URLRequest(
      url: try #require(URL(string: "https://user:password@feeds.example.test/next.xml")))
    userinfo.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    #expect(handler.handleRedirect(original: original, proposed: userinfo, hopNumber: 1) == nil)
    #expect(
      handler.handleRedirect(
        original: original,
        proposed: URLRequest(url: try #require(URL(string: "https://@feeds.example.test/next.xml"))),
        hopNumber: 1) == nil)
  }

  @Test("retryable failures pace the URL and success resets the policy")
  func backoff() async throws {
    let clock = MutableFeedClock(Date(timeIntervalSince1970: 100))
    let transport = scriptedTransport(responses: [
      .failure(APIError.transport), .success(response()), .failure(APIError.transport),
    ])
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/retry.xml"))
    let client = FeedFetchClient(
      httpClient: transport, now: { clock.now() }, randomUnit: { 1 })

    await #expect(throws: APIError.transport) { try await client.fetch(endpoint) }
    do {
      _ = try await client.fetch(endpoint)
      Issue.record("expected backoff")
    } catch let error as FeedFetchError {
      guard case .backoffActive(let retryAfter) = error else {
        Issue.record("unexpected feed error")
        return
      }
      #expect(retryAfter.timeIntervalSince(clock.now()) == 1)
      clock.advance(by: 1.1)
    }
    if case .fetched = try await client.fetch(endpoint) {} else { Issue.record("expected fetch") }

    await #expect(throws: APIError.transport) { try await client.fetch(endpoint) }
    do {
      _ = try await client.fetch(endpoint)
      Issue.record("expected reset base delay")
    } catch let error as FeedFetchError {
      guard case .backoffActive(let retryAfter) = error else {
        Issue.record("unexpected feed error")
        return
      }
      #expect(retryAfter.timeIntervalSince(clock.now()) == 1)
    }
  }

  @Test("non-retryable status failures do not arm backoff")
  func nonRetryableFailure() async throws {
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/missing.xml"))
    let transport = scriptedTransport(responses: [
      .success(HTTPResponse(statusCode: 404, headers: [:], body: Data())),
      .failure(APIError.transport),
    ])
    let client = FeedFetchClient(httpClient: transport, now: Date.init, randomUnit: { 1 })

    await #expect(throws: APIError.notFound) { try await client.fetch(endpoint) }
    await #expect(throws: APIError.transport) { try await client.fetch(endpoint) }
  }

  @Test("omits conditional headers without stored validators")
  func omitsConditionalHeadersWithoutValidators() async throws {
    let transport = scriptedTransport(responses: [.success(response())])
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/no-validators.xml"))
    let client = FeedFetchClient(httpClient: transport)

    _ = try await client.fetch(endpoint)

    let request = try #require(transport.requests.first)
    #expect(request.headers["If-None-Match"] == nil)
    #expect(request.headers["If-Modified-Since"] == nil)
  }

  @Test("replays stored validators verbatim")
  func replaysStoredValidators() async throws {
    let transport = scriptedTransport(responses: [.success(response())])
    let store = InMemoryFeedValidatorStore()
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/validators.xml"))
    await store.store(
      FeedValidators(etag: "W/\"raw etag\"", lastModified: "Thu, 01 Jan 1970 00:00:00 GMT"),
      for: endpoint.url)
    let client = FeedFetchClient(httpClient: transport, validatorStore: store)

    _ = try await client.fetch(endpoint)

    let request = try #require(transport.requests.first)
    #expect(request.headers["If-None-Match"] == "W/\"raw etag\"")
    #expect(request.headers["If-Modified-Since"] == "Thu, 01 Jan 1970 00:00:00 GMT")
  }

  @Test("replays only the stored ETag when Last-Modified is absent")
  func replaysOnlyETag() async throws {
    let transport = scriptedTransport(responses: [.success(response())])
    let store = InMemoryFeedValidatorStore()
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/etag.xml"))
    await store.store(FeedValidators(etag: "\"etag\"", lastModified: nil), for: endpoint.url)
    let client = FeedFetchClient(httpClient: transport, validatorStore: store)

    _ = try await client.fetch(endpoint)

    let request = try #require(transport.requests.first)
    #expect(request.headers["If-None-Match"] == "\"etag\"")
    #expect(request.headers["If-Modified-Since"] == nil)
  }

  @Test("304 retains validators, clears backoff, and permits the next fetch")
  func notModifiedRetainsValidatorsAndClearsBackoff() async throws {
    let store = InMemoryFeedValidatorStore()
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/current.xml"))
    let original = FeedValidators(etag: "\"old\"", lastModified: "old-date")
    await store.store(original, for: endpoint.url)
    let transport = scriptedTransport(responses: [
      .success(HTTPResponse(statusCode: 304, headers: ["ETag": "\"new\""], body: Data())),
      .success(response()),
    ])
    let client = FeedFetchClient(httpClient: transport, validatorStore: store)

    #expect(try await client.fetch(endpoint) == .notModified)
    #expect(await store.validators(for: endpoint.url) == original)
    if case .fetched = try await client.fetch(endpoint) {} else { Issue.record("expected fetch") }
  }

  @Test("stores lowercase validator response headers")
  func storesLowercaseResponseHeaders() async throws {
    let store = InMemoryFeedValidatorStore()
    let transport = scriptedTransport(responses: [
      .success(
        HTTPResponse(
          statusCode: 200, headers: ["etag": "\"lower\"", "last-modified": "lower-date"], body: Data()))
    ])
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/lowercase.xml"))
    let client = FeedFetchClient(httpClient: transport, validatorStore: store)

    guard case .fetched(let response) = try await client.fetch(endpoint) else {
      Issue.record("expected fetch")
      return
    }
    await client.acceptValidators(from: response)

    #expect(
      await store.validators(for: endpoint.url)
        == FeedValidators(etag: "\"lower\"", lastModified: "lower-date"))
  }

  @Test("clears stored validators when a 200 omits them")
  func clearsValidatorsWhenResponseOmitsThem() async throws {
    let store = InMemoryFeedValidatorStore()
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/clears.xml"))
    await store.store(FeedValidators(etag: "\"old\"", lastModified: "old-date"), for: endpoint.url)
    let transport = scriptedTransport(responses: [
      .success(HTTPResponse(statusCode: 200, headers: [:], body: Data("feed".utf8)))
    ])
    let client = FeedFetchClient(httpClient: transport, validatorStore: store)

    guard case .fetched(let response) = try await client.fetch(endpoint) else {
      Issue.record("expected fetch")
      return
    }
    await client.acceptValidators(from: response)

    #expect(await store.validators(for: endpoint.url) == nil)
  }

  @Test("a late parse cannot roll accepted validators back to an older response")
  func lateValidatorAcceptance() async throws {
    let store = InMemoryFeedValidatorStore()
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/ordered.xml"))
    let transport = scriptedTransport(responses: [
      .success(HTTPResponse(statusCode: 200, headers: ["ETag": "old"], body: Data("old".utf8))),
      .success(HTTPResponse(statusCode: 200, headers: ["ETag": "new"], body: Data("new".utf8))),
    ])
    let client = FeedFetchClient(httpClient: transport, validatorStore: store)

    guard case .fetched(let older) = try await client.fetch(endpoint),
      case .fetched(let newer) = try await client.fetch(endpoint)
    else {
      Issue.record("expected two fetches")
      return
    }

    await client.acceptValidators(from: newer)
    await client.acceptValidators(from: older)

    #expect(await store.validators(for: endpoint.url) == FeedValidators(etag: "new", lastModified: nil))
  }

  @Test("coalesced waiters share a not-modified outcome")
  func coalescedNotModifiedOutcome() async throws {
    let transport = scriptedTransport(responses: [
      .success(HTTPResponse(statusCode: 304, headers: [:], body: Data()))
    ])
    transport.gate.hold()
    let client = FeedFetchClient(httpClient: transport)
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/coalesced.xml"))
    let first = Task { try await client.fetch(endpoint) }
    let second = Task { try await client.fetch(endpoint) }

    #expect(await waitUntil { transport.requests.count == 1 })
    transport.gate.release(HTTPResponse(statusCode: 304, headers: [:], body: Data()))
    #expect(try await first.value == .notModified)
    #expect(try await second.value == .notModified)
  }

  @Test("cancelling the only waiter cancels the underlying transport")
  func cancellation() async throws {
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/slow.xml"))
    let transport = scriptedTransport(responses: [.success(response())])
    transport.gate.hold()
    let client = FeedFetchClient(httpClient: transport)
    let task = Task { try await client.fetch(endpoint) }

    #expect(await waitUntil { transport.requests.count == 1 })
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await waitUntil { transport.cancellations.count == 1 })
  }

  @Test("the end-to-end feed-flight budget cancels a held transport")
  func flightBudget() async throws {
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/budget.xml"))
    let transport = scriptedTransport(responses: [.success(response())])
    transport.gate.hold()
    let sleeper = ManualFeedBudgetSleeper()
    let client = FeedFetchClient(
      httpClient: transport, now: Date.init, randomUnit: { 1 },
      flightBudget: .seconds(120), sleep: { try await sleeper.sleep(for: $0) })
    let task = Task { try await client.fetch(endpoint) }

    #expect(await waitUntil { transport.requests.count == 1 })
    #expect(await waitUntil { await sleeper.requestedDurations.count == 1 })
    await sleeper.expireAll()

    do {
      _ = try await task.value
      Issue.record("expected the feed-flight budget to expire")
    } catch let error as URLError {
      #expect(error.code == .timedOut)
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(await waitUntil { transport.cancellations.count == 1 })
    #expect(await sleeper.requestedDurations == [.seconds(120)])
  }

  @Test("the feed-flight budget includes time queued behind the request gate")
  func flightBudgetIncludesGateWait() async throws {
    let transport = scriptedTransport(
      responses: Array(repeating: .success(response()), count: 5))
    transport.gate.hold()
    let sleeper = ManualFeedBudgetSleeper()
    let client = FeedFetchClient(
      httpClient: transport, now: Date.init, randomUnit: { 1 },
      flightBudget: .seconds(120), sleep: { try await sleeper.sleep(for: $0) })
    let endpoints = try (0..<5).map {
      try #require(FeedEndpoint(string: "https://feeds.example.test/budget/\($0).xml"))
    }
    var active: [Task<FeedFetchOutcome, Error>] = []
    for index in 0..<4 {
      active.append(Task { try await client.fetch(endpoints[index]) })
      #expect(await waitUntil { transport.requests.count == index + 1 })
      #expect(await waitUntil { await sleeper.requestedDurations.count == index + 1 })
    }
    let queued = Task { try await client.fetch(endpoints[4]) }
    #expect(await waitUntil { await sleeper.requestedDurations.count == 5 })
    #expect(transport.requests.count == 4)

    await sleeper.expireLast()

    do {
      _ = try await queued.value
      Issue.record("expected the queued flight budget to expire")
    } catch let error as URLError {
      #expect(error.code == .timedOut)
    } catch {
      Issue.record("unexpected error: \(error)")
    }
    #expect(transport.requests.count == 4)

    for task in active { task.cancel() }
    for task in active {
      await #expect(throws: CancellationError.self) { try await task.value }
    }
  }

  @Test("a completed flight withdraws its pending budget")
  func completedFlightCancelsBudget() async throws {
    let endpoint = try #require(FeedEndpoint(string: "https://feeds.example.test/fast.xml"))
    let transport = scriptedTransport(responses: [.success(response())])
    transport.gate.hold()
    let sleeper = ManualFeedBudgetSleeper()
    let client = FeedFetchClient(
      httpClient: transport, now: Date.init, randomUnit: { 1 },
      flightBudget: .seconds(120), sleep: { try await sleeper.sleep(for: $0) })
    let task = Task { try await client.fetch(endpoint) }

    #expect(await waitUntil { transport.requests.count == 1 })
    #expect(await waitUntil { await sleeper.requestedDurations.count == 1 })
    transport.gate.release(response())

    if case .fetched = try await task.value {} else { Issue.record("expected fetch") }
    #expect(await waitUntil { await sleeper.cancellationCount == 1 })
  }

  private func response() -> HTTPResponse {
    HTTPResponse(statusCode: 200, headers: ["ETag": "tag"], body: Data("feed".utf8))
  }
}

private actor ManualFeedBudgetSleeper {
  private typealias SleepGate = TestGate<Result<Void, any Error>>
  private var pending: [(id: UUID, gate: SleepGate)] = []
  private nonisolated let cancellations = TestCountRecorder(
    label: "ManualFeedBudgetSleeper cancellations")
  private(set) var requestedDurations: [Duration] = []
  var cancellationCount: Int { cancellations.count }

  func sleep(for duration: Duration) async throws {
    let id = UUID()
    let gate = SleepGate(label: "ManualFeedBudgetSleeper sleep")
    gate.hold()
    requestedDurations.append(duration)
    pending.append((id, gate))
    defer { pending.removeAll { $0.id == id } }
    let result = await withTaskCancellationHandler {
      await gate.pass(otherwise: { .failure(CancellationError()) })
    } onCancel: {
      cancellations.record()
    }
    try result.get()
  }

  func expireAll() async {
    let all = pending
    pending.removeAll()
    for sleep in all { await expire(sleep.gate) }
  }

  func expireLast() async {
    guard let last = pending.popLast() else { return }
    await expire(last.gate)
  }

  /// A sleep records itself just before it parks, so wait for the park before releasing it.
  private func expire(_ gate: SleepGate) async {
    await gate.waitUntilParked()
    gate.release(.success(()))
  }
}

private final class MutableFeedClock: @unchecked Sendable {
  private let lock = NSLock()
  private var date: Date

  init(_ date: Date) { self.date = date }

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

/// A transport that answers from `responses`, then with an empty 200 once they run out.
private func scriptedTransport(
  responses: [FakeRedirectCustomizingHTTPClienting.Outcome]
) -> FakeRedirectCustomizingHTTPClienting {
  FakeRedirectCustomizingHTTPClienting(
    responses: responses,
    fallback: .success(HTTPResponse(statusCode: 200, headers: [:], body: Data())))
}
