import ABSApi
import Foundation

/// Redirect decisions for RSS-origin feed and enclosure traffic (ADR 0004). Unlike
/// `ABSRedirectPolicy`, cross-origin redirects are allowed (podcast CDNs routinely redirect
/// cross-host), but an https origin never downgrades to http, a target carrying embedded userinfo
/// is rejected rather than followed, and `Authorization` never follows the request across an
/// origin boundary.
public enum FeedRedirectPolicy {
  public enum Decision: Sendable, Equatable {
    /// Follow the redirect. `stripAuthorization` is true when the target is cross-origin
    /// relative to the original request URL, and the caller must remove the `Authorization`
    /// header before following.
    case allow(stripAuthorization: Bool)
    case reject
  }

  /// Bounded hops: the sixth redirect in a chain is rejected.
  public static let maximumHops = 5

  /// `hopNumber` is 1-based: the first redirect of a chain evaluates with `hopNumber: 1`.
  /// `original` is the URL the caller first requested, never an intermediate hop.
  public static func evaluate(original: URL, target: URL, hopNumber: Int) -> Decision {
    guard hopNumber >= 1, hopNumber <= maximumHops else { return .reject }

    let originalScheme = original.scheme?.lowercased()
    let targetScheme = target.scheme?.lowercased()
    if originalScheme == "https", targetScheme != "https" { return .reject }

    guard targetScheme == "http" || targetScheme == "https", target.host != nil else {
      return .reject
    }

    // Embedded userinfo, even an empty user, is a second set of credentials the app did not mint.
    // Stripping the header would not remove it, so the redirect is refused instead of followed.
    guard target.user == nil, target.password == nil else { return .reject }

    return .allow(stripAuthorization: sameOrigin(original, target) == false)
  }

  /// Origin equality only. `FeedCredentialOrigin` owns the shared comparison; this policy layers
  /// fail-closed userinfo and transport admission on top of it.
  private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    FeedCredentialOrigin.sameOrigin(lhs, rhs)
  }
}
