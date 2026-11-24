import Foundation

/// A validated feed location for RSS-origin traffic (ADR 0004). Construction is the validation
/// boundary: holders of a `FeedEndpoint` may hand its URL to the feed transport without
/// re-checking scheme, host, or credential rules.
public struct FeedEndpoint: Sendable, Equatable, Hashable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  /// Names a per-feed credential stored elsewhere. The endpoint never carries the secret itself.
  public struct CredentialReference: Sendable, Equatable, Hashable {
    public let id: String

    public init?(id: String) {
      guard id.isEmpty == false else { return nil }
      self.id = id
    }
  }

  public let url: URL
  public let credentialReference: CredentialReference?
  /// Safe for logs: never contains the URL, host, query, or userinfo.
  public let routeTemplate: String

  public init?(url: URL, credentialReference: CredentialReference? = nil) {
    guard
      let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host,
      host.isEmpty == false,
      url.user?.isEmpty != false,
      url.password?.isEmpty != false
    else { return nil }

    self.url = url
    self.credentialReference = credentialReference
    routeTemplate = "/rss/<redacted-feed>"
  }

  public init?(string: String, credentialReference: CredentialReference? = nil) {
    guard let url = URL(string: string) else { return nil }
    self.init(url: url, credentialReference: credentialReference)
  }

  /// Hand-written so descriptions cannot accidentally expose the URL or credential identifier.
  public var description: String {
    "\(routeTemplate) (hasCredential: \(credentialReference != nil))"
  }

  public var debugDescription: String { description }
}
