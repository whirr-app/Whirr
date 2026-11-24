import Foundation

/// Applies ADR 0004's redirect rule to an enclosure the Watch downloaded itself, after the fact
/// (ADR 0020 Decision 3). A background `URLSession` follows redirects without calling the redirect
/// delegate, so the chain is read from `URLSessionTaskMetrics`' transaction URLs once the download
/// completes. Bytes from a rejected chain are never moved into the store or played.
///
/// The rules are `FeedRedirectPolicy`'s, adapted to a whole chain: `http` may upgrade to `https`,
/// once any hop is `https` a later `http` hop rejects the chain, every hop must be fetchable
/// `http`/`https` without embedded credentials, and missing metrics count as a rejection. Hop
/// count is `URLSession`'s own limit, so this check has none.
public enum WatchEnclosureRedirectCheck {
  public enum Verdict: Sendable, Equatable {
    case accepted
    case rejected
  }

  /// `hops` are the transaction URLs in the order the session visited them; the first is normally
  /// `requested`. The requested URL is checked as the chain's origin even if the metrics omit it.
  public static func evaluate(requested: URL, hops: [URL]) -> Verdict {
    guard !hops.isEmpty else { return .rejected }
    guard isFetchable(requested) else { return .rejected }

    var sawHTTPS = isHTTPS(requested)
    for hop in hops {
      guard isFetchable(hop) else { return .rejected }
      if isHTTPS(hop) {
        sawHTTPS = true
      } else if sawHTTPS {
        // ATS does not help here: the Watch app allows arbitrary loads for self-hosted
        // Audiobookshelf, so an https→http downgrade is this check's to refuse.
        return .rejected
      }
    }
    return .accepted
  }

  private static func isFetchable(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty
    else { return false }
    // Embedded userinfo is a second set of credentials the app did not mint, and a rejection is
    // safer than following it.
    return url.user == nil && url.password == nil
  }

  private static func isHTTPS(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "https"
  }
}
