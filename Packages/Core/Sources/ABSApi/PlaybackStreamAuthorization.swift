import Foundation

/// The already-stamped HTTP header fields a direct-play stream request needs
/// (`/api/items/{id}/file/{ino}` answers `401` without a Bearer header; see API-CONVENTIONS.md).
/// The playback adapter attaches these to the asset it is separately permitted to execute
/// (ARCHITECTURE.md) without ever holding a token itself.
///
/// Shaped like `AuthorizedDownloadRequest`: no public initializer; the only way in is
/// `ABSClient.makePlaybackStreamAuthorization(account:)`, which stamps the current access token.
/// Its `description` is hand-written because the synthesised one would print credentials
/// (SECURITY.md).
public struct PlaybackStreamAuthorization: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
  private let headerFields: [String: String]
  private let proxyHeaderFields: [String: String]
  /// Scheme, host, and effective port of the configured server. `ABSServerConfig` guarantees all
  /// three, so this is `nil` only if a construction path escaped that validation. It stays
  /// optional so that case sends no credentials rather than trapping mid-playback (fail closed).
  private let origin: Origin?
  /// The server's `/api` mount point, path prefix included. Direct play is
  /// `<prefix>/api/items/{id}/file/{ino}`, which 401s without a Bearer, while a transcoded
  /// `<prefix>/hls/{sessionId}/output.m3u8` is mounted outside the `/api` middleware and is served
  /// without auth.
  private let authenticatedPathPrefix: String

  fileprivate init(
    headerFields: [String: String],
    proxyHeaderFields: [String: String],
    authenticatedPathPrefix: String,
    server: ABSServerConfig
  ) {
    self.headerFields = headerFields
    self.proxyHeaderFields = proxyHeaderFields
    self.authenticatedPathPrefix = authenticatedPathPrefix
    origin = Origin(URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false))
  }

  /// Scheme + host + effective port, so an omitted `:443`/`:80` compares equal to an explicit one.
  /// `PlaybackStreamResource` compares `URL.port` raw, which treats `https://host` and
  /// `https://host:443` as different origins; do not copy that here.
  private struct Origin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(_ components: URLComponents?) {
      guard let components,
        let scheme = components.scheme?.lowercased(),
        let host = components.host?.lowercased(), host.isEmpty == false,
        let port = components.port ?? Self.defaultPort(for: scheme)
      else { return nil }
      self.scheme = scheme
      self.host = host
      self.port = port
    }

    static func defaultPort(for scheme: String) -> Int? {
      switch scheme {
      case "https": return 443
      case "http": return 80
      default: return nil
      }
    }
  }

  /// The adapter's only way to read the headers; the Bearer is baked in at construction, so the
  /// caller never handles the token.
  ///
  /// Resource-aware and fail closed: proxy credentials travel only with a same-origin URL, and the
  /// ABS Bearer additionally requires this server's `/api` mount, since one header set mapped onto
  /// every track would leak credentials where the route does not need them.
  public func httpHeaderFields(for url: URL) -> [String: String] {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      matchesOrigin(components)
    else { return [:] }

    var fields = proxyHeaderFields
    guard components.percentEncodedPath.hasPrefix(authenticatedPathPrefix) else { return fields }
    fields.merge(headerFields) { _, bearerValue in bearerValue }
    return fields
  }

  public var description: String {
    let names = Set(headerFields.keys).union(proxyHeaderFields.keys).sorted()
    return "PlaybackStreamAuthorization(fields: \(names.joined(separator: ", ")))"
  }

  public var debugDescription: String { description }

  private func matchesOrigin(_ components: URLComponents) -> Bool {
    guard let origin, let candidate = Origin(components) else { return false }
    return candidate == origin
  }
}

extension ABSClient {
  /// Stamps the account's currently cached access token into a stream header set. A pure transform
  /// over the token store, never a network call, so it takes no `ServerRequestGate` permit (as
  /// `makeAuthorizedDownloadRequest`). Called by `PlaybackSessionCoordinator` right after `/play`
  /// returns, so the value in `PreparedPlayback` is as fresh as the token that authorised the
  /// session.
  public func makePlaybackStreamAuthorization(account: TokenAccount) throws -> PlaybackStreamAuthorization {
    let tokens = try loadTokens(for: account)
    return stampedPlaybackStreamAuthorization(accessToken: tokens.accessToken)
  }

  /// The stream half of the download queue's one-renewed-retry path
  /// (`renewAuthorizedDownloadRequest`): forces one single-flight refresh, then re-stamps. A Bearer
  /// minted at `/play` ages with the session and a listen can outlive it, but AVFoundation fetches
  /// the asset, so no transport sees the 401; the playback adapter asks for this instead.
  ///
  /// A definitively rejected refresh throws `APIError.unauthorized` and latches
  /// `AuthenticatedHTTPClient`, raising sign-in recovery; a stale header is never returned as
  /// fresh. No retry loop here or inside it.
  public func renewPlaybackStreamAuthorization(account: TokenAccount) async throws
    -> PlaybackStreamAuthorization
  {
    let initialTokens = try loadTokens(for: account)
    let refreshed = try await authenticatedTransport(for: account, initialTokens: initialTokens)
      .forceRefresh()
    return stampedPlaybackStreamAuthorization(accessToken: refreshed.accessToken)
  }

  private func stampedPlaybackStreamAuthorization(accessToken: String) -> PlaybackStreamAuthorization {
    PlaybackStreamAuthorization(
      headerFields: ["Authorization": "Bearer \(accessToken)"],
      proxyHeaderFields: server.customHeaders.headers,
      authenticatedPathPrefix: server.pathPrefix + "/api/",
      server: server)
  }
}
