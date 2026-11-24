import Foundation

public enum RequestBuilderError: Error, Sendable, Equatable {
  case absolutePathNotAllowed
  case queryOrFragmentInPath
  case pathTraversalNotAllowed
  case invalidURL
}

public struct RequestBuilder: Sendable {
  private let server: ABSServerConfig

  public init(server: ABSServerConfig) {
    self.server = server
  }

  public func makeRequest(
    method: HTTPMethod,
    path: String,
    queryItems: [URLQueryItem] = [],
    headers: [String: String] = [:],
    body: Data? = nil,
    acceptedMIMETypes: [String] = ["application/json"],
    bearerToken: String? = nil,
    routeTemplate: String? = nil,
    transportClass: HTTPTransportClass = .ordinaryAPI,
    timeout: TimeInterval? = nil,
    maximumResponseBytes: Int? = EndpointDecodeLimits.standard.maximumBodyBytes,
    isAuthenticationRoute: Bool = false
  ) throws -> HTTPRequest {
    let normalizedPath = try normalizePath(path)
    var components = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false)
    components?.percentEncodedPath = server.pathPrefix + normalizedPath
    // `percentEncodedQueryItems`, not `.queryItems`: the latter leaves '+' and '/' literal in a
    // query value, and many form-urlencoded parsers read an unescaped '+' as a space. That breaks
    // base64 filter strings. Each component is pre-encoded with a strict RFC 3986 "unreserved"
    // allowlist and passed through as-is (`.queryItems` would double-encode a manual '%').
    components?.percentEncodedQueryItems =
      queryItems.isEmpty ? nil : queryItems.map(Self.percentEncodedQueryItem)
    guard let url = components?.url else {
      throw RequestBuilderError.invalidURL
    }

    var requestHeaders = headers
    // Server-scoped fields are applied before protocol and ABS-auth stamps so those policies win
    // any collision with a request-specific value.
    for (name, value) in server.customHeaders.headers {
      Self.setHeader(value, named: name, in: &requestHeaders)
    }
    if body != nil, Self.header(named: "Content-Type", in: requestHeaders) == nil {
      Self.setHeader("application/json", named: "Content-Type", in: &requestHeaders)
    }
    if acceptedMIMETypes.isEmpty == false {
      Self.setHeader(
        acceptedMIMETypes.joined(separator: ", "), named: "Accept", in: &requestHeaders)
    }
    if let bearerToken {
      Self.setHeader("Bearer \(bearerToken)", named: "Authorization", in: &requestHeaders)
    }

    return HTTPRequest(
      method: method,
      url: url,
      headers: requestHeaders,
      body: body,
      routeTemplate: routeTemplate ?? "/<redacted>",
      timeout: timeout,
      transportClass: transportClass,
      maximumResponseBytes: maximumResponseBytes,
      isAuthenticationRoute: isAuthenticationRoute,
      httpShouldHandleCookies: server.customHeaders.cookieHeaderIsPresent == false
    )
  }

  public func makeJSONRequest<Body: Encodable>(
    method: HTTPMethod,
    path: String,
    queryItems: [URLQueryItem] = [],
    headers: [String: String] = [:],
    body: Body,
    acceptedMIMETypes: [String] = ["application/json"],
    bearerToken: String? = nil,
    routeTemplate: String? = nil,
    transportClass: HTTPTransportClass = .ordinaryAPI,
    timeout: TimeInterval? = nil,
    maximumResponseBytes: Int? = EndpointDecodeLimits.standard.maximumBodyBytes,
    isAuthenticationRoute: Bool = false,
    outputFormatting: JSONEncoder.OutputFormatting = []
  ) throws -> HTTPRequest {
    let encoder = JSONEncoder()
    encoder.outputFormatting = outputFormatting
    let encodedBody = try encoder.encode(body)
    return try makeRequest(
      method: method,
      path: path,
      queryItems: queryItems,
      headers: headers,
      body: encodedBody,
      acceptedMIMETypes: acceptedMIMETypes,
      bearerToken: bearerToken,
      routeTemplate: routeTemplate,
      transportClass: transportClass,
      timeout: timeout,
      maximumResponseBytes: maximumResponseBytes,
      isAuthenticationRoute: isAuthenticationRoute
    )
  }

  private func normalizePath(_ path: String) throws -> String {
    guard path.contains("://") == false else {
      throw RequestBuilderError.absolutePathNotAllowed
    }
    guard path.contains("?") == false, path.contains("#") == false else {
      throw RequestBuilderError.queryOrFragmentInPath
    }

    let withLeadingSlash = path.hasPrefix("/") ? path : "/" + path
    for segment in withLeadingSlash.split(separator: "/", omittingEmptySubsequences: true) {
      guard let decodedSegment = segment.removingPercentEncoding else {
        throw RequestBuilderError.invalidURL
      }
      if decodedSegment == "." || decodedSegment == ".." || decodedSegment.contains("/") {
        throw RequestBuilderError.pathTraversalNotAllowed
      }
    }
    return withLeadingSlash
  }

  private static func header(named name: String, in headers: [String: String]) -> String? {
    headers.first { field, _ in field.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  private static func setHeader(_ value: String, named name: String, in headers: inout [String: String]) {
    let matchingNames = headers.keys.filter { $0.caseInsensitiveCompare(name) == .orderedSame }
    for matchingName in matchingNames {
      headers.removeValue(forKey: matchingName)
    }
    headers[name] = value
  }

  /// RFC 3986 §2.3 "unreserved" characters only, stricter than Foundation's own query-item
  /// allowlist (which passes '+' and '/' through unescaped).
  private static let unreservedQueryCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
  )

  private static func percentEncodedQueryItem(_ item: URLQueryItem) -> URLQueryItem {
    URLQueryItem(
      name: percentEncodeQueryComponent(item.name),
      value: item.value.map(percentEncodeQueryComponent)
    )
  }

  private static func percentEncodeQueryComponent(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreservedQueryCharacters) ?? value
  }
}
