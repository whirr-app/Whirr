import Foundation

/// A successful cover fetch: raw bytes plus the server-reported content type. Rule 18 always
/// requests `format=webp`, but the client trusts the response header rather than hardcoding
/// `image/webp` itself.
public struct CoverImageResult: Sendable, Equatable {
  public let data: Data
  public let contentType: String?

  public init(data: Data, contentType: String?) {
    self.data = data
    self.contentType = contentType
  }
}

/// ARCHITECTURE.md transport exception 1: the only client allowed to issue unauthenticated cover
/// GETs, and its sole entry point takes a `CoverRequest`, so no arbitrary URL is reachable.
/// Concurrent callers for one cover coalesce onto one request; distinct in-flight covers are capped
/// at six with FIFO admission via `ServerRequestGate` (API-CONVENTIONS.md rule 13). Fetches are
/// written to `CoverFileStore` and served from it; the server sends no ETag/Cache-Control
/// (rule 18), so caching is client-driven.
public actor CoverImageClient {
  /// Covers coalesce by item + width + revision. `CoverRequest` is only `Equatable`, so this
  /// local key supplies the `Hashable`.
  private struct CoalescingKey: Hashable {
    let itemID: String
    let width: Int?
    let revision: ArtworkRevision
    let format: CoverImageFormat
  }

  /// Six-request cap (API-CONVENTIONS.md rule 13): a separate, independent pool from the
  /// foreground `ServerRequestGate(maximumConcurrent: 4)` composed into `ABSClient`.
  public static let maximumInFlightCovers = 6

  private let requestBuilder: RequestBuilder
  private let transport: any HTTPClienting
  private let gate: ServerRequestGate
  private let store: CoverFileStore
  public nonisolated let artworkScope: ArtworkAccountScope
  /// The encoding requested for covers fetched by `ArtworkKey`.
  public nonisolated let format: CoverImageFormat
  public nonisolated var defaultSource: ArtworkSource? { .audiobookshelf(artworkScope) }

  private struct InFlight {
    let task: Task<CoverImageResult, Error>
    var waiters: Set<UUID>
  }

  private var inFlight: [CoalescingKey: InFlight] = [:]
  private var acceptsRequests = true
  var inFlightRequestCountForTesting: Int { inFlight.count }

  /// A client given a `cacheDirectory` keeps its covers in the file store shared by every client
  /// over that directory. One without keeps them in memory only, up to `memoryCapacity` bytes, and
  /// shares them with no other client: the Watch, the UI harness and tests.
  public init(
    server: ABSServerConfig,
    httpClient: any HTTPClienting = URLSessionHTTPClient(),
    cacheDirectory: URL? = nil,
    memoryCapacity: Int = 20 * 1024 * 1024,
    artworkScope: ArtworkAccountScope? = nil,
    format: CoverImageFormat = .webp
  ) {
    self.init(
      server: server, httpClient: httpClient,
      store: cacheDirectory.map(CoverFileStore.shared(root:))
        ?? CoverFileStore(memoryCapacity: memoryCapacity),
      artworkScope: artworkScope, format: format)
  }

  init(
    server: ABSServerConfig,
    httpClient: any HTTPClienting,
    store: CoverFileStore,
    artworkScope: ArtworkAccountScope? = nil,
    format: CoverImageFormat = .webp
  ) {
    requestBuilder = RequestBuilder(server: server)
    transport = httpClient
    gate = ServerRequestGate(maximumConcurrent: Self.maximumInFlightCovers)
    self.store = store
    self.artworkScope = artworkScope ?? ArtworkAccountScope(server.baseURL.absoluteString)
    self.format = format
  }

  /// The cover cache is disposable: a dedicated subdirectory of Caches, excluded from backup and
  /// safe to evict under storage pressure.
  public static let disposableCacheDirectoryURL: URL? = FileManager.default
    .urls(for: .cachesDirectory, in: .userDomainMask).first?
    .appendingPathComponent("CoverImages", isDirectory: true)

  /// The one entry point: no arbitrary-URL escape hatch exists alongside it.
  public func fetch(_ request: CoverRequest) async throws -> CoverImageResult {
    guard acceptsRequests else { throw APIError.cancelled }
    let httpRequest = try request.makeRequest(using: requestBuilder)

    if let cached = cachedCover(for: request, httpRequest: httpRequest) {
      return cached
    }

    let key = CoalescingKey(
      itemID: request.itemID, width: request.width, revision: request.revision, format: request.format)
    let waiterID = UUID()
    let task = joinOrStart(
      key: key, waiterID: waiterID, request: httpRequest, storeKey: storeKey(for: request))

    return try await withTaskCancellationHandler {
      do {
        let result = try await task.value
        let cancelled = Task.isCancelled
        releaseWaiter(key: key, waiterID: waiterID, cancelling: cancelled)
        if cancelled { throw CancellationError() }
        return result
      } catch {
        let cancelled = Task.isCancelled || error is CancellationError
        releaseWaiter(key: key, waiterID: waiterID, cancelling: cancelled)
        if Task.isCancelled { throw CancellationError() }
        throw error
      }
    } onCancel: {
      Task { await self.releaseWaiter(key: key, waiterID: waiterID, cancelling: true) }
    }
  }

  private func joinOrStart(
    key: CoalescingKey,
    waiterID: UUID,
    request: HTTPRequest,
    storeKey: CoverStoreKey
  ) -> Task<CoverImageResult, Error> {
    if var existing = inFlight[key] {
      existing.waiters.insert(waiterID)
      inFlight[key] = existing
      return existing.task
    }

    let transport = self.transport
    let gate = self.gate
    let store = self.store
    // Cancellation is honoured only before the transfer starts. Once `send` returns the cost is
    // sunk, so the response is cached and returned even if the last waiter has left. A later
    // request then hits the cache instead of re-downloading.
    let task = Task {
      try Task.checkCancellation()
      return try await gate.withPermit {
        try Task.checkCancellation()
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
          throw APIError.fromHTTPStatus(response.statusCode)
        }
        let contentType = response.headers.first {
          $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
        }?.value
        let result = try CoverImageAdmission.admit(data: response.body, contentType: contentType)
        store.write(result.data, for: storeKey)
        return result
      }
    }
    inFlight[key] = InFlight(task: task, waiters: [waiterID])
    return task
  }

  private func releaseWaiter(
    key: CoalescingKey,
    waiterID: UUID,
    cancelling: Bool
  ) {
    guard var entry = inFlight[key], entry.waiters.remove(waiterID) != nil else { return }
    guard entry.waiters.isEmpty else {
      inFlight[key] = entry
      return
    }
    if cancelling {
      entry.task.cancel()
    }
    inFlight[key] = nil
  }

  public func fetch(_ key: ArtworkKey) async throws -> CoverImageResult {
    try await fetch(key.coverRequest(format: format))
  }

  /// Cache-only compressed bytes. A miss is `nil`: palette work and preflight checks must never
  /// create network traffic or consume one of the six transfer permits.
  public func data(for request: CoverRequest) -> Data? {
    guard acceptsRequests else { return nil }
    guard let httpRequest = try? request.makeRequest(using: requestBuilder) else { return nil }
    return cachedCover(for: request, httpRequest: httpRequest)?.data
  }

  public func data(for key: ArtworkKey) -> Data? {
    guard let request = try? key.coverRequest(format: format) else { return nil }
    return data(for: request)
  }

  /// Whether the cover is stored, without reading it. A cover still in the cache of an older
  /// build counts, and is moved into the store by the check.
  public func contains(_ key: ArtworkKey) -> Bool {
    guard acceptsRequests, let request = try? key.coverRequest(format: format) else { return false }
    if store.contains(storeKey(for: request)) { return true }
    guard let httpRequest = try? request.makeRequest(using: requestBuilder) else { return false }
    return migratedLegacyCover(for: request, httpRequest: httpRequest) != nil
  }

  public func needsRefresh(_ key: ArtworkKey) -> Bool { false }

  /// Removes covers nothing will ask for again; see `CoverFileStore.prune`. `live` maps every item
  /// the account still has to its current revision, and `keep` lists the covers a bulk pass warms.
  /// Nonisolated so a walk of the whole store never holds up a cover read.
  public nonisolated func pruneCachedArtwork(
    live: [String: ArtworkRevision],
    keep: [ArtworkKey],
    unlistedOlderThan: TimeInterval,
    byteCeiling: Int64,
    now: Date = Date()
  ) async -> CoverCachePruneSummary {
    var liveDirectories: [String: String] = [:]
    for (itemID, revision) in live {
      liveDirectories[CoverStoreNaming.itemDirectory(itemID)] =
        CoverStoreNaming.revisionToken(revision)
    }
    let keepPaths = Set(
      keep.compactMap { key -> String? in
        guard let request = try? key.coverRequest(format: format) else { return nil }
        return CoverStoreKey(
          scope: artworkScope, itemID: request.itemID, width: request.width,
          revision: request.revision, format: request.format
        ).relativePath
      })
    return store.prune(
      scopeDirectory: CoverStoreNaming.scopeDirectory(artworkScope), live: liveDirectories,
      keep: keepPaths, unlistedOlderThan: unlistedOlderThan, byteCeiling: byteCeiling, now: now)
  }

  /// Deletes what is left of the pre-file-store cache. Called once a bulk pass has finished: by
  /// then every cover it wants has been moved into the store.
  public nonisolated func retireLegacyCache() async {
    store.retireLegacyCache()
  }

  /// Empties every cover this client can still answer with. The user-facing clear exists because
  /// the server sends no ETag/Cache-Control (rule 18), so a cached cover is otherwise served
  /// forever. Requests are fenced off and in-flight transfers drained first, so no write lands
  /// after the store is emptied.
  public func clearCachedArtwork() async {
    acceptsRequests = false
    await drainInFlightRequests()
    store.clear()
    acceptsRequests = true
  }

  private func drainInFlightRequests() async {
    let tasks = inFlight.values.map(\.task)
    for task in tasks { task.cancel() }
    for task in tasks { _ = try? await task.value }
    inFlight.removeAll()
  }

  private func storeKey(for request: CoverRequest) -> CoverStoreKey {
    CoverStoreKey(
      scope: artworkScope, itemID: request.itemID, width: request.width,
      revision: request.revision, format: request.format)
  }

  private func cachedCover(for request: CoverRequest, httpRequest: HTTPRequest) -> CoverImageResult? {
    if let data = store.data(for: storeKey(for: request)) {
      return CoverImageResult(data: data, contentType: request.format.mimeType)
    }
    return migratedLegacyCover(for: request, httpRequest: httpRequest)
  }

  // MARK: Covers cached by an older build

  /// Builds before the file store kept covers in a `URLCache`, keyed by the account's artwork
  /// scope and the request's path and query on a host that can never resolve. A hit is moved into
  /// the store, so each cover is read from the old cache at most once.
  static let canonicalCacheHost = "cover-cache.whirr.invalid"

  private func migratedLegacyCover(
    for request: CoverRequest, httpRequest: HTTPRequest
  ) -> CoverImageResult? {
    let keys = [
      legacyCanonicalKey(for: request, httpRequest: httpRequest), URLRequest(url: httpRequest.url),
    ]
    guard let legacy = store.takeLegacyCover(for: keys) else { return nil }
    store.write(legacy.data, for: storeKey(for: request))
    return legacy
  }

  func legacyCanonicalKey(for request: CoverRequest, httpRequest: HTTPRequest) -> URLRequest {
    var components = URLComponents()
    components.scheme = "https"
    components.host = Self.canonicalCacheHost
    let scope =
      artworkScope.rawValue.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
      ?? artworkScope.rawValue
    let itemID =
      request.itemID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
      ?? request.itemID
    components.percentEncodedPath = "/\(scope)/items/\(itemID)/cover"
    components.percentEncodedQuery =
      URLComponents(url: httpRequest.url, resolvingAgainstBaseURL: false)?.percentEncodedQuery
    guard let url = components.url else { return URLRequest(url: httpRequest.url) }
    return URLRequest(url: url)
  }
}

extension CoverImageClient: ArtworkServing {}
