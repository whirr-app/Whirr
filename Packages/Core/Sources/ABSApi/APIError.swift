import Foundation

public enum ServerConfigurationIssue: Sendable, Equatable {
  case unsupportedScheme
  case missingHost
  case credentialsNotAllowed
  case queryNotAllowed
  case fragmentNotAllowed
  case pathTraversalNotAllowed
}

public enum APIError: Error, Sendable, Equatable, CustomStringConvertible {
  case transport
  case badRequest
  case unauthorized
  case forbidden
  case notFound
  case payloadTooLarge
  case rateLimited
  case serverFailure(statusCode: Int)
  case unexpectedStatus(statusCode: Int)
  case decoding
  case ambiguousLocalSessionResponse
  case incompatibleServer(required: ABSServerVersion, detected: ABSServerVersion?)
  case invalidServerConfiguration(ServerConfigurationIssue)
  case cancelled

  public static func fromHTTPStatus(_ statusCode: Int) -> APIError {
    switch statusCode {
    case 400:
      return .badRequest
    case 401:
      return .unauthorized
    case 403:
      return .forbidden
    case 404:
      return .notFound
    case 413:
      return .payloadTooLarge
    case 429:
      return .rateLimited
    case 500...599:
      return .serverFailure(statusCode: statusCode)
    default:
      return .unexpectedStatus(statusCode: statusCode)
    }
  }

  public var isUnauthorized: Bool {
    if case .unauthorized = self { return true }
    return false
  }

  public var description: String {
    switch self {
    case .transport:
      return "The server could not be reached."
    case .badRequest:
      return "The server rejected the request."
    case .unauthorized:
      return "The server rejected authentication."
    case .forbidden:
      return "The server denied access to this resource."
    case .notFound:
      return "The requested resource was not found."
    case .payloadTooLarge:
      return "The server response was oversized."
    case .rateLimited:
      return "The server is rate limiting requests."
    case .serverFailure(let statusCode):
      return "The server failed with status \(statusCode)."
    case .unexpectedStatus(let statusCode):
      return "The server returned an unexpected status (\(statusCode))."
    case .decoding:
      return "The server response could not be read."
    case .ambiguousLocalSessionResponse:
      return "The local session response could not be interpreted."
    case .incompatibleServer(let required, let detected):
      if let detected {
        return "Audiobookshelf server \(detected) is unsupported. Upgrade the server to \(required) or newer."
      }
      return "The Audiobookshelf server version could not be identified. Upgrade the server to \(required) or newer."
    case .invalidServerConfiguration(let issue):
      switch issue {
      case .unsupportedScheme:
        return "The server URL must start with https:// or http://."
      case .missingHost:
        return "The server URL must include a host."
      case .credentialsNotAllowed:
        return "Credentials are not allowed in the server URL."
      case .queryNotAllowed:
        return "A query string is not allowed in the server URL."
      case .fragmentNotAllowed:
        return "A fragment is not allowed in the server URL."
      case .pathTraversalNotAllowed:
        return "Path traversal is not allowed in the server URL."
      }
    case .cancelled:
      return "The request was cancelled."
    }
  }
}
