import Foundation
import Persistence
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Setup validation: a typed URL normalizes via `ABSServerConfig`, fetches `/status`, and
/// runs `ABSServerCompatibilityGate`. The failures below must classify distinctly (own recovery
/// message per case): every case in `AccountLifecycleError` maps to exactly one test here.
@Suite struct AccountSetupTests {

  private func makeService(transport: ScriptedAccountTransport) throws -> AccountLifecycleService {
    makeAccountLifecycleService(
      transport: transport,
      database: try AppDatabase.inMemory(),
      tokenStore: InMemoryTokenStore()
    )
  }

  @Test func validatesAndNormalizesAReachableCompatibleServer() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    let service = try makeService(transport: transport)

    let result = try await service.validateServer(url: try #require(URL(string: "https://books.example.test")))

    #expect(result.serverVersion == "2.36.0")
    #expect(result.isPlainHTTP == false)
    #expect(await transport.requests.map(\.url.path) == ["/status"])
  }

  @Test("passes caller-supplied headers to the pre-auth probe and validated server")
  func validatesWithCustomHeaders() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    let service = try makeService(transport: transport)
    let fields = ["X-Proxy-Token": "proxy-secret"]

    let result = try await service.validateServer(
      url: try #require(URL(string: "https://books.example.test")), customHeaders: fields)

    #expect(result.customHeaders.headers == fields)
    #expect(await transport.requests.first?.headers["X-Proxy-Token"] == "proxy-secret")
  }

  /// The sign-in methods `/status` advertises reach the setup flow instead of being dropped.
  @Test("the validated server carries the sign-in methods the status advertised")
  func carriesTheAdvertisedSignInMethods() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/status", response: makeStatusResponse(serverVersion: "2.37.2", authMethods: ["local", "openid"]))
    let service = try makeService(transport: transport)

    let result = try await service.validateServer(url: try #require(URL(string: "https://books.example.test")))

    #expect(result.authMethods == [.local, .openID])
    #expect(result.offersOnlySingleSignOn == false)
  }

  @Test("a status without sign-in methods validates, carrying none")
  func validatesAStatusWithoutSignInMethods() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0"))
    let service = try makeService(transport: transport)

    let result = try await service.validateServer(url: try #require(URL(string: "https://books.example.test")))

    #expect(result.authMethods == nil)
    #expect(result.offersOnlySingleSignOn == false)
  }

  /// Only a server that positively advertises OpenID and not password sign-in is SSO-only; an
  /// absent or empty list is a malformed response, never evidence that passwords are refused.
  @Test("only OpenID without local sign-in counts as SSO-only")
  func classifiesSingleSignOnOnly() throws {
    let cases: [(methods: Set<ServerAuthMethod>?, expected: Bool)] = [
      ([.openID], true),
      ([.openID, .unrecognized("passkey")], true),
      ([.local, .openID], false),
      ([.local], false),
      ([], false),
      ([.unrecognized("passkey")], false),
      (nil, false),
    ]
    let url = try #require(URL(string: "https://books.example.test"))
    for testCase in cases {
      let server = ValidatedServer(
        serverURL: url, serverVersion: "2.37.2", isPlainHTTP: false, authMethods: testCase.methods)
      #expect(server.offersOnlySingleSignOn == testCase.expected, "\(String(describing: testCase.methods))")
    }
  }

  @Test func httpSchemeIsInformationalNotAnError() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.35.1"))
    let service = try makeService(transport: transport)

    let result = try await service.validateServer(url: try #require(URL(string: "http://tailnet.example.test")))

    #expect(result.isPlainHTTP == true)
    #expect(result.serverVersion == "2.35.1")
  }

  @Test func malformedURLNeverReachesTheNetwork() async throws {
    let transport = ScriptedAccountTransport()
    let service = try makeService(transport: transport)

    await #expect(throws: AccountLifecycleError.malformedURL) {
      // A query string is rejected by `ABSServerConfig` before any request is built.
      _ = try await service.validateServer(url: try #require(URL(string: "https://books.example.test/?x=1")))
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test func unreachableServerClassifiesDistinctlyFromTLSFailure() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", error: URLError(.cannotConnectToHost))
    let service = try makeService(transport: transport)

    await #expect(throws: AccountLifecycleError.unreachable) {
      _ = try await service.validateServer(url: try #require(URL(string: "https://unreachable.example.test")))
    }
  }

  @Test func untrustedTLSCertificateClassifiesDistinctlyFromUnreachable() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", error: URLError(.serverCertificateUntrusted))
    let service = try makeService(transport: transport)

    await #expect(throws: AccountLifecycleError.tlsUntrusted) {
      _ = try await service.validateServer(url: try #require(URL(string: "https://badcert.example.test")))
    }
  }

  @Test func oldServerVersionClassifiesAsIncompatibleCarryingTheDetectedVersion() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.10.0"))
    let service = try makeService(transport: transport)

    await #expect(throws: AccountLifecycleError.incompatibleServer(detectedVersion: "2.10.0")) {
      _ = try await service.validateServer(url: try #require(URL(string: "https://old.example.test")))
    }
  }

  @Test func unparseableServerVersionClassifiesAsIncompatibleWithNoDetectedVersion() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "garbage"))
    let service = try makeService(transport: transport)

    await #expect(throws: AccountLifecycleError.incompatibleServer(detectedVersion: nil)) {
      _ = try await service.validateServer(url: try #require(URL(string: "https://unparseable.example.test")))
    }
  }

  // MARK: - Server identity

  /// A NAS portal (such as a Synology DSM page) can pass this step with a green check and only
  /// fail at the login POST with a 405, by which point the recovery copy blames the
  /// credentials. Validation has to establish that Audiobookshelf is what answered.

  @Test("a server identifying itself as another app is rejected as not Audiobookshelf")
  func foreignAppIdentifierIsRejected() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/status", response: makeStatusResponse(serverVersion: "7.2.1", app: "SYNO.Core.Portal"))
    let service = try makeService(transport: transport)

    await #expect(throws: AccountLifecycleError.notAudiobookshelfServer) {
      _ = try await service.validateServer(url: try #require(URL(string: "https://192.168.0.10")))
    }
  }

  @Test("a JSON response that never identifies the app is rejected rather than assumed")
  func missingAppIdentifierIsRejected() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeStatusResponse(serverVersion: "2.36.0", app: nil))
    let service = try makeService(transport: transport)

    await #expect(throws: AccountLifecycleError.notAudiobookshelfServer) {
      _ = try await service.validateServer(url: try #require(URL(string: "https://anonymous.example.test")))
    }
  }

  /// A NAS/router landing page answers 200 with HTML. That is "the wrong thing is here", not
  /// "nothing is here", so it must not classify as `.unreachable`. The unreachable copy sends the
  /// user off to check their network and Tailscale for an address that answered immediately.
  @Test("a non-JSON portal response is rejected as not Audiobookshelf, not as unreachable")
  func nonJSONPortalResponseIsRejected() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", response: makeHTMLPortalResponse())
    let service = try makeService(transport: transport)

    await #expect(throws: AccountLifecycleError.notAudiobookshelfServer) {
      _ = try await service.validateServer(url: try #require(URL(string: "https://192.168.0.10")))
    }
  }

  /// Identity is checked before the version gate: naming a "version" read off something that
  /// isn't Audiobookshelf would send the user to their server admin for an upgrade that has
  /// nothing to do with the problem.
  @Test("app identity is decided before the version gate")
  func identityIsCheckedBeforeTheVersionGate() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/status", response: makeStatusResponse(serverVersion: "2.10.0", app: "SYNO.Core.Portal"))
    let service = try makeService(transport: transport)

    await #expect(throws: AccountLifecycleError.notAudiobookshelfServer) {
      _ = try await service.validateServer(url: try #require(URL(string: "https://192.168.0.10")))
    }
  }

  /// Audiobookshelf never gates `/status`, so a 401 or 403 there came from something in front of
  /// it. Calling that unreachable sends the user to check a network that answered immediately.
  @Test("a 401 or 403 on status is a proxy refusal, not unreachable", arguments: [401, 403])
  func statusRefusalIsBlockedByProxy(statusCode: Int) async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/status", response: HTTPResponse(statusCode: statusCode, headers: [:], body: Data("denied".utf8)))
    let service = try makeService(transport: transport)

    await #expect(throws: AccountLifecycleError.blockedByProxy) {
      _ = try await service.validateServer(url: try #require(URL(string: "https://books.example.test")))
    }
  }

  @Test("a refused redirect on status carries its target")
  func refusedRedirectOnStatusIsRedirected() async throws {
    let target = try #require(URL(string: "https://books.example.test/status"))
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", error: RefusedRedirectError(target: target))
    let service = try makeService(transport: transport)

    await #expect(throws: AccountLifecycleError.redirected(target: target)) {
      _ = try await service.validateServer(url: try #require(URL(string: "http://books.example.test")))
    }
  }

  @Test("the app identifier is matched case-insensitively")
  func appIdentifierIsMatchedCaseInsensitively() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(
      path: "/status", response: makeStatusResponse(serverVersion: "2.36.0", app: "AudioBookshelf"))
    let service = try makeService(transport: transport)

    let result = try await service.validateServer(url: try #require(URL(string: "https://books.example.test")))

    #expect(result.serverVersion == "2.36.0")
  }

  /// A transport failure still means "couldn't reach it". The identity check must not swallow
  /// the distinction the recovery copy depends on.
  @Test("a transport failure still classifies as unreachable, not as a foreign server")
  func transportFailureIsNotReclassifiedAsAForeignServer() async throws {
    let transport = ScriptedAccountTransport()
    await transport.stub(path: "/status", error: URLError(.cannotConnectToHost))
    let service = try makeService(transport: transport)

    await #expect(throws: AccountLifecycleError.unreachable) {
      _ = try await service.validateServer(url: try #require(URL(string: "https://unreachable.example.test")))
    }
  }
}
