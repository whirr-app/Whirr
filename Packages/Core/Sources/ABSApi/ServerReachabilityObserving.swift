/// The credential-free outcomes `ABSClient` reports through `ServerReachabilityObserving`. Any
/// HTTP response means the server answered, whatever its status; a transport failure means none
/// existed. The event carries no request, credential, query, body or transport-error data.
public enum ServerReachabilityEvent: Sendable, Equatable {
  /// The server returned an HTTP response. The status code is not included: a 401,
  /// 404, or 500 still proves that the server is reachable and answering.
  case responded
  /// The request failed before an HTTP response existed.
  case transportFailure
}

/// Sendable observer seam accepted by `ABSClient.production` for credential-free server
/// reachability events. It is a supplement to active probing because not every server-related
/// request crosses the foreground ABSApi transport pipeline.
public protocol ServerReachabilityObserving: Sendable {
  func reachabilityEvent(_ event: ServerReachabilityEvent) async
}

/// No-op default: every composition that does not need reachability observation gets a harmless
/// default rather than an optional threaded through every call site.
public struct NoOpServerReachabilityObserving: ServerReachabilityObserving {
  public init() {}
  public func reachabilityEvent(_ event: ServerReachabilityEvent) async {}
}
