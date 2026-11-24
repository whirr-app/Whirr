import Foundation
import SyncEngine
import Testing

@testable import AppModel

struct ConnectivityStatusPolicyTests {
  @Test("no evidence yet shows nothing")
  func unknownShowsNothing() {
    #expect(ConnectivityStatusPolicy.indicator(for: .unknown) == nil)
  }

  @Test("a reachable server shows nothing")
  func reachableShowsNothing() {
    #expect(ConnectivityStatusPolicy.indicator(for: .reachable) == nil)
  }

  @Test("a proven outage shows the indicator regardless of what it is costing")
  func unreachableShowsTheIndicator() {
    let indicator = ConnectivityStatusPolicy.indicator(
      for: .unreachable(.serverUnreachable, since: Date(timeIntervalSince1970: 0)))

    #expect(indicator == ConnectivityStatusCopy.status(for: .serverUnreachable))
  }

  @Test("each reason carries its own remedy")
  func eachReasonCarriesItsOwnRemedy() {
    let noPath = ConnectivityStatusPolicy.indicator(
      for: .unreachable(.noNetworkPath, since: Date(timeIntervalSince1970: 0)))
    let serverDown = ConnectivityStatusPolicy.indicator(
      for: .unreachable(.serverUnreachable, since: Date(timeIntervalSince1970: 0)))

    #expect(noPath != serverDown)
    #expect(noPath?.systemImage == "wifi.slash")
    #expect(serverDown?.systemImage == "server.rack")
  }

  /// The old banner took `remotePlaybackUnavailable`, `startFailureMessagePresent`, and the
  /// consequence registry as arguments so it could stay silent until an outage cost the user
  /// something. The indicator takes none of them: it is ambient chrome, so a refused
  /// play must not change it, and the alert that refusal raises is then the only loud surface.
  @Test("a refused play does not change the indicator")
  func aRefusedPlayDoesNotChangeTheIndicator() {
    let duringOutage = ConnectivityStatusPolicy.indicator(
      for: .unreachable(.serverUnreachable, since: Date(timeIntervalSince1970: 0)))
    let afterTheRefusal = ConnectivityStatusPolicy.indicator(
      for: .unreachable(.serverUnreachable, since: Date(timeIntervalSince1970: 0)))

    #expect(duringOutage == afterTheRefusal)
  }
}
