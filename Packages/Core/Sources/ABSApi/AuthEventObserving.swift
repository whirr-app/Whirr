import Foundation

/// The fixed, credential-free categories `ABSClient.production` reports through
/// `AuthEventObserving`. Never carries a token, username, or raw server response, only the
/// `TokenAccount` the event concerns.
public enum AuthEvent: Sendable, Equatable {
  /// A refresh failed before the server returned an HTTP response.
  case refreshTransport(TokenAccount)
  /// A refresh was rate limited (HTTP 429).
  case refreshRateLimited(TokenAccount)
  /// A refresh failed with an HTTP 5xx response.
  case refreshServerFailure(TokenAccount)
  /// A successful refresh response could not be safely decoded into a token pair.
  case refreshDecoding(TokenAccount)
  /// A definitive refresh rejection (API-CONVENTIONS.md rule 4a) just latched
  /// `AuthenticatedHTTPClient`'s in-memory rejection state for `account`. Fires once per latch
  /// transition; a local failure against an already-set latch never re-emits.
  case reauthenticationRequired(TokenAccount)
  /// `ABSClient.reauthenticate` just completed its atomic sequence (save the rotated pair, then
  /// replace the cached transport's in-memory tokens and clear its latch) for `account`. Fires
  /// only after both steps have completed.
  case reauthenticationSucceeded(TokenAccount)
}

/// Sendable observer seam accepted by `ABSClient.production`, mirroring `ServerDateObserving`.
public protocol AuthEventObserving: Sendable {
  func authEvent(_ event: AuthEvent) async
}

/// No-op default, so callers uninterested in auth events need no optional at every call site.
public struct NoOpAuthEventObserving: AuthEventObserving {
  public init() {}
  public func authEvent(_ event: AuthEvent) async {}
}
