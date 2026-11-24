import Foundation

public struct ABSServerConfig: Sendable, Equatable {
  public let baseURL: URL
  public let pathPrefix: String
  public let customHeaders: CustomHeaders

  public init(url: URL, customHeaders: CustomHeaders = .none) throws {
    guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
      throw APIError.invalidServerConfiguration(.unsupportedScheme)
    }
    guard let host = url.host, host.isEmpty == false else {
      throw APIError.invalidServerConfiguration(.missingHost)
    }
    guard url.user == nil, url.password == nil else {
      throw APIError.invalidServerConfiguration(.credentialsNotAllowed)
    }
    guard url.query == nil else {
      throw APIError.invalidServerConfiguration(.queryNotAllowed)
    }
    guard url.fragment == nil else {
      throw APIError.invalidServerConfiguration(.fragmentNotAllowed)
    }

    let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    let encodedSegments = (components?.percentEncodedPath ?? "").split(
      separator: "/",
      omittingEmptySubsequences: true
    )
    for encodedSegment in encodedSegments {
      let segment = String(encodedSegment)
      guard let decodedSegment = segment.removingPercentEncoding else {
        throw APIError.invalidServerConfiguration(.pathTraversalNotAllowed)
      }
      guard decodedSegment != ".", decodedSegment != "..", decodedSegment.contains("/") == false else {
        throw APIError.invalidServerConfiguration(.pathTraversalNotAllowed)
      }
    }

    let normalizedPath = encodedSegments.isEmpty ? "" : "/" + encodedSegments.joined(separator: "/")
    var normalizedComponents = components
    normalizedComponents?.percentEncodedPath = normalizedPath

    guard let normalizedURL = normalizedComponents?.url else {
      throw APIError.invalidServerConfiguration(.missingHost)
    }

    self.baseURL = normalizedURL
    self.pathPrefix = normalizedPath
    self.customHeaders = customHeaders
  }
}
