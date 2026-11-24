import CryptoKit
import Foundation

/// Why an OIDC sign-in attempt failed, one case per distinct recovery.
/// Transport failures and rate limiting still surface as `URLError` and `APIError`.
public enum OIDCLoginError: Error, Sendable, Equatable {
  /// The server's Allowed Mobile Redirect URIs does not list `whirr://oauth` (first leg's
  /// `400 Invalid redirect_uri`, before any browser opens).
  case redirectURINotAllowed
  /// The first leg refused for any other reason: SSO is disabled or misconfigured on the server.
  case unavailable
  /// The browser returned to something other than `whirr://oauth`.
  case invalidCallback
  /// The callback's `state` is not this attempt's.
  case stateMismatch
  /// An attempt is single use; this one was already completed or abandoned.
  case attemptAlreadyUsed
  /// The attempt was begun against a different server than the client completing it.
  case attemptForAnotherServer
  /// The server does not hold the attempt (`400 No session`): it restarted or the attempt expired.
  case attemptExpired
  /// The identity provider or the server refused the sign-in (no code, or a `/login?error=` redirect).
  case refused
  /// A proxy `Cookie` header names a cookie the server also set; Whirr will not guess which wins.
  case proxyCookieConflict
  /// The server is plain HTTP. An on-path attacker could swap the identity provider's page for a
  /// fake and collect a password that reaches beyond this server, so no request is sent.
  case requiresHTTPS
}

/// One OIDC sign-in attempt. Memory only and single use: it holds the PKCE verifier and the
/// first leg's cookies, which are secrets, and is never persisted or logged (SECURITY.md).
public final class OIDCAttempt: @unchecked Sendable, CustomStringConvertible,
  CustomDebugStringConvertible
{
  /// The redirect URI every server administrator allow-lists, so it cannot change once shipped.
  public static let redirectURI = "whirr://oauth"
  /// The scheme the browser session intercepts. The App also registers it for widget links, so a
  /// `whirr://oauth` URL can reach the App from outside; it is harmless only because the App's URL
  /// handler accepts widget links alone (`WidgetTapRouterTests` pins that) and an exchange needs
  /// this attempt's `state`. A new route that accepts the scheme must keep both true.
  public static let callbackScheme = "whirr"

  /// The identity provider's authorization page, to open in the browser session. It carries no
  /// Whirr secret: the challenge is public by design.
  public let authorizationURL: URL

  let state: String
  let codeVerifier: String
  let cookies: [HTTPResponseCookie]
  let serverBaseURL: URL

  private let lock = NSLock()
  private var isConsumed = false

  init(
    authorizationURL: URL, state: String, codeVerifier: String, cookies: [HTTPResponseCookie],
    serverBaseURL: URL
  ) {
    self.authorizationURL = authorizationURL
    self.state = state
    self.codeVerifier = codeVerifier
    self.cookies = cookies
    self.serverBaseURL = serverBaseURL
  }

  /// Marks the attempt used. A cancelled browser session calls this too, so a late callback for
  /// an abandoned attempt can never complete it.
  public func abandon() {
    lock.lock()
    isConsumed = true
    lock.unlock()
  }

  func consume() throws {
    lock.lock()
    defer { lock.unlock() }
    guard isConsumed == false else { throw OIDCLoginError.attemptAlreadyUsed }
    isConsumed = true
  }

  public var description: String { "OIDCAttempt(<redacted>)" }
  public var debugDescription: String { description }
}

extension ABSClient {
  /// First leg: asks the server to start a mobile OIDC flow and returns the identity provider's
  /// page for the browser. The redirect is surfaced, never followed, so the session cookies stay
  /// with Whirr rather than landing in the browser's jar, where the callback could not use them.
  public func beginOIDCLogin() async throws -> OIDCAttempt {
    guard server.baseURL.scheme?.lowercased() == "https" else { throw OIDCLoginError.requiresHTTPS }
    let state = Self.randomURLSafeToken()
    let verifier = Self.randomURLSafeToken()
    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/auth/openid",
      queryItems: [
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "redirect_uri", value: OIDCAttempt.redirectURI),
        URLQueryItem(name: "state", value: state),
        URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
      ],
      acceptedMIMETypes: [],
      routeTemplate: "/auth/openid",
      isAuthenticationRoute: true
    ).surfacingRedirectAndCookies()

    let response = try await send(request)
    switch response.statusCode {
    case 300..<400:
      guard let location = Self.header(named: "Location", in: response),
        let target = URL(string: location, relativeTo: request.url)?.absoluteURL,
        let scheme = target.scheme?.lowercased(), scheme == "https" || scheme == "http",
        target.host()?.isEmpty == false, target.user == nil, target.password == nil
      else { throw APIError.decoding }
      return OIDCAttempt(
        authorizationURL: target, state: state, codeVerifier: verifier, cookies: response.cookies,
        serverBaseURL: server.baseURL)
    case 400 where Self.bodyText(response).contains("Invalid redirect_uri"):
      throw OIDCLoginError.redirectURINotAllowed
    case 429:
      throw APIError.rateLimited
    default:
      throw OIDCLoginError.unavailable
    }
  }

  /// Second leg: validates the browser's callback and exchanges it for a committable session,
  /// as `prepareLogin(credentials:)` does for a password. Nothing is stored until the lifecycle
  /// owner commits it.
  public func prepareOIDCLogin(attempt: OIDCAttempt, callbackURL: URL) async throws -> LoginSession {
    LoginSession.prepared(from: try await exchangeOIDCCallback(attempt: attempt, callbackURL: callbackURL))
  }

  func exchangeOIDCCallback(attempt: OIDCAttempt, callbackURL: URL) async throws -> PasswordExchange {
    try attempt.consume()
    guard attempt.serverBaseURL == server.baseURL else { throw OIDCLoginError.attemptForAnotherServer }

    guard
      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == OIDCAttempt.callbackScheme,
      components.host?.lowercased() == "oauth"
    else { throw OIDCLoginError.invalidCallback }
    let items = components.queryItems ?? []
    guard items.first(where: { $0.name == "state" })?.value == attempt.state else {
      throw OIDCLoginError.stateMismatch
    }
    // ABS's mobile-redirect never forwards the provider's `error`: a refusal arrives as the
    // literal `code=undefined` (`encodeURIComponent(undefined)`), the same in 2.35.1 and 2.37.2.
    guard let code = items.first(where: { $0.name == "code" })?.value, code.isEmpty == false,
      code != "undefined"
    else { throw OIDCLoginError.refused }

    let request = try requestBuilder.makeRequest(
      method: .get,
      path: "/auth/openid/callback",
      queryItems: [
        URLQueryItem(name: "code", value: code),
        URLQueryItem(name: "state", value: attempt.state),
        URLQueryItem(name: "code_verifier", value: attempt.codeVerifier),
      ],
      routeTemplate: "/auth/openid/callback",
      isAuthenticationRoute: true
    )
    .surfacingRedirectAndCookies()
    .replacingCookieHeader(with: try Self.cookieHeader(proxy: server.customHeaders, attempt: attempt.cookies))

    let response = try await send(request)
    switch response.statusCode {
    case 200..<300:
      return try decodeLoginResponse(response.body, endpoint: "/auth/openid/callback")
    case 300..<400:
      // Both tags send provider and token-exchange failures here as a redirect to
      // `/login?error=…`: their mobile check compares the stored redirect URI string with `true`.
      throw OIDCLoginError.refused
    case 400 where Self.bodyText(response).contains("No session"):
      throw OIDCLoginError.attemptExpired
    case 400, 401, 500:
      throw OIDCLoginError.refused
    default:
      throw APIError.fromHTTPStatus(response.statusCode)
    }
  }

  /// The proxy's own `Cookie` value, if any, followed by the attempt's cookies. A shared name is
  /// refused rather than resolved: either choice could silently break the proxy or the sign-in.
  static func cookieHeader(proxy: CustomHeaders, attempt: [HTTPResponseCookie]) throws -> String {
    let proxyValue = proxy.headers.first { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame }?
      .value.trimmingCharacters(in: .whitespaces)
    let proxyNames = Set(
      (proxyValue ?? "").split(separator: ";").compactMap { pair -> String? in
        let name = pair.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
        return name?.isEmpty == false ? name : nil
      })
    guard attempt.allSatisfy({ proxyNames.contains($0.name) == false }) else {
      throw OIDCLoginError.proxyCookieConflict
    }
    let attemptValue = attempt.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    return [proxyValue, attemptValue].compactMap { $0?.isEmpty == false ? $0 : nil }
      .joined(separator: "; ")
  }

  /// 32 random bytes, base64url without padding: 43 characters, within RFC 7636's verifier limits.
  static func randomURLSafeToken() -> String {
    SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URLEncodedString()
  }

  /// RFC 7636 S256: base64url(SHA-256(ASCII verifier)).
  static func codeChallenge(for verifier: String) -> String {
    Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
  }

  private static func header(named name: String, in response: HTTPResponse) -> String? {
    response.headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  private static func bodyText(_ response: HTTPResponse) -> String {
    String(decoding: response.body.prefix(1_024), as: UTF8.self)
  }
}

extension Data {
  fileprivate func base64URLEncodedString() -> String {
    base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }
}
