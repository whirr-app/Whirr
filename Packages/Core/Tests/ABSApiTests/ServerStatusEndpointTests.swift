import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// `GET /status` is the only thing setup knows about a typed URL before it sends credentials, so
/// it has to carry the server's own self-identification (`app`) and not just its version.
/// Without it, a Synology DSM portal at a bare LAN address passes setup validation and only
/// fails at the login POST with a 405.
@Suite("Server status endpoint")
struct ServerStatusEndpointTests {

  /// Setup reads a refused redirect on `/status` as "use the address it points to"; every other
  /// request keeps the plain transport failure.
  @Test("the status request opts in to reporting a refused redirect")
  func statusRequestReportsRefusedRedirect() async throws {
    let http = FakeHTTPClient(responses: [
      HTTPResponse(
        statusCode: 200, headers: ["Content-Type": "application/json"],
        body: Data(#"{"app":"audiobookshelf","serverVersion":"2.36.0"}"#.utf8))
    ])
    let client = ABSClient(
      server: try ABSServerConfig(url: #require(URL(string: "https://books.example.test"))),
      httpClient: http, tokenStore: InMemoryTokenStore())

    _ = try await client.fetchServerStatus()

    #expect(http.requests.map(\.reportsRefusedRedirect) == [true])
  }

  private func makeClient(body: String) throws -> ABSClient {
    let server = try ABSServerConfig(url: #require(URL(string: "https://books.example.test")))
    let response = HTTPResponse(
      statusCode: 200,
      headers: ["Content-Type": "application/json"],
      body: Data(body.utf8)
    )
    return ABSClient(
      server: server,
      httpClient: FakeHTTPClient(responses: [response]),
      tokenStore: InMemoryTokenStore()
    )
  }

  @Test("carries the server's own app identifier alongside the version")
  func decodesTheAppIdentifier() async throws {
    let client = try makeClient(
      body: #"{"app":"audiobookshelf","serverVersion":"2.36.0","isInit":true,"language":"en-us"}"#)

    let status = try await client.fetchServerStatus()

    #expect(status.app == "audiobookshelf")
    #expect(status.serverVersion == "2.36.0")
  }

  @Test("a foreign app identifier is carried through verbatim rather than rejected at the decoder")
  func decodesAForeignAppIdentifier() async throws {
    let client = try makeClient(body: #"{"app":"SYNO.Core.Portal","serverVersion":"7.2.1"}"#)

    #expect(try await client.fetchServerStatus().app == "SYNO.Core.Portal")
  }

  /// The field is optional at the decoder so the lifecycle layer owns the refusal and can give
  /// it a specific recovery message. A decode failure would surface as "couldn't reach it".
  @Test("a missing or non-string app identifier decodes as nil instead of throwing")
  func toleratesAMissingOrNonStringAppIdentifier() async throws {
    #expect(try await makeClient(body: #"{"serverVersion":"2.36.0"}"#).fetchServerStatus().app == nil)
    #expect(try await makeClient(body: #"{"app":7,"serverVersion":"2.36.0"}"#).fetchServerStatus().app == nil)
    #expect(try await makeClient(body: #"{"app":null,"serverVersion":"2.36.0"}"#).fetchServerStatus().app == nil)
  }

  // MARK: - Sign-in methods

  /// The repository's 2.35.1 capture: a password-only server, as every ABS server is by default.
  @Test("a password-only server's captured status decodes as local only, with no SSO button text")
  func decodesTheCapturedPasswordOnlyStatus() async throws {
    let body = try #require(String(data: try Fixtures.data(named: "status"), encoding: .utf8))
    let status = try await makeClient(body: body).fetchServerStatus()

    #expect(status.authMethods == [.local])
    #expect(status.openIDButtonText == nil)
  }

  /// Live captures from a disposable v2.37.2 container, one per sign-in configuration
  /// The button text is present only while OpenID is enabled.
  @Test("the captured v2.37.2 statuses decode each sign-in configuration")
  func decodesTheCapturedCurrentServerStatuses() async throws {
    let cases: [(fixture: String, methods: Set<ServerAuthMethod>, buttonText: String?)] = [
      ("current-server-2-37-2-status-local", [.local], nil),
      ("current-server-2-37-2-status-local-and-openid", [.local, .openID], "Sign in with Fixture SSO"),
      ("current-server-2-37-2-status-openid-only", [.openID], "Sign in with Fixture SSO"),
    ]
    for testCase in cases {
      let body = try #require(String(data: try Fixtures.data(named: testCase.fixture), encoding: .utf8))
      let status = try await makeClient(body: body).fetchServerStatus()

      #expect(status.serverVersion == "2.37.2", "\(testCase.fixture)")
      #expect(status.authMethods == testCase.methods, "\(testCase.fixture)")
      #expect(status.openIDButtonText == testCase.buttonText, "\(testCase.fixture)")
    }
  }

  /// `authFormData` carries the button text only while OpenID is enabled
  /// (`ServerSettings.authFormData`).
  @Test("a server offering both methods carries the SSO button text")
  func decodesBothMethodsAndTheButtonText() async throws {
    let client = try makeClient(
      body: #"""
        {"app":"audiobookshelf","serverVersion":"2.37.2","authMethods":["local","openid"],
         "authFormData":{"authLoginCustomMessage":"","authOpenIDButtonText":"Sign in with Pocket ID",
         "authOpenIDAutoLaunch":false}}
        """#)

    let status = try await client.fetchServerStatus()

    #expect(status.authMethods == [.local, .openID])
    #expect(status.openIDButtonText == "Sign in with Pocket ID")
  }

  @Test("an SSO-only server decodes as OpenID alone")
  func decodesAnOpenIDOnlyServer() async throws {
    let client = try makeClient(
      body: #"{"app":"audiobookshelf","serverVersion":"2.37.2","authMethods":["openid"]}"#)

    #expect(try await client.fetchServerStatus().authMethods == [.openID])
  }

  /// A future method must not hide the ones Whirr knows, and must not be mistaken for one of them.
  @Test("an unrecognized method is kept as unrecognized beside the known ones")
  func keepsAnUnrecognizedMethod() async throws {
    let client = try makeClient(
      body: #"{"app":"audiobookshelf","serverVersion":"2.37.2","authMethods":["local","passkey",7]}"#)

    #expect(try await client.fetchServerStatus().authMethods == [.local, .unrecognized("passkey")])
  }

  /// `/status` gates every setup; a malformed sign-in field must never turn a reachable server
  /// into "not Audiobookshelf".
  @Test("an absent or malformed authMethods decodes as nil instead of failing the probe")
  func toleratesAnAbsentOrMalformedAuthMethods() async throws {
    for body in [
      #"{"app":"audiobookshelf","serverVersion":"2.36.0"}"#,
      #"{"app":"audiobookshelf","serverVersion":"2.36.0","authMethods":"local"}"#,
      #"{"app":"audiobookshelf","serverVersion":"2.36.0","authMethods":null}"#,
      #"{"app":"audiobookshelf","serverVersion":"2.36.0","authFormData":"x","authMethods":{}}"#,
    ] {
      let status = try await makeClient(body: body).fetchServerStatus()
      #expect(status.authMethods == nil, "\(body)")
      #expect(status.openIDButtonText == nil, "\(body)")
    }
  }

  @Test("blank button text decodes as nil, and surrounding whitespace is trimmed")
  func normalizesTheButtonText() async throws {
    func buttonText(_ json: String) async throws -> String? {
      try await makeClient(
        body: #"{"app":"audiobookshelf","serverVersion":"2.37.2","authMethods":["openid"],"authFormData":"#
          + json + "}"
      ).fetchServerStatus().openIDButtonText
    }
    #expect(try await buttonText(#"{"authOpenIDButtonText":"   "}"#) == nil)
    #expect(try await buttonText(#"{"authOpenIDButtonText":7}"#) == nil)
    #expect(try await buttonText(#"{"authOpenIDButtonText":"  Company SSO \n"}"#) == "Company SSO")
  }
}
