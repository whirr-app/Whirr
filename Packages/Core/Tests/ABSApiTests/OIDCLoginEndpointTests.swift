import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// The app-side legs of the ABS mobile OIDC flow, over the stub transport beneath the production
/// decorator stack. Server behaviour is from ABS v2.35.1 and v2.37.2 (`server/Auth.js`,
/// `server/auth/OidcAuthStrategy.js`), which agree on every case here.
@Suite("OIDC login endpoint")
struct OIDCLoginEndpointTests {
  private static let serverURL = URL(string: "https://books.example.test")!
  private static let idpURL = "https://idp.example.test/authorize?client_id=abs&state=x"
  private static let sessionCookie = HTTPResponseCookie(name: "connect.sid", value: "s%3Asession")
  private static let methodCookie = HTTPResponseCookie(name: "auth_method", value: "openid-mobile")

  private func makeClient(
    responses: [HTTPResponse], customHeaders: [String: String] = [:], url: URL = serverURL
  ) throws -> (ABSClient, FakeHTTPClient, InMemoryTokenStore) {
    let http = FakeHTTPClient(responses: responses)
    let store = InMemoryTokenStore()
    let server = try ABSServerConfig(url: url, customHeaders: CustomHeaders(customHeaders))
    return (ABSClient(server: server, httpClient: http, tokenStore: store), http, store)
  }

  private static func leg1Redirect(cookies: [HTTPResponseCookie] = [sessionCookie, methodCookie]) -> HTTPResponse {
    HTTPResponse(statusCode: 302, headers: ["Location": idpURL], body: Data(), cookies: cookies)
  }

  private static func text(_ status: Int, _ body: String) -> HTTPResponse {
    HTTPResponse(statusCode: status, headers: ["Content-Type": "text/html"], body: Data(body.utf8))
  }

  private static func loginJSON(userID: String = "user-1", refreshToken: String = "refresh-1") -> HTTPResponse {
    HTTPResponse(
      statusCode: 200, headers: ["Content-Type": "application/json"],
      body: Data(
        #"""
        {"user":{"id":"\#(userID)","username":"sso-user","accessToken":"access-1","refreshToken":"\#(refreshToken)"},
         "userDefaultLibraryId":"lib-1","serverSettings":{},"Source":"docker"}
        """#.utf8))
  }

  private static func callback(for attempt: OIDCAttempt, code: String? = "auth-code", state: String? = nil) -> URL {
    var components = URLComponents(string: OIDCAttempt.redirectURI)!
    components.queryItems = [
      code.map { URLQueryItem(name: "code", value: $0) },
      URLQueryItem(name: "state", value: state ?? attempt.state),
    ].compactMap { $0 }
    return components.url!
  }

  private static func query(_ request: HTTPRequest) -> [String: String] {
    let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
  }

  // MARK: - First leg

  @Test("the first leg asks for the mobile code flow with S256 PKCE and surfaces the redirect")
  func firstLegRequestsTheMobileFlow() async throws {
    let (client, http, _) = try makeClient(responses: [Self.leg1Redirect()])

    let attempt = try await client.beginOIDCLogin()

    let request = try #require(http.requests.first)
    #expect(request.url.path == "/auth/openid")
    #expect(request.isAuthenticationRoute)
    #expect(request.surfacesRedirectAndCookies)
    let query = Self.query(request)
    #expect(query["response_type"] == "code")
    #expect(query["redirect_uri"] == "whirr://oauth")
    #expect(query["code_challenge_method"] == "S256")
    #expect(query["state"] == attempt.state)
    #expect(query["code_challenge"] == ABSClient.codeChallenge(for: attempt.codeVerifier))
    #expect(query["code_verifier"] == nil, "the verifier never travels on the first leg")
    #expect(attempt.authorizationURL.absoluteString == Self.idpURL)
    #expect(attempt.cookies == [Self.sessionCookie, Self.methodCookie])
  }

  @Test("every attempt gets its own state and verifier")
  func attemptsAreIndependent() async throws {
    let (client, _, _) = try makeClient(responses: [Self.leg1Redirect(), Self.leg1Redirect()])

    let first = try await client.beginOIDCLogin()
    let second = try await client.beginOIDCLogin()

    #expect(first.state != second.state)
    #expect(first.codeVerifier != second.codeVerifier)
    #expect(first.codeVerifier.count == 43)
  }

  /// RFC 7636 Appendix B.
  @Test("the S256 challenge matches the RFC 7636 test vector")
  func challengeMatchesTheRFCVector() {
    #expect(
      ABSClient.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
  }

  @Test("proxy headers are sent on the first leg")
  func firstLegCarriesProxyHeaders() async throws {
    let (client, http, _) = try makeClient(
      responses: [Self.leg1Redirect()], customHeaders: ["X-Proxy-Token": "proxy-secret"])

    _ = try await client.beginOIDCLogin()

    #expect(http.requests.first?.headers["X-Proxy-Token"] == "proxy-secret")
  }

  /// On plain HTTP an on-path attacker could swap the identity provider's page for a fake and
  /// collect the user's IdP password, which reaches far beyond this server.
  @Test("a plain-HTTP server is refused before any request is sent")
  func plainHTTPServerIsRefusedWithoutARequest() async throws {
    let (client, http, _) = try makeClient(
      responses: [Self.leg1Redirect()], url: URL(string: "http://books.example.test")!)

    await #expect(throws: OIDCLoginError.requiresHTTPS) { try await client.beginOIDCLogin() }
    #expect(http.requests.isEmpty)
  }

  @Test("an unlisted redirect URI is reported precisely, before any browser opens")
  func unlistedRedirectURIIsReported() async throws {
    let (client, _, _) = try makeClient(responses: [Self.text(400, "Invalid redirect_uri")])

    await #expect(throws: OIDCLoginError.redirectURINotAllowed) { try await client.beginOIDCLogin() }
  }

  @Test("any other first-leg refusal means SSO is unavailable on this server")
  func otherFirstLegRefusalsAreUnavailable() async throws {
    for response in [
      Self.text(400, "Only S256 code_challenge_method method supported"),
      Self.text(500, "Unknown error"),
      Self.text(404, "Not Found"),
      Self.text(200, "<html>a proxy login page</html>"),
    ] {
      let (client, _, _) = try makeClient(responses: [response])
      await #expect(throws: OIDCLoginError.unavailable) { try await client.beginOIDCLogin() }
    }
  }

  @Test("a rate-limited first leg stays a rate limit")
  func firstLegRateLimit() async throws {
    let (client, _, _) = try makeClient(responses: [Self.text(429, "Too many requests")])

    await #expect(throws: APIError.rateLimited) { try await client.beginOIDCLogin() }
  }

  @Test("a redirect without a usable web location is malformed")
  func redirectWithoutAWebLocationIsMalformed() async throws {
    for headers in [
      [:], ["Location": "javascript:alert(1)"], ["Location": "whirr://oauth?code=x"],
      ["Location": "https://user:secret@idp.example.test/authorize"],
    ] {
      let (client, _, _) = try makeClient(
        responses: [HTTPResponse(statusCode: 302, headers: headers, body: Data())])
      await #expect(throws: APIError.decoding) { try await client.beginOIDCLogin() }
    }
  }

  // MARK: - Callback

  @Test("the callback replays both first-leg cookies and exchanges code, state and verifier")
  func callbackReplaysCookiesAndExchanges() async throws {
    let (client, http, store) = try makeClient(responses: [Self.leg1Redirect(), Self.loginJSON()])
    let attempt = try await client.beginOIDCLogin()

    let session = try await client.prepareOIDCLogin(attempt: attempt, callbackURL: Self.callback(for: attempt))

    let request = try #require(http.requests.last)
    #expect(request.url.path == "/auth/openid/callback")
    #expect(request.isAuthenticationRoute)
    #expect(request.surfacesRedirectAndCookies)
    #expect(request.httpShouldHandleCookies == false)
    #expect(request.headers["Cookie"] == "connect.sid=s%3Asession; auth_method=openid-mobile")
    let query = Self.query(request)
    #expect(query["code"] == "auth-code")
    #expect(query["state"] == attempt.state)
    #expect(query["code_verifier"] == attempt.codeVerifier)

    #expect(session.userID == "user-1")
    #expect(session.defaultLibraryID == "lib-1")
    #expect(try store.load(for: session.account) == nil, "nothing is stored before commit")
    try await client.commitLogin(session)
    #expect(try store.load(for: session.account) == TokenPair(accessToken: "access-1", refreshToken: "refresh-1"))
  }

  @Test("a proxy Cookie header is kept and the attempt's cookies follow it")
  func proxyCookieIsMerged() async throws {
    let (client, http, _) = try makeClient(
      responses: [Self.leg1Redirect(), Self.loginJSON()], customHeaders: ["Cookie": "CF_Authorization=edge"])
    let attempt = try await client.beginOIDCLogin()

    _ = try await client.prepareOIDCLogin(attempt: attempt, callbackURL: Self.callback(for: attempt))

    let cookie = http.requests.last?.headers.first { $0.key.lowercased() == "cookie" }
    #expect(cookie?.value == "CF_Authorization=edge; connect.sid=s%3Asession; auth_method=openid-mobile")
    #expect(http.requests.last?.headers.keys.filter { $0.lowercased() == "cookie" }.count == 1)
  }

  @Test("a proxy cookie sharing a name with a server cookie is refused without a request")
  func proxyCookieCollisionIsRefused() async throws {
    let (client, http, _) = try makeClient(
      responses: [Self.leg1Redirect()], customHeaders: ["cookie": "a=1; connect.sid=proxy"])
    let attempt = try await client.beginOIDCLogin()

    await #expect(throws: OIDCLoginError.proxyCookieConflict) {
      try await client.prepareOIDCLogin(attempt: attempt, callbackURL: Self.callback(for: attempt))
    }
    #expect(http.requests.count == 1)
  }

  @Test("the callback's server failures each map to their own recovery")
  func callbackFailuresAreDistinct() async throws {
    let cases: [(HTTPResponse, OIDCLoginError)] = [
      (Self.text(400, "No session"), .attemptExpired),
      (
        HTTPResponse(
          statusCode: 302, headers: ["Location": "/login?error=Unauthorized&autoLaunch=0"], body: Data()),
        .refused
      ),
      (Self.text(401, "Unauthorized"), .refused),
      (Self.text(500, "Error in callback"), .refused),
    ]
    for (response, expected) in cases {
      let (client, _, _) = try makeClient(responses: [Self.leg1Redirect(), response])
      let attempt = try await client.beginOIDCLogin()
      await #expect(throws: expected) {
        try await client.prepareOIDCLogin(attempt: attempt, callbackURL: Self.callback(for: attempt))
      }
    }
  }

  @Test("a callback for another state is refused without a request")
  func stateMismatchIsRefused() async throws {
    let (client, http, _) = try makeClient(responses: [Self.leg1Redirect()])
    let attempt = try await client.beginOIDCLogin()

    await #expect(throws: OIDCLoginError.stateMismatch) {
      try await client.prepareOIDCLogin(attempt: attempt, callbackURL: Self.callback(for: attempt, state: "other"))
    }
    #expect(http.requests.count == 1)
  }

  /// ABS's mobile-redirect drops the provider's `error` and sends `code=undefined`.
  @Test("a missing, empty or undefined code is a refusal, not an exchange")
  func missingCodeIsARefusal() async throws {
    for code in [nil, "", "undefined"] as [String?] {
      let (client, http, _) = try makeClient(responses: [Self.leg1Redirect()])
      let attempt = try await client.beginOIDCLogin()
      await #expect(throws: OIDCLoginError.refused) {
        try await client.prepareOIDCLogin(attempt: attempt, callbackURL: Self.callback(for: attempt, code: code))
      }
      #expect(http.requests.count == 1)
    }
  }

  @Test("a callback to another scheme or host is invalid")
  func foreignCallbackIsInvalid() async throws {
    for url in ["https://oauth/?code=c", "whirr://elsewhere?code=c", "audiobookshelf://oauth?code=c"] {
      let (client, _, _) = try makeClient(responses: [Self.leg1Redirect()])
      let attempt = try await client.beginOIDCLogin()
      await #expect(throws: OIDCLoginError.invalidCallback) {
        try await client.prepareOIDCLogin(attempt: attempt, callbackURL: URL(string: url + "&state=\(attempt.state)")!)
      }
    }
  }

  @Test("an attempt completes once; a second callback or an abandoned attempt is refused")
  func attemptsAreSingleUse() async throws {
    let (client, http, _) = try makeClient(responses: [Self.leg1Redirect(), Self.loginJSON(), Self.leg1Redirect()])
    let used = try await client.beginOIDCLogin()
    _ = try await client.prepareOIDCLogin(attempt: used, callbackURL: Self.callback(for: used))

    await #expect(throws: OIDCLoginError.attemptAlreadyUsed) {
      try await client.prepareOIDCLogin(attempt: used, callbackURL: Self.callback(for: used))
    }

    let abandoned = try await client.beginOIDCLogin()
    abandoned.abandon()
    await #expect(throws: OIDCLoginError.attemptAlreadyUsed) {
      try await client.prepareOIDCLogin(attempt: abandoned, callbackURL: Self.callback(for: abandoned))
    }
    #expect(http.requests.count == 3)
  }

  /// The attempt's cookies are another server's session secrets (SECURITY.md rule 5).
  @Test("an attempt begun on one server is never completed against another")
  func attemptIsBoundToItsServer() async throws {
    let (origin, _, _) = try makeClient(responses: [Self.leg1Redirect()])
    let attempt = try await origin.beginOIDCLogin()
    let (other, http, _) = try makeClient(
      responses: [Self.loginJSON()], url: URL(string: "https://other.example.test")!)

    await #expect(throws: OIDCLoginError.attemptForAnotherServer) {
      try await other.prepareOIDCLogin(attempt: attempt, callbackURL: Self.callback(for: attempt))
    }
    #expect(http.requests.isEmpty)
  }

  @Test("a success without a refresh token is malformed, as for password login")
  func emptyRefreshTokenIsMalformed() async throws {
    let (client, _, _) = try makeClient(responses: [Self.leg1Redirect(), Self.loginJSON(refreshToken: "")])
    let attempt = try await client.beginOIDCLogin()

    await #expect(throws: APIError.decoding) {
      try await client.prepareOIDCLogin(attempt: attempt, callbackURL: Self.callback(for: attempt))
    }
  }

  @Test("an attempt and a response cookie never print their secrets")
  func secretsAreRedacted() async throws {
    let (client, _, _) = try makeClient(responses: [Self.leg1Redirect()])
    let attempt = try await client.beginOIDCLogin()

    for text in [String(describing: attempt), String(reflecting: attempt), String(describing: Self.sessionCookie)] {
      #expect(text.contains(attempt.state) == false)
      #expect(text.contains(attempt.codeVerifier) == false)
      #expect(text.contains("s%3Asession") == false)
    }
  }

  @Test("an ordinary request does not opt in")
  func ordinaryRequestsDoNotOptIn() throws {
    let builder = RequestBuilder(server: try ABSServerConfig(url: Self.serverURL))

    #expect(try builder.makeRequest(method: .get, path: "/status").surfacesRedirectAndCookies == false)
    #expect(
      try builder.makeRequest(method: .get, path: "/login", isAuthenticationRoute: true)
        .surfacesRedirectAndCookies == false)
  }
}
