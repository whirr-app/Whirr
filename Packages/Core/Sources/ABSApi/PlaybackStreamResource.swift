import Foundation

/// A restricted, resolved, credential-free stream URL for one playback track (ARCHITECTURE.md,
/// API-CONVENTIONS.md). No public initializer: the only way to get one is
/// `resolve(rawContentUrl:server:)`, called while mapping a successful `/play` (or
/// `GET /api/session/{id}`) response's `audioTracks[].contentUrl` against the account's own
/// `ABSServerConfig`. Not a generic URL builder: it resolves one server-returned candidate against
/// a fixed, validated origin and rejects anything not a same-origin, credential-free,
/// traversal-free `http(s)` resource, so no arbitrary endpoint can be minted.
public struct PlaybackStreamResource: Sendable, Equatable {
  public let url: URL

  private init(url: URL) {
    self.url = url
  }

  /// Resolves `rawContentUrl`. Observed shapes are a bare `/api/items/{id}/file/{ino}` (direct
  /// play) and `/hls/{sessionId}/output.m3u8` (transcode, mounted outside `/api`); a `/public/...`
  /// shape is accepted on the same terms. Returns `nil`, never throws, for anything hostile or
  /// unusable, so a malformed track is unusable rather than a decode failure. `PlaybackSession`'s
  /// mapping enforces "at least one usable stream" as the fail-closed session-level requirement.
  static func resolve(rawContentUrl: String, server: ABSServerConfig) -> PlaybackStreamResource? {
    guard let candidate = URLComponents(string: rawContentUrl) else { return nil }

    // Credential-free: never resolve a URL carrying embedded user-info, a query (where a token
    // could hide), or a fragment. Real content URLs carry none of these.
    guard candidate.user == nil, candidate.password == nil else { return nil }
    guard candidate.percentEncodedQuery == nil else { return nil }
    guard candidate.fragment == nil else { return nil }

    guard let serverComponents = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false) else {
      return nil
    }

    var resolvedComponents: URLComponents
    if let scheme = candidate.scheme {
      // Absolute URL: only accepted when it is the configured server's own origin.
      let normalizedScheme = scheme.lowercased()
      guard normalizedScheme == "http" || normalizedScheme == "https",
        normalizedScheme == serverComponents.scheme?.lowercased()
      else { return nil }
      guard candidate.host?.lowercased() == serverComponents.host?.lowercased(),
        candidate.port == serverComponents.port
      else { return nil }
      resolvedComponents = candidate
    } else {
      // Relative: reject protocol-relative ("//host/path") forms. A bare host with no scheme is
      // host confusion, not a same-origin path. A usable relative path is path-absolute.
      guard candidate.host == nil else { return nil }
      guard candidate.percentEncodedPath.hasPrefix("/") else { return nil }

      resolvedComponents = serverComponents
      // Overwrite (not append to) the base URL's path with the configured prefix plus the raw
      // path, as RequestBuilder does, so the prefix is never doubled.
      resolvedComponents.percentEncodedPath = server.pathPrefix + candidate.percentEncodedPath
      resolvedComponents.percentEncodedQuery = nil
      resolvedComponents.fragment = nil
    }

    // Reject traversal in any (possibly percent-encoded) path segment, as
    // ABSServerConfig/RequestBuilder do at normalisation time.
    let segments = resolvedComponents.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
    for segment in segments {
      guard let decoded = String(segment).removingPercentEncoding else { return nil }
      guard decoded != ".", decoded != ".." else { return nil }
    }

    guard let resolvedURL = resolvedComponents.url else { return nil }
    return PlaybackStreamResource(url: resolvedURL)
  }
}
