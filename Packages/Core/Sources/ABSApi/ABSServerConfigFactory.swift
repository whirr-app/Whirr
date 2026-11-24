import Foundation

/// Builds request-bearing server configurations with the server's persisted proxy credentials.
/// Validation is also exposed with caller-supplied fields because setup must probe before the first
/// successful login has written anything to Keychain.
public struct ABSServerConfigFactory: Sendable {
  private let customHeaderStore: any CustomHeaderStoring

  public init(customHeaderStore: any CustomHeaderStoring) {
    self.customHeaderStore = customHeaderStore
  }

  public func make(for url: URL) throws -> ABSServerConfig {
    let headers = try customHeaderStore.load(for: url) ?? .none
    return try ABSServerConfig(url: url, customHeaders: headers)
  }

  public func make(for url: URL, customHeaders: CustomHeaders) throws -> ABSServerConfig {
    try ABSServerConfig(url: url, customHeaders: customHeaders)
  }

  public func make(for url: URL, customHeaderFields: [String: String]) throws -> ABSServerConfig {
    try make(for: url, customHeaders: CustomHeaders(customHeaderFields))
  }
}
