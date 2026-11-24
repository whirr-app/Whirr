import ABSApi
import Foundation

/// One accountless directory hit. Its artwork URLs are ADR 0004 class 4 directory thumbnails.
public struct PodcastDirectoryResult: Sendable, Equatable, Identifiable {
  public var id: URL { feedURL }
  public let feedURL: URL
  public let title: String
  public let author: String?
  public let artworkURL: URL?
  /// The directory's 600-pixel image, for a detail header. Same provenance as `artworkURL`.
  public let largeArtworkURL: URL?
  public let episodeCount: Int?

  public init(
    feedURL: URL, title: String, author: String?, artworkURL: URL?, largeArtworkURL: URL? = nil,
    episodeCount: Int?
  ) {
    self.feedURL = feedURL
    self.title = title
    self.author = author
    self.artworkURL = artworkURL
    self.largeArtworkURL = largeArtworkURL
    self.episodeCount = episodeCount
  }
}

extension PodcastDirectoryResult {
  /// The directory's own image at the size a full-bleed header draws, or nil when the large image
  /// is not one the directory's image host can resize.
  ///
  /// The iTunes image host serves one master at the size the final path segment names, so this is
  /// the image the search returned, not a new source (ADR 0004 class 4, amended 2026-09-29).
  /// 600px is half what a full-width header needs on a 3x phone. Anything other than that host's
  /// `600x600bb.<ext>` form is left alone, and a caller falls back to `largeArtworkURL` when this
  /// fetch fails.
  public var heroArtworkURL: URL? {
    guard let largeArtworkURL, largeArtworkURL.query == nil, largeArtworkURL.fragment == nil,
      let host = largeArtworkURL.host?.lowercased(),
      host == "mzstatic.com" || host.hasSuffix(".mzstatic.com")
    else { return nil }
    let name = largeArtworkURL.lastPathComponent
    let sizePrefix = "600x600bb."
    guard name.hasPrefix(sizePrefix) else { return nil }
    let fileExtension = name.dropFirst(sizePrefix.count)
    guard fileExtension.isEmpty == false, fileExtension.allSatisfy(\.isLetter) else { return nil }
    return largeArtworkURL.deletingLastPathComponent()
      .appendingPathComponent("1200x1200bb.\(fileExtension)")
  }
}

public enum PodcastDirectorySearchError: Error, Sendable, Equatable {
  case emptyQuery
  case queryTooLong
  case invalidResponse
  case backoffActive(retryAfter: Date)
}

public protocol PodcastDirectorySearching: Sendable {
  func search(term: String) async throws -> [PodcastDirectoryResult]
}

public struct NoOpPodcastDirectorySearch: PodcastDirectorySearching {
  public init() {}
  public func search(term: String) async throws -> [PodcastDirectoryResult] { [] }
}

/// Keyless iTunes Search API transport, isolated from every ABS pool and credential path.
public actor PodcastDirectorySearchClient: PodcastDirectorySearching {
  public static let maximumInFlightSearches = 4
  public static let maximumResponseBytes = 2 * 1024 * 1024
  public static let maximumResults = 25
  public static let maximumQueryCharacters = 200
  public static let maximumResultStringBytes = 4 * 1024

  private struct ResponseEnvelope: Decodable {
    let results: [WireResult]
  }

  private struct WireResult: Decodable {
    let feedUrl: String?
    let collectionName: String?
    let artistName: String?
    let artworkUrl100: String?
    let artworkUrl600: String?
    let trackCount: Int?
  }

  private let httpClient: any RedirectCustomizingHTTPClienting
  private let now: @Sendable () -> Date
  private let randomUnit: @Sendable () -> Double
  private let gate: ServerRequestGate
  private let logger = RedactingHTTPLogger()
  private var pool: URLFlightPool<URL, [PodcastDirectoryResult]>

  /// Production directory traffic owns a separate ephemeral URLSession from ABS and feed fetches.
  /// The injected initializer below remains the deterministic transport seam for tests.
  public init(now: @escaping @Sendable () -> Date = Date.init) {
    self.init(httpClient: PodcastDirectoryHTTPTransport.shared, now: now)
  }

  public init(
    httpClient: any RedirectCustomizingHTTPClienting,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.init(httpClient: httpClient, now: now, randomUnit: { Double.random(in: 0...1) })
  }

  init(
    httpClient: any RedirectCustomizingHTTPClienting,
    now: @escaping @Sendable () -> Date,
    randomUnit: @escaping @Sendable () -> Double
  ) {
    self.httpClient = httpClient
    self.now = now
    self.randomUnit = randomUnit
    pool = URLFlightPool(now: now, randomUnit: randomUnit)
    gate = ServerRequestGate(maximumConcurrent: Self.maximumInFlightSearches)
  }

  public func search(term: String) async throws -> [PodcastDirectoryResult] {
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { throw PodcastDirectorySearchError.emptyQuery }
    guard trimmed.count <= Self.maximumQueryCharacters else {
      throw PodcastDirectorySearchError.queryTooLong
    }
    let url = try Self.searchURL(term: trimmed)
    if let retryAfter = pool.backoffRetryAfter(for: url) {
      throw PodcastDirectorySearchError.backoffActive(retryAfter: retryAfter)
    }

    let waiterID = UUID()
    let task = joinOrStart(url: url, waiterID: waiterID)
    return try await withTaskCancellationHandler {
      do {
        let result = try await task.value
        let cancelled = Task.isCancelled
        finish(url: url, waiterID: waiterID, cancelling: cancelled, result: .success(result))
        if cancelled { throw CancellationError() }
        return result
      } catch {
        let cancelled = Task.isCancelled || error is CancellationError
        finish(url: url, waiterID: waiterID, cancelling: cancelled, result: .failure(error))
        if Task.isCancelled { throw CancellationError() }
        throw error
      }
    } onCancel: {
      Task { await self.finish(url: url, waiterID: waiterID, cancelling: true, result: nil) }
    }
  }

  private func joinOrStart(url: URL, waiterID: UUID) -> Task<[PodcastDirectoryResult], Error> {
    let client = httpClient
    let gate = gate
    let logger = logger
    return pool.joinOrStart(key: url, waiterID: waiterID) {
      Task {
        let request = HTTPRequest(
          method: .get, url: url,
          headers: ["Accept": "application/json"], body: nil,
          routeTemplate: "/search?media=podcast&entity=podcast&limit={limit}&term={redacted}",
          transportClass: .ordinaryAPI, maximumResponseBytes: Self.maximumResponseBytes)
        let started = Date()
        do {
          let response = try await gate.withPermit {
            try Task.checkCancellation()
            return try await client.send(request, redirectHandler: FeedRedirectHandler())
          }
          guard (200..<300).contains(response.statusCode) else {
            throw APIError.fromHTTPStatus(response.statusCode)
          }
          let envelope: ResponseEnvelope
          do {
            envelope = try JSONDecoder().decode(ResponseEnvelope.self, from: response.body)
          } catch {
            throw PodcastDirectorySearchError.invalidResponse
          }
          await logger.record(
            request: request, response: response, duration: Date().timeIntervalSince(started),
            requestID: nil)
          return Self.results(from: envelope.results)
        } catch {
          await logger.recordFailure(
            request: request, duration: Date().timeIntervalSince(started), requestID: nil)
          throw error
        }
      }
    }
  }

  private func finish(
    url: URL, waiterID: UUID, cancelling: Bool,
    result: Result<[PodcastDirectoryResult], Error>?
  ) {
    pool.finish(key: url, url: url, waiterID: waiterID, cancelling: cancelling, result: result)
  }

  private static func searchURL(term: String) throws -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "itunes.apple.com"
    components.path = "/search"
    components.queryItems = [
      URLQueryItem(name: "media", value: "podcast"),
      URLQueryItem(name: "entity", value: "podcast"),
      URLQueryItem(name: "limit", value: String(maximumResults)),
      URLQueryItem(name: "term", value: term),
    ]
    guard let url = components.url else { throw PodcastDirectorySearchError.invalidResponse }
    return url
  }

  private static func results(from wireResults: [WireResult]) -> [PodcastDirectoryResult] {
    var seen = Set<URL>()
    var results: [PodcastDirectoryResult] = []
    for wire in wireResults {
      guard results.count < maximumResults else { break }
      guard let rawFeedURL = wire.feedUrl, let endpoint = FeedEndpoint(string: rawFeedURL) else {
        continue
      }
      guard rawFeedURL.utf8.count <= maximumResultStringBytes else { continue }
      guard seen.insert(endpoint.url).inserted else { continue }
      let title = wire.collectionName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard title.isEmpty == false, title.utf8.count <= maximumResultStringBytes else { continue }
      let author = wire.artistName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let boundedAuthor = author.flatMap {
        $0.utf8.count <= maximumResultStringBytes && $0.isEmpty == false ? $0 : nil
      }
      let artworkURL = wire.artworkUrl100.flatMap(boundedHTTPURL)
      let largeArtworkURL = wire.artworkUrl600.flatMap(boundedHTTPURL)
      results.append(
        PodcastDirectoryResult(
          feedURL: endpoint.url, title: title,
          author: boundedAuthor,
          artworkURL: artworkURL,
          largeArtworkURL: largeArtworkURL,
          episodeCount: wire.trackCount.map { max(0, $0) }))
    }
    return results
  }

  private static func boundedHTTPURL(_ string: String) -> URL? {
    string.utf8.count <= maximumResultStringBytes ? validHTTPURL(string) : nil
  }

  private static func validHTTPURL(_ string: String) -> URL? {
    guard let url = URL(string: string), url.user == nil, url.password == nil,
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host?.isEmpty == false
    else { return nil }
    return url
  }
}

private enum PodcastDirectoryHTTPTransport {
  static let shared: any RedirectCustomizingHTTPClienting = URLSessionHTTPClient(
    session: URLSessionHTTPClient.makeDedicatedSession(for: .ordinaryAPI))
}
