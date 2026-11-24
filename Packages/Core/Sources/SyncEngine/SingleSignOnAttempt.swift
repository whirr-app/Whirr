import ABSApi
import Foundation

/// One single-sign-on attempt, as AppModel and the App hold it between starting the sign-in and
/// the browser's callback. Opaque so the PKCE verifier, `state` and the
/// server's cookies stay inside ABSApi's `OIDCAttempt`, memory only and single use (SECURITY.md
/// rules 6 and 10). Equality is identity, because no two attempts are ever interchangeable.
public final class SingleSignOnAttempt: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  /// The scheme the browser session intercepts. Also registered for widget links: see
  /// `OIDCAttempt.callbackScheme` for why a stray callback reaches no code path.
  public static let callbackScheme = OIDCAttempt.callbackScheme
  /// What a server administrator adds to Allowed Mobile Redirect URIs.
  public static let redirectURI = OIDCAttempt.redirectURI

  /// The identity provider's page, for the browser session. Never log it: it carries the
  /// attempt's `state`.
  public let authorizationURL: URL
  let oidcAttempt: OIDCAttempt?

  /// A stand-in for fakes and previews. It carries no exchange, so the production service refuses
  /// to complete it.
  public init(authorizationURL: URL) {
    self.authorizationURL = authorizationURL
    oidcAttempt = nil
  }

  init(_ attempt: OIDCAttempt) {
    authorizationURL = attempt.authorizationURL
    oidcAttempt = attempt
  }

  /// Ends the attempt without completing it, so a late callback can never use it. The App calls
  /// this when the browser session is cancelled or the screen goes away.
  public func abandon() {
    oidcAttempt?.abandon()
  }

  public static func == (lhs: SingleSignOnAttempt, rhs: SingleSignOnAttempt) -> Bool {
    lhs === rhs
  }

  public var description: String { "SingleSignOnAttempt(<redacted>)" }
  public var debugDescription: String { description }
}

/// Why a single sign-on failed, one case per distinct recovery message. A cancelled browser session
/// is not a failure: the App stays silent.
public enum SingleSignOnFailure: Sendable, Equatable, CaseIterable {
  /// The server's Allowed Mobile Redirect URIs does not list `whirr://oauth`.
  case redirectURINotAllowed
  /// Single sign-on is disabled or misconfigured on the server.
  case unavailable
  /// The browser came back with something that does not belong to this attempt.
  case callbackRejected
  /// The server no longer holds the attempt: it restarted, or the sign-in took too long.
  case attemptExpired
  /// The identity provider or the server refused the sign-in.
  case refused
  /// A custom proxy header sets a cookie the server also uses for the sign-in.
  case proxyCookieConflict
  /// The server is plain HTTP, where single sign-on is never offered.
  case requiresHTTPS
}

extension SingleSignOnFailure {
  /// The failure an exchange error reads as, for callers that run the exchange themselves (Watch
  /// setup's second sign-in).
  public init(_ error: OIDCLoginError) {
    self = AccountLifecycleService.singleSignOnFailure(error).0
  }
}
