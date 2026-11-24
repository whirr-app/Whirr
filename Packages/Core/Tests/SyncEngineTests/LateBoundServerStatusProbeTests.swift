import Foundation
import TestSupport
import Testing

@testable import ABSApi
@testable import SyncEngine

@Suite("Late-bound server status probe")
struct LateBoundServerStatusProbeTests {
  /// `.cancelled` is the monitor's "no verdict" code, not an arbitrary choice: an unsent request is
  /// evidence about the composition, not the server. `ServerReachabilityMonitorTests` pins the
  /// other half (a cancelled probe leaves the state alone and re-arms recovery), so together
  /// these guarantee an unbound slot can never assert an outage. Any other code here would, because
  /// a probe failure bypasses the three-failure hysteresis.
  @Test("reports no verdict rather than an outage before a client is set")
  func reportsNoVerdictBeforeBinding() async {
    let probe = LateBoundServerStatusProbe()

    do {
      try await probe.probeServerStatus()
      Issue.record("expected an unbound probe to report no answer")
    } catch let error as URLError {
      #expect(error.code == .cancelled)
    } catch {
      Issue.record("expected URLError, got \(error)")
    }
  }

  @Test("forwards to the bound client")
  func forwardsAfterBinding() async throws {
    let server = try ABSServerConfig(url: URL(string: "https://books.example.test")!)
    let http = FakeHTTPClient(
      responses: [
        HTTPResponse(
          statusCode: 200,
          headers: ["Content-Type": "application/json"],
          body: Data(#"{"serverVersion":"2.35.1"}"#.utf8))
      ])
    let client = ABSClient(server: server, httpClient: http, tokenStore: InMemoryTokenStore())
    let probe = LateBoundServerStatusProbe()

    probe.setClient(client)
    try await probe.probeServerStatus()

    #expect(http.requests.count == 1)
    #expect(http.requests[0].url.path == "/status")
  }
}
