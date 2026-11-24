import Foundation

public enum HTTPMethod: String, Sendable, Equatable {
  case get = "GET"
  case post = "POST"
  case patch = "PATCH"
  case delete = "DELETE"
}

/// Selects a URL loading budget by workload rather than allowing Foundation's seven-day resource
/// default to leak into every request. `timeoutIntervalForRequest` is an inactivity timeout between
/// packets; `timeoutIntervalForResource` bounds the complete transfer.
public enum HTTPTransportClass: Sendable, Equatable {
  case ordinaryAPI
  case progressSync
  /// Cover and feed artwork, separate from `ordinaryAPI` for two reasons. A cover is often a
  /// server-side resize on first request, which on a modest server can far exceed the fifteen
  /// seconds an API call gets, so oversized covers would fail on every attempt and launch. And
  /// artwork is requested six at a time (`CoverImageClient.maximumInFlightCovers`) on top of the
  /// four-permit API gate, so one session would make both contend for a single connection pool.
  case coverArtwork
  case download

  public var requestTimeout: TimeInterval {
    switch self {
    case .ordinaryAPI, .progressSync: 15
    case .coverArtwork: 60
    case .download: 5 * 60
    }
  }

  public var resourceTimeout: TimeInterval {
    switch self {
    case .ordinaryAPI: 2 * 60
    case .progressSync: 30
    case .coverArtwork: 5 * 60
    case .download: 24 * 60 * 60
    }
  }
}

public struct HTTPRequest: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  public static let defaultTimeout = HTTPTransportClass.ordinaryAPI.requestTimeout

  public let method: HTTPMethod
  public let url: URL
  public let headers: [String: String]
  public let body: Data?
  public let routeTemplate: String
  public let timeout: TimeInterval
  public let transportClass: HTTPTransportClass
  /// The maximum response body the transport may consume. `nil` is reserved for callers that
  /// have no transport cap; ordinary API requests use the standard decoder cap.
  public let maximumResponseBytes: Int?
  /// Authentication requests must never follow a redirect, even when the redirect stays on the
  /// same origin. This is explicit rather than inferred from route strings so new auth endpoints
  /// cannot accidentally inherit a permissive redirect policy.
  public let isAuthenticationRoute: Bool
  /// False when the request carries an explicit Cookie field, so URLSession cannot merge its
  /// cookie jar into the caller's value.
  public let httpShouldHandleCookies: Bool
  /// The one transport exception: returns a 3xx instead of failing and parses `Set-Cookie` into
  /// `HTTPResponse.cookies`. Only `surfacingRedirectAndCookies()` sets it, internal to ABSApi and
  /// used only by the two app-side OIDC legs (`OIDCLoginEndpoint.swift`; a source scan pins that).
  /// Redirects are still never followed.
  public private(set) var surfacesRedirectAndCookies = false
  /// A refused redirect throws `RefusedRedirectError` instead of `APIError.transport`. Only
  /// `reportingRefusedRedirect()` sets it, internal to ABSApi and used only by
  /// `fetchServerStatus()`: other callers match on `.transport` for retry and outbox decisions.
  public private(set) var reportsRefusedRedirect = false

  public init(
    method: HTTPMethod,
    url: URL,
    headers: [String: String],
    body: Data?,
    routeTemplate: String = "/<redacted>",
    timeout: TimeInterval? = nil,
    transportClass: HTTPTransportClass = .ordinaryAPI,
    maximumResponseBytes: Int? = EndpointDecodeLimits.standard.maximumBodyBytes,
    isAuthenticationRoute: Bool = false,
    httpShouldHandleCookies: Bool = true
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.routeTemplate = routeTemplate
    self.timeout = timeout ?? transportClass.requestTimeout
    self.transportClass = transportClass
    self.maximumResponseBytes = maximumResponseBytes
    self.isAuthenticationRoute = isAuthenticationRoute
    self.httpShouldHandleCookies = httpShouldHandleCookies
  }

  /// Hand-written because the synthesized, reflection-based default would print `headers`
  /// (including `Authorization: Bearer ...`) and the full URL verbatim (SECURITY.md §7).
  /// `AuthorizedDownloadRequest`/`PlaybackStreamAuthorization` do the same for the `HTTPRequest`
  /// they wrap. Header names are kept (useful for diagnosing a missing header, never secret);
  /// values, URL, and body are not.
  public var description: String {
    "HTTPRequest(method: \(method.rawValue), route: \(routeTemplate), "
      + "headerFields: \(headers.keys.sorted().joined(separator: ", ")), "
      + "bodyBytes: \(body?.count ?? 0))"
  }

  public var debugDescription: String { description }

  /// See `surfacesRedirectAndCookies`. Internal so no module outside ABSApi can opt in.
  func surfacingRedirectAndCookies() -> HTTPRequest {
    var request = self
    request.surfacesRedirectAndCookies = true
    return request
  }

  /// See `reportsRefusedRedirect`. Internal so no module outside ABSApi can opt in.
  func reportingRefusedRedirect() -> HTTPRequest {
    var request = self
    request.reportsRefusedRedirect = true
    return request
  }

  /// Replaces any `Cookie` field (case-insensitively) and stops URLSession from merging its own
  /// cookie handling into it. Used only by the OIDC callback to replay the first leg's cookies.
  func replacingCookieHeader(with value: String) -> HTTPRequest {
    var fields = headers.filter { $0.key.caseInsensitiveCompare("Cookie") != .orderedSame }
    fields["Cookie"] = value
    var request = HTTPRequest(
      method: method, url: url, headers: fields, body: body, routeTemplate: routeTemplate,
      timeout: timeout, transportClass: transportClass, maximumResponseBytes: maximumResponseBytes,
      isAuthenticationRoute: isAuthenticationRoute, httpShouldHandleCookies: false)
    request.surfacesRedirectAndCookies = surfacesRedirectAndCookies
    request.reportsRefusedRedirect = reportsRefusedRedirect
    return request
  }
}

/// A cookie the server set, reduced to what replaying it needs. Only requests that opt in through
/// `HTTPRequest.surfacesRedirectAndCookies` ever receive any. The value is a session secret, so it
/// never appears in a description (SECURITY.md §7).
public struct HTTPResponseCookie: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  public let name: String
  public let value: String

  public init(name: String, value: String) {
    self.name = name
    self.value = value
  }

  public var description: String { "HTTPResponseCookie(name: \(name), value: <redacted>)" }
  public var debugDescription: String { description }
}

public struct HTTPResponse: Sendable, Equatable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data
  /// Parsed `Set-Cookie` fields for the request's origin; empty unless the request opted in.
  /// `headers` cannot carry them: several `Set-Cookie` fields collapse into one comma-joined value.
  public let cookies: [HTTPResponseCookie]

  public init(statusCode: Int, headers: [String: String], body: Data, cookies: [HTTPResponseCookie] = []) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
    self.cookies = cookies
  }
}

/// The raw transport seam is public so TestSupport can provide a reusable fake. Production
/// composition remains internal to ABSApi and adds policy decorators.
public protocol HTTPClienting: Sendable {
  func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// Thin URLSession adapter. It does not interpret MIME types, retries, or auth.
public final class URLSessionHTTPClient: HTTPClienting, @unchecked Sendable {
  private let ordinarySession: URLSession
  private let progressSyncSession: URLSession
  private let downloadSession: URLSession
  private let coverArtworkSession: URLSession

  /// URLSession supplies the system certificate trust evaluation; no custom trust delegate or
  /// certificate exception is installed here (docs/SECURITY.md §Transport).
  public init() {
    ordinarySession = Self.dedicatedSession
    progressSyncSession = Self.dedicatedProgressSyncSession
    downloadSession = Self.dedicatedDownloadSession
    coverArtworkSession = Self.dedicatedCoverArtworkSession
  }

  /// Test/integration seam: an explicitly supplied session handles every class so callers can
  /// substitute a URLProtocol-backed transport without constructing three sessions.
  public init(session: URLSession) {
    ordinarySession = session
    progressSyncSession = session
    downloadSession = session
    coverArtworkSession = session
  }

  /// `coverArtworkSession` defaults to the ordinary one so a test that only cares about the
  /// original three classes keeps its existing two-session arrangement.
  init(
    ordinarySession: URLSession,
    progressSyncSession: URLSession,
    downloadSession: URLSession,
    coverArtworkSession: URLSession? = nil
  ) {
    self.ordinarySession = ordinarySession
    self.progressSyncSession = progressSyncSession
    self.downloadSession = downloadSession
    self.coverArtworkSession = coverArtworkSession ?? ordinarySession
  }

  /// One process-wide instance per transport class rather than sessions per client: ABSApi never
  /// invalidates these sessions, so per-client sessions would leak their connection pools on every
  /// login/logout composition rebuild.
  public static let dedicatedSession = makeDedicatedSession(for: .ordinaryAPI)
  static let dedicatedProgressSyncSession = makeDedicatedSession(for: .progressSync)
  static let dedicatedDownloadSession = makeDedicatedSession(for: .download)
  /// Artwork's own connection pool, so six concurrent covers cannot queue the API calls a screen
  /// needs to render at all, and so a slow resize cannot hold a connection an API call is waiting
  /// for. `RSSArtworkClient` already keeps a separate session for its side of the same workload.
  public static let dedicatedCoverArtworkSession = makeDedicatedSession(for: .coverArtwork)

  public static func makeDedicatedSession() -> URLSession {
    makeDedicatedSession(for: .ordinaryAPI)
  }

  public static func makeDedicatedSession(for transportClass: HTTPTransportClass) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.timeoutIntervalForRequest = transportClass.requestTimeout
    configuration.timeoutIntervalForResource = transportClass.resourceTimeout
    return URLSession(configuration: configuration)
  }

  public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    // A request that surfaces its redirect never follows one, whatever its route flag says.
    let redirectHandler = ABSRedirectHandler(
      isAuthenticationRoute: request.isAuthenticationRoute || request.surfacesRedirectAndCookies)
    return try await sendImplementation(
      request, redirectHandler: redirectHandler, allowsNotModified: false)
  }

  public func send(
    _ request: HTTPRequest, redirectHandler: any HTTPRedirectHandling
  ) async throws -> HTTPResponse {
    try await sendImplementation(
      request, redirectHandler: redirectHandler, allowsNotModified: true)
  }

  private func sendImplementation(
    _ request: HTTPRequest,
    redirectHandler: any HTTPRedirectHandling,
    allowsNotModified: Bool
  ) async throws -> HTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.timeoutInterval = request.timeout
    urlRequest.httpShouldHandleCookies = request.httpShouldHandleCookies
    urlRequest.httpMethod = request.method.rawValue
    urlRequest.httpBody = request.body
    for (field, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: field)
    }

    let delegate = URLSessionRedirectDelegate(
      originalURL: request.url, redirectHandler: redirectHandler)
    let session =
      switch request.transportClass {
      case .ordinaryAPI: ordinarySession
      case .progressSync: progressSyncSession
      case .coverArtwork: coverArtworkSession
      case .download: downloadSession
      }
    // URL loading failures, including `.timedOut`, escape this call untouched. The
    // classifiers above this raw transport rely on the concrete URLError category.
    let (bytes, response) = try await session.bytes(for: urlRequest, delegate: delegate)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw APIError.transport
    }

    // 304 never triggers the redirect callback, so allowing it through for a validator-driven
    // caller cannot surface a denied redirect. The guard below is unchanged for actual redirect
    // statuses.
    if httpResponse.statusCode == 304, allowsNotModified == false {
      bytes.task.cancel()
      throw APIError.transport
    }
    // A denied redirect is returned as its 3xx response when the delegate completes with nil.
    // Convert it into a transport failure here so the raw response cannot enter a success path.
    guard
      httpResponse.statusCode == 304 || (300..<400).contains(httpResponse.statusCode) == false
        || request.surfacesRedirectAndCookies
    else {
      bytes.task.cancel()
      if request.reportsRefusedRedirect {
        let target = httpResponse.value(forHTTPHeaderField: "Location")
          .flatMap { URL(string: $0, relativeTo: request.url)?.absoluteURL }
        throw RefusedRedirectError(target: target)
      }
      throw APIError.transport
    }

    let maximumResponseBytes = request.maximumResponseBytes
    do {
      try ResponseBodyAdmission.validateContentLength(
        httpResponse.value(forHTTPHeaderField: "Content-Length"), maximumBytes: maximumResponseBytes)
    } catch {
      bytes.task.cancel()
      throw error
    }
    if let maximumResponseBytes, maximumResponseBytes < 0 {
      bytes.task.cancel()
      throw APIError.payloadTooLarge
    }

    var accumulator = ResponseBodyAccumulator(maximumBytes: maximumResponseBytes)
    do {
      for try await byte in bytes {
        try accumulator.append(byte)
      }
      accumulator.finish()
    } catch let error as APIError {
      if error == .payloadTooLarge { bytes.task.cancel() }
      throw error
    }

    var headers: [String: String] = [:]
    for (field, value) in httpResponse.allHeaderFields {
      if let field = field as? String, let value = value as? String {
        headers[field] = value
      }
    }
    return HTTPResponse(
      statusCode: httpResponse.statusCode, headers: headers, body: accumulator.data,
      cookies: request.surfacesRedirectAndCookies
        ? Self.originCookies(in: httpResponse, requestURL: request.url) : [])
  }

  /// `HTTPCookie` parses the comma-joined `Set-Cookie` value `allHeaderFields` presents (dates in
  /// `Expires` contain commas, so splitting by hand is wrong). Cookies scoped to another domain are
  /// dropped: these are replayed only to the origin that set them.
  static func originCookies(in response: HTTPURLResponse, requestURL: URL) -> [HTTPResponseCookie] {
    var fields: [String: String] = [:]
    for (field, value) in response.allHeaderFields {
      if let field = field as? String, let value = value as? String { fields[field] = value }
    }
    guard let host = requestURL.host()?.lowercased() else { return [] }
    return HTTPCookie.cookies(withResponseHeaderFields: fields, for: requestURL)
      .filter { cookie in
        let domain = cookie.domain.lowercased().trimmingPrefix(".")
        return host == domain || host.hasSuffix("." + domain)
      }
      .map { HTTPResponseCookie(name: $0.name, value: $0.value) }
  }
}
