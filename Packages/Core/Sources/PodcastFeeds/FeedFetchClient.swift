import ABSApi
import Foundation

/// Transport seam the feed pool needs: a send that accepts a per-request redirect handler.
/// `URLSessionHTTPClient` conforms below; tests substitute a fake.
public protocol RedirectCustomizingHTTPClienting: Sendable {
  func send(
    _ request: HTTPRequest, redirectHandler: any HTTPRedirectHandling
  ) async throws -> HTTPResponse
}

extension URLSessionHTTPClient: RedirectCustomizingHTTPClienting {}

/// The result of a feed fetch: raw body bytes plus response headers for the validator layer.
public struct FeedFetchResponse: Sendable, Equatable {
  fileprivate struct DeferredValidatorUpdate: Sendable, Equatable {
    let url: URL
    let validators: FeedValidators?
    let sequence: UInt64
  }

  public let body: Data
  public let headers: [String: String]
  fileprivate let validatorUpdate: DeferredValidatorUpdate?

  public init(body: Data, headers: [String: String]) {
    self.body = body
    self.headers = headers
    validatorUpdate = nil
  }

  fileprivate init(
    body: Data, headers: [String: String], validatorUpdate: DeferredValidatorUpdate
  ) {
    self.body = body
    self.headers = headers
    self.validatorUpdate = validatorUpdate
  }

  public static func == (lhs: FeedFetchResponse, rhs: FeedFetchResponse) -> Bool {
    lhs.body == rhs.body && lhs.headers == rhs.headers
  }
}

/// The validator pair a feed origin returned with its last full response. Stored raw and
/// replayed verbatim, with no date parsing or weak/strong ETag interpretation.
public struct FeedValidators: Sendable, Equatable {
  public let etag: String?
  public let lastModified: String?

  public init(etag: String?, lastModified: String?) {
    self.etag = etag
    self.lastModified = lastModified
  }
}

/// Reads and writes validators keyed by feed URL. The persistence layer supplies the durable
/// implementation; `InMemoryFeedValidatorStore` covers tests and persistence-free use.
public protocol FeedValidatorStoring: Sendable {
  func validators(for url: URL) async -> FeedValidators?
  func store(_ validators: FeedValidators?, for url: URL) async
}

public actor InMemoryFeedValidatorStore: FeedValidatorStoring {
  private var values: [URL: FeedValidators] = [:]

  public init() {}

  public func validators(for url: URL) async -> FeedValidators? { values[url] }

  public func store(_ validators: FeedValidators?, for url: URL) async {
    values[url] = validators
  }
}

public enum FeedFetchOutcome: Sendable, Equatable {
  case fetched(FeedFetchResponse)
  /// The origin answered 304: the caller's stored copy is current. Validators are retained.
  case notModified
}

public enum FeedFetchError: Error, Sendable, Equatable {
  case backoffActive(retryAfter: Date)
}

/// Redirect handling for feed-origin requests. The delegate supplies the URL the caller first
/// requested on every hop, so cross-origin authorization stripping is based on the subscription
/// origin, not the prior hop.
public struct FeedRedirectHandler: HTTPRedirectHandling {
  public init() {}

  public func handleRedirect(original: URL, proposed: URLRequest, hopNumber: Int) -> URLRequest? {
    guard let target = proposed.url else { return nil }
    let decision = FeedRedirectPolicy.evaluate(
      original: original, target: target, hopNumber: hopNumber)
    guard case .allow(let stripAuthorization) = decision else { return nil }
    guard stripAuthorization else { return proposed }

    var request = proposed
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    return request
  }
}

public actor FeedFetchClient {
  private struct ValidatorAcceptance {
    let id: UUID
    let task: Task<Void, Never>
  }

  /// Independent four-request pool (API-CONVENTIONS.md rule 27), never the ABS gate.
  public static let maximumInFlightFetches = 4
  /// Feed documents are XML measured in kilobytes; multi-megabyte feeds exist (large serial
  /// archives) but anything past this cap is hostile or broken.
  public static let maximumFeedBytes = 10 * 1024 * 1024
  /// Matches the ordinary transport's complete-resource ceiling, but starts before validator
  /// lookup and request-gate admission so queueing cannot extend a feed flight indefinitely.
  public static let maximumFlightDuration: Duration = .seconds(
    HTTPTransportClass.ordinaryAPI.resourceTimeout)

  private struct FetchKey: Hashable {
    let url: URL
    let credentialFingerprint: String?
  }

  private let httpClient: any RedirectCustomizingHTTPClienting
  private let now: @Sendable () -> Date
  private let randomUnit: @Sendable () -> Double
  private let validatorStore: any FeedValidatorStoring
  private let credentialStore: (any FeedCredentialStoring)?
  private let gate: ServerRequestGate
  private let flightBudget: Duration
  private let sleep: @Sendable (Duration) async throws -> Void
  private let logger = RedactingHTTPLogger()
  private var pool: URLFlightPool<FetchKey, FeedFetchOutcome>
  private var nextValidatorUpdateSequence: UInt64 = 0
  private var acceptedValidatorUpdateSequences: [URL: UInt64] = [:]
  private var validatorAcceptances: [URL: ValidatorAcceptance] = [:]

  public init(
    httpClient: any RedirectCustomizingHTTPClienting = URLSessionHTTPClient(),
    now: @escaping @Sendable () -> Date = Date.init,
    validatorStore: any FeedValidatorStoring = InMemoryFeedValidatorStore(),
    credentialStore: (any FeedCredentialStoring)? = nil
  ) {
    self.init(
      httpClient: httpClient, now: now, randomUnit: { Double.random(in: 0...1) },
      flightBudget: Self.maximumFlightDuration,
      sleep: { try await Task.sleep(for: $0) }, validatorStore: validatorStore,
      credentialStore: credentialStore)
  }

  init(
    httpClient: any RedirectCustomizingHTTPClienting,
    now: @escaping @Sendable () -> Date,
    randomUnit: @escaping @Sendable () -> Double,
    flightBudget: Duration = FeedFetchClient.maximumFlightDuration,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    validatorStore: any FeedValidatorStoring = InMemoryFeedValidatorStore(),
    credentialStore: (any FeedCredentialStoring)? = nil
  ) {
    self.httpClient = httpClient
    self.now = now
    self.randomUnit = randomUnit
    self.validatorStore = validatorStore
    self.credentialStore = credentialStore
    self.flightBudget = flightBudget
    self.sleep = sleep
    pool = URLFlightPool(now: now, randomUnit: randomUnit)
    gate = ServerRequestGate(maximumConcurrent: Self.maximumInFlightFetches)
  }

  /// Accepts conditional validators only after the fetched body has passed feed parsing.
  /// A malformed 200 therefore cannot replace the last known-good validator pair.
  public func acceptValidators(from response: FeedFetchResponse) async {
    guard let update = response.validatorUpdate,
      update.sequence > acceptedValidatorUpdateSequences[update.url, default: 0]
    else { return }

    acceptedValidatorUpdateSequences[update.url] = update.sequence
    let predecessor = validatorAcceptances[update.url]?.task
    let validatorStore = validatorStore
    let id = UUID()
    let task = Task {
      await predecessor?.value
      await validatorStore.store(update.validators, for: update.url)
    }
    validatorAcceptances[update.url] = ValidatorAcceptance(id: id, task: task)
    await task.value
    if validatorAcceptances[update.url]?.id == id {
      validatorAcceptances[update.url] = nil
    }
  }

  public func fetch(
    _ endpoint: FeedEndpoint, credential ephemeralCredential: FeedCredential? = nil
  ) async throws -> FeedFetchOutcome {
    let credential = try ephemeralCredential ?? storedCredential(for: endpoint)
    let key = FetchKey(
      url: endpoint.url, credentialFingerprint: credential?.fingerprint)
    if let retryAfter = pool.backoffRetryAfter(for: endpoint.url) {
      throw FeedFetchError.backoffActive(retryAfter: retryAfter)
    }

    let waiterID = UUID()
    let task = joinOrStart(
      endpoint: endpoint, credential: credential, key: key, waiterID: waiterID)
    return try await withTaskCancellationHandler {
      do {
        let result = try await task.value
        let cancelled = Task.isCancelled
        finish(key: key, waiterID: waiterID, cancelling: cancelled, result: .success(result))
        if cancelled { throw CancellationError() }
        return result
      } catch {
        let cancelled = Task.isCancelled || error is CancellationError
        finish(key: key, waiterID: waiterID, cancelling: cancelled, result: .failure(error))
        if Task.isCancelled { throw CancellationError() }
        throw error
      }
    } onCancel: {
      Task { await self.finish(key: key, waiterID: waiterID, cancelling: true, result: nil) }
    }
  }

  private func storedCredential(for endpoint: FeedEndpoint) throws -> FeedCredential? {
    guard let reference = endpoint.credentialReference,
      let feedID = Int64(reference.id), feedID > 0,
      let credentialStore
    else { return nil }
    return try credentialStore.load(forFeedID: feedID)
  }

  private func joinOrStart(
    endpoint: FeedEndpoint, credential: FeedCredential?, key: FetchKey, waiterID: UUID
  )
    -> Task<FeedFetchOutcome, Error>
  {
    let client = httpClient
    let gate = gate
    let logger = logger
    let redirectHandler = FeedRedirectHandler()
    let validatorStore = validatorStore
    let flightBudget = flightBudget
    let sleep = sleep
    return pool.joinOrStart(key: key, waiterID: waiterID) {
      // Only a started flight takes a sequence, so a joiner cannot renumber a later flight's
      // validator update.
      nextValidatorUpdateSequence += 1
      let validatorUpdateSequence = nextValidatorUpdateSequence
      return Task {
        try await Self.withFlightBudget(flightBudget, sleep: sleep) {
          let started = Date()
          let validators = await validatorStore.validators(for: endpoint.url)
          var headers = [
            "Accept": "application/rss+xml, application/atom+xml, application/xml;q=0.9, text/xml;q=0.8"
          ]
          if let credential { headers["Authorization"] = credential.authorization }
          if let etag = validators?.etag { headers["If-None-Match"] = etag }
          if let lastModified = validators?.lastModified { headers["If-Modified-Since"] = lastModified }
          let request = HTTPRequest(
            method: .get, url: endpoint.url, headers: headers, body: nil,
            routeTemplate: endpoint.routeTemplate, transportClass: .ordinaryAPI,
            maximumResponseBytes: Self.maximumFeedBytes)
          do {
            let response = try await gate.withPermit {
              try Task.checkCancellation()
              return try await client.send(request, redirectHandler: redirectHandler)
            }
            // Production URLSession enforces this while accumulating bytes. Checked here too so a
            // substitute transport cannot pass an oversized body to XMLParser.
            guard response.body.count <= Self.maximumFeedBytes else {
              throw APIError.payloadTooLarge
            }
            if response.statusCode == 304 {
              await logger.record(
                request: request, response: response, duration: Date().timeIntervalSince(started), requestID: nil)
              return FeedFetchOutcome.notModified
            }
            guard (200..<300).contains(response.statusCode) else {
              throw APIError.fromHTTPStatus(response.statusCode)
            }
            let responseValidators = FeedValidators(
              etag: response.headerValue(named: "ETag"),
              lastModified: response.headerValue(named: "Last-Modified"))
            let update = FeedFetchResponse.DeferredValidatorUpdate(
              url: endpoint.url,
              validators: responseValidators.etag == nil && responseValidators.lastModified == nil
                ? nil : responseValidators,
              sequence: validatorUpdateSequence)
            await logger.record(
              request: request, response: response, duration: Date().timeIntervalSince(started), requestID: nil)
            return FeedFetchOutcome.fetched(
              FeedFetchResponse(
                body: response.body, headers: response.headers, validatorUpdate: update))
          } catch {
            await logger.recordFailure(
              request: request, duration: Date().timeIntervalSince(started), requestID: nil)
            throw error
          }
        }
      }
    }
  }

  private nonisolated static func withFlightBudget<Value: Sendable>(
    _ duration: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
      group.addTask { try await operation() }
      group.addTask {
        try await sleep(duration)
        try Task.checkCancellation()
        throw URLError(.timedOut)
      }
      defer { group.cancelAll() }
      guard let value = try await group.next() else { throw CancellationError() }
      return value
    }
  }

  private func finish(
    key: FetchKey, waiterID: UUID, cancelling: Bool, result: Result<FeedFetchOutcome, Error>?
  ) {
    pool.finish(
      key: key, url: key.url, waiterID: waiterID, cancelling: cancelling, result: result)
  }
}

extension HTTPResponse {
  fileprivate func headerValue(named name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}
