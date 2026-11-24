import ABSApi
import Foundation

public protocol RSSArtworkAuthorizationProviding: Sendable {
  func authorizationHeader(for feedIdentity: String) async -> String?
}

public struct NoRSSArtworkAuthorization: RSSArtworkAuthorizationProviding {
  public init() {}
  public func authorizationHeader(for feedIdentity: String) async -> String? { nil }
}

public struct RSSArtworkAuthorization: RSSArtworkAuthorizationProviding, Sendable,
  CustomStringConvertible, CustomDebugStringConvertible
{
  private let credentialStore: any PodcastFeedCredentialStoring

  public init(credentialStore: any PodcastFeedCredentialStoring) {
    self.credentialStore = credentialStore
  }

  public func authorizationHeader(for feedIdentity: String) async -> String? {
    guard let feedID = Self.feedID(from: feedIdentity) else { return nil }

    do {
      return try credentialStore.load(forFeedID: feedID)?.authorization
    } catch {
      return nil
    }
  }

  public var description: String {
    "RSSArtworkAuthorization(fields: Authorization)"
  }

  public var debugDescription: String { description }

  private static func feedID(from feedIdentity: String) -> Int64? {
    guard feedIdentity.hasPrefix("rss:") else { return nil }

    let digits = feedIdentity.dropFirst(4)
    guard digits.isEmpty == false,
      digits.first != "0",
      digits.allSatisfy({ $0.isASCII && $0.isNumber }),
      let feedID = Int64(digits),
      feedID > 0
    else {
      return nil
    }

    return feedID
  }
}

/// ADR 0004's source-specific artwork transport. It accepts only an `.rss` `ArtworkKey`, owns a
/// two-request gate and a distinct URL cache, and never observes or mutates ABS reachability.
public actor RSSArtworkClient: ArtworkServing {
  public static let maximumInFlightRequests = 2
  public static let defaultRevalidationInterval: TimeInterval = 24 * 60 * 60

  public nonisolated let defaultSource: ArtworkSource? = nil

  private enum CacheUserInfoKey {
    static let etag = "RSSArtworkClient.etag"
    static let lastModified = "RSSArtworkClient.lastModified"
    static let validatedAt = "RSSArtworkClient.validatedAt"
  }

  private struct ValidationState: Sendable {
    var etag: String?
    var lastModified: String?
    var validatedAt: Date
  }

  private struct InFlight {
    let task: Task<CoverImageResult, Error>
    var waiters: Set<UUID>
  }

  private let httpClient: any RedirectCustomizingHTTPClienting
  private let authorization: any RSSArtworkAuthorizationProviding
  private let gate: ServerRequestGate
  private let now: @Sendable () -> Date
  private let revalidationInterval: TimeInterval
  private var cache: URLCache
  private var validation: [RSSArtworkSource: ValidationState] = [:]
  private var inFlight: [RSSArtworkSource: InFlight] = [:]

  public init(
    httpClient: (any RedirectCustomizingHTTPClienting)? = nil,
    cache: URLCache = RSSArtworkClient.makeDisposableCache(),
    authorization: any RSSArtworkAuthorizationProviding,
    now: @escaping @Sendable () -> Date = Date.init,
    revalidationInterval: TimeInterval = RSSArtworkClient.defaultRevalidationInterval
  ) {
    self.httpClient = httpClient ?? RSSArtworkHTTPTransport.shared
    self.cache = cache
    self.authorization = authorization
    self.now = now
    self.revalidationInterval = max(0, revalidationInterval)
    gate = ServerRequestGate(maximumConcurrent: Self.maximumInFlightRequests)
  }

  public static let disposableCacheDirectoryURL: URL? = FileManager.default
    .urls(for: .cachesDirectory, in: .userDomainMask).first?
    .appendingPathComponent("RSSArtwork", isDirectory: true)

  public static func makeDisposableCache() -> URLCache {
    URLCache(
      memoryCapacity: 20 * 1024 * 1024,
      diskCapacity: 256 * 1024 * 1024,
      directory: disposableCacheDirectoryURL)
  }

  public func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    guard case .rss(let source) = key.source else {
      throw ArtworkRoutingError.providerMismatch
    }
    if needsRefresh(source) == false, let cached = cachedResult(for: source) {
      return cached
    }

    let waiterID = UUID()
    let task = joinOrStart(source: source, waiterID: waiterID)
    return try await withTaskCancellationHandler {
      do {
        let result = try await task.value
        let cancelled = Task.isCancelled
        release(source: source, waiterID: waiterID, cancelling: cancelled)
        if cancelled { throw CancellationError() }
        return result
      } catch {
        let cancelled = Task.isCancelled || error is CancellationError
        release(source: source, waiterID: waiterID, cancelling: cancelled)
        if Task.isCancelled { throw CancellationError() }
        throw error
      }
    } onCancel: {
      Task { await self.release(source: source, waiterID: waiterID, cancelling: true) }
    }
  }

  public func data(for key: ArtworkKey) -> Data? {
    guard case .rss(let source) = key.source else { return nil }
    return cachedResult(for: source)?.data
  }

  /// Clears RSS artwork bytes and their validator state as one cache operation.
  public func clearCachedArtwork() async {
    let tasks = inFlight.values.map(\.task)
    for task in tasks { task.cancel() }
    for task in tasks { _ = try? await task.value }
    inFlight.removeAll()
    cache.removeAllCachedResponses()
    validation.removeAll()
  }

  public func needsRefresh(_ key: ArtworkKey) -> Bool {
    guard case .rss(let source) = key.source else { return false }
    return needsRefresh(source)
  }

  private func needsRefresh(_ source: RSSArtworkSource) -> Bool {
    guard cachedResult(for: source) != nil else { return true }
    // A byte-valid entry without a stamp is an older cache format, not corrupt data. Revalidate it
    // once so the successful response upgrades the entry with persisted validator state.
    guard let state = validationState(for: source) else { return true }
    return now().timeIntervalSince(state.validatedAt) >= revalidationInterval
  }

  private func validationState(for source: RSSArtworkSource) -> ValidationState? {
    if let state = validation[source] { return state }
    guard
      let cached = cachedResponse(for: source),
      cached.response is HTTPURLResponse,
      let validatedAt = cached.userInfo?[CacheUserInfoKey.validatedAt] as? Date
    else { return nil }

    let state = ValidationState(
      etag: cached.userInfo?[CacheUserInfoKey.etag] as? String,
      lastModified: cached.userInfo?[CacheUserInfoKey.lastModified] as? String,
      validatedAt: validatedAt)
    validation[source] = state
    return state
  }

  private func joinOrStart(
    source: RSSArtworkSource, waiterID: UUID
  ) -> Task<CoverImageResult, Error> {
    if var existing = inFlight[source] {
      existing.waiters.insert(waiterID)
      inFlight[source] = existing
      return existing.task
    }

    let client = httpClient
    let gate = gate
    let authorization = authorization
    let cache = cache
    let validators = validationState(for: source)
    let task = Task { [weak self] in
      guard let self else { throw CancellationError() }
      var headers = ["Accept": "image/*"]
      if let etag = validators?.etag { headers["If-None-Match"] = etag }
      if let lastModified = validators?.lastModified {
        headers["If-Modified-Since"] = lastModified
      }
      if let feedURL = source.feedURL,
        case .allow(stripAuthorization: false) = FeedRedirectPolicy.evaluate(
          original: feedURL,
          target: source.artworkURL,
          hopNumber: 1
        ),
        let header = await authorization.authorizationHeader(for: source.feedIdentity),
        Self.isSafeAuthorizationHeader(header)
      {
        headers["Authorization"] = header
      }
      let request = HTTPRequest(
        method: .get, url: source.artworkURL, headers: headers, body: nil,
        routeTemplate: "/rss/<redacted-artwork>", transportClass: .coverArtwork,
        maximumResponseBytes: CoverImageAdmission.maximumResponseBytes)
      let response = try await gate.withPermit {
        try Task.checkCancellation()
        return try await client.send(request, redirectHandler: FeedRedirectHandler())
      }
      if response.statusCode == 304 {
        guard
          let cached = Self.cachedResponse(for: source, cache: cache),
          let cachedResponse = cached.response as? HTTPURLResponse,
          let admitted = try? CoverImageAdmission.admit(
            data: cached.data, contentType: cached.response.mimeType)
        else {
          throw APIError.decoding
        }
        let state = await self.recordValidation(
          for: source, responseHeaders: response.headers, preserveMissing: true)
        // Keep the response and bytes together with their refreshed stamp. The validators live in
        // userInfo because URLCache persists it across launches without normalizing header values.
        cache.storeCachedResponse(
          CachedURLResponse(
            response: cachedResponse, data: cached.data,
            userInfo: Self.cacheUserInfo(for: state), storagePolicy: .allowed),
          for: URLRequest(url: source.artworkURL))
        return admitted
      }
      guard (200..<300).contains(response.statusCode) else {
        throw APIError.fromHTTPStatus(response.statusCode)
      }
      let contentType = response.headers.headerValue(named: "Content-Type")
      let admitted = try CoverImageAdmission.admit(
        data: response.body, contentType: contentType)
      guard
        let httpResponse = HTTPURLResponse(
          url: source.artworkURL,
          statusCode: response.statusCode,
          httpVersion: nil,
          headerFields: response.headers)
      else {
        throw APIError.transport
      }
      let state = await self.recordValidation(
        for: source, responseHeaders: response.headers, preserveMissing: false)
      // Keep validators in the same URLCache entry as the bytes so eviction cannot leave a stale
      // validator pointing at different artwork. URLCache preserves these userInfo values on disk.
      let cachedEntry = CachedURLResponse(
        response: httpResponse, data: response.body, userInfo: Self.cacheUserInfo(for: state),
        storagePolicy: .allowed)
      cache.storeCachedResponse(cachedEntry, for: URLRequest(url: source.artworkURL))
      return admitted
    }
    inFlight[source] = InFlight(task: task, waiters: [waiterID])
    return task
  }

  private func recordValidation(
    for source: RSSArtworkSource,
    responseHeaders: [String: String],
    preserveMissing: Bool
  ) -> ValidationState {
    let prior = validation[source]
    let state = ValidationState(
      etag: responseHeaders.headerValue(named: "ETag") ?? (preserveMissing ? prior?.etag : nil),
      lastModified: responseHeaders.headerValue(named: "Last-Modified")
        ?? (preserveMissing ? prior?.lastModified : nil),
      validatedAt: now())
    validation[source] = state
    return state
  }

  private func release(source: RSSArtworkSource, waiterID: UUID, cancelling: Bool) {
    guard var entry = inFlight[source], entry.waiters.remove(waiterID) != nil else { return }
    guard entry.waiters.isEmpty else {
      inFlight[source] = entry
      return
    }
    if cancelling { entry.task.cancel() }
    inFlight[source] = nil
  }

  private func cachedResult(for source: RSSArtworkSource) -> CoverImageResult? {
    Self.cachedResult(for: source, cache: cache)
  }

  private func cachedResponse(for source: RSSArtworkSource) -> CachedURLResponse? {
    Self.cachedResponse(for: source, cache: cache)
  }

  private static func cacheUserInfo(for state: ValidationState) -> [AnyHashable: Any] {
    var userInfo: [AnyHashable: Any] = [CacheUserInfoKey.validatedAt: state.validatedAt]
    if let etag = state.etag { userInfo[CacheUserInfoKey.etag] = etag }
    if let lastModified = state.lastModified {
      userInfo[CacheUserInfoKey.lastModified] = lastModified
    }
    return userInfo
  }

  private static func cachedResponse(
    for source: RSSArtworkSource, cache: URLCache
  ) -> CachedURLResponse? {
    cache.cachedResponse(for: URLRequest(url: source.artworkURL))
  }

  private static func cachedResult(
    for source: RSSArtworkSource, cache: URLCache
  ) -> CoverImageResult? {
    let request = URLRequest(url: source.artworkURL)
    guard let cached = cachedResponse(for: source, cache: cache) else { return nil }
    guard
      let admitted = try? CoverImageAdmission.admit(
        data: cached.data, contentType: cached.response.mimeType)
    else {
      cache.removeCachedResponse(for: request)
      return nil
    }
    return admitted
  }

  private static func isSafeAuthorizationHeader(_ value: String) -> Bool {
    value.isEmpty == false && value.contains("\r") == false && value.contains("\n") == false
  }
}

private enum RSSArtworkHTTPTransport {
  static let shared: any RedirectCustomizingHTTPClienting = URLSessionHTTPClient(
    session: URLSessionHTTPClient.makeDedicatedSession(for: .coverArtwork))
}

extension Dictionary where Key == String, Value == String {
  fileprivate func headerValue(named name: String) -> String? {
    first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }
}
