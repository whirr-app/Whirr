import Foundation
import Persistence
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

/// Shared fixtures for `AccountSetupTests`/`AccountLoginTests`/`AccountRestoreTests`/
/// `AccountLogoutTests`. `@testable import ABSApi` reaches `ABSClient`'s internal raw initializer,
/// putting a fake transport under the production decorator composition (Gate, Logger, transport),
/// the seam `ABSApiTests` uses.

/// Per-path canned responses or a single injected error (a raw `URLError`, `APIError`, or any
/// other `Error`) for the next request(s) on that path. Lets tests simulate TLS failures,
/// unreachable hosts, and HTTP status failures without any live network.
// Stays: ~20 other test files stub it with `await transport.stub(path:...)` and read `requests`
// through the actor, and FakeHTTPClient has no per-path response queues to stand in for it.
actor ScriptedAccountTransport: HTTPClienting {
  private var responses: [String: [HTTPResponse]] = [:]
  private var errors: [String: Error] = [:]
  private(set) var requests: [HTTPRequest] = []

  func stub(path: String, response: HTTPResponse) {
    responses[path, default: []].append(response)
  }

  func stub(path: String, error: Error) {
    errors[path] = error
  }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    requests.append(request)
    if let error = errors[request.url.path] {
      throw error
    }
    guard var queue = responses[request.url.path], queue.isEmpty == false else {
      throw FakeHTTPClientError(message: "no stubbed response for \(request.url.path)")
    }
    let response = queue.removeFirst()
    responses[request.url.path] = queue
    return response
  }
}

func makeAccountLifecycleService(
  transport: ScriptedAccountTransport,
  database: AppDatabase,
  tokenStore: any TokenStoring,
  customHeaderStore: any CustomHeaderStoring = InMemoryCustomHeaderStore(),
  clientUUIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
  loginBackoffGate: LoginBackoffGate = LoginBackoffGate(),
  clearCachedArtwork: @escaping @Sendable () async -> Void = {},
  accountRecordSaver: (@Sendable (AccountRecord) throws -> AccountRecord)? = nil
) -> AccountLifecycleService {
  AccountLifecycleService(
    tokenStore: tokenStore,
    accountDAO: AccountDAO(database: database),
    accountEndpointDAO: AccountEndpointDAO(database: database),
    accountRemover: AccountRemover(database: database),
    customHeaderStore: customHeaderStore,
    clientFactory: { server, tokenStore in
      // The header store rides along as in production, so logout's server-scoped clearing runs
      // against the same account shapes the App composes.
      ABSClient(
        server: server, httpClient: transport, tokenStore: tokenStore,
        customHeaderStore: customHeaderStore)
    },
    clientUUIDGenerator: clientUUIDGenerator,
    loginBackoffGate: loginBackoffGate,
    accountRecordSaver: accountRecordSaver,
    clearCachedArtwork: clearCachedArtwork
  )
}

/// Shaped like a real Audiobookshelf `/status`, which identifies itself with `app` before it
/// reports a version. Pass `app: nil` to omit the field entirely, or another value to stand in for
/// something else answering at the address.
func makeStatusResponse(
  serverVersion: String, app: String? = "audiobookshelf", authMethods: [String]? = nil
) -> HTTPResponse {
  let methods = authMethods.map { names in
    #""authMethods":["# + names.map { #""\#($0)""# }.joined(separator: ",") + "]"
  }
  let fields = [app.map { #""app":"\#($0)""# }, #""serverVersion":"\#(serverVersion)""#, methods]
  return HTTPResponse(
    statusCode: 200,
    headers: [:],
    body: Data("{\(fields.compactMap { $0 }.joined(separator: ","))}".utf8)
  )
}

/// A non-JSON body, the way a NAS or router admin portal answers an unknown path.
func makeHTMLPortalResponse() -> HTTPResponse {
  HTTPResponse(
    statusCode: 200,
    headers: ["Content-Type": "text/html"],
    body: Data("<html><head><title>Synology DiskStation</title></head><body></body></html>".utf8)
  )
}

func makeLoginResponse(
  userId: String,
  accessToken: String = "access-token",
  refreshToken: String = "refresh-token",
  defaultLibraryId: String? = "lib-1"
) -> HTTPResponse {
  let defaultLibraryJSON = defaultLibraryId.map { "\"\($0)\"" } ?? "null"
  let body = """
    {"user":{"id":"\(userId)","accessToken":"\(accessToken)","refreshToken":"\(refreshToken)"},"userDefaultLibraryId":\(defaultLibraryJSON)}
    """
  return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
}
