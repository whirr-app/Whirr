import Foundation

public struct HTTPLogEntry: Sendable, Equatable, CustomStringConvertible {
  public let method: HTTPMethod
  public let routeTemplate: String
  public let statusCode: Int?
  public let duration: TimeInterval
  public let requestID: String?

  public var description: String {
    let status = statusCode.map(String.init) ?? "error"
    let request = requestID.map { " request_id=\($0)" } ?? ""
    return "\(method.rawValue) \(routeTemplate) status=\(status) duration_ms=\(Int(duration * 1_000))\(request)"
  }
}

/// Metadata-only logger. It never reads request URLs, headers, bodies, response
/// headers/bodies, or error text; callers provide a route template safe for diagnostics.
public actor RedactingHTTPLogger {
  private var entries: [HTTPLogEntry] = []

  public init() {}

  public func record(
    request: HTTPRequest,
    response: HTTPResponse,
    duration: TimeInterval,
    requestID: String?
  ) {
    entries.append(
      HTTPLogEntry(
        method: request.method,
        routeTemplate: request.routeTemplate,
        statusCode: response.statusCode,
        duration: duration,
        requestID: requestID
      )
    )
  }

  public func recordFailure(
    request: HTTPRequest,
    duration: TimeInterval,
    requestID: String?
  ) {
    entries.append(
      HTTPLogEntry(
        method: request.method,
        routeTemplate: request.routeTemplate,
        statusCode: nil,
        duration: duration,
        requestID: requestID
      )
    )
  }

  public func formattedEntries() -> [String] {
    entries.map(\.description)
  }
}
