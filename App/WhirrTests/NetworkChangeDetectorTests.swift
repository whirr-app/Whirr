import Testing

@testable import Whirr

@Suite("Network change detector")
struct NetworkChangeDetectorTests {
  private let homeWiFi = NetworkSignature(interfaces: ["wifi"], gateways: ["192.168.0.1"])
  private let otherWiFi = NetworkSignature(interfaces: ["wifi"], gateways: ["10.0.0.1"])
  private let cellular = NetworkSignature(interfaces: ["cellular"], gateways: [])
  private let homeWiFiWithVPN = NetworkSignature(
    interfaces: ["other", "wifi"], gateways: ["192.168.0.1"])

  @Test("the first satisfied path is a baseline, not a change")
  func firstPathIsBaseline() {
    #expect(changes(for: [homeWiFi, homeWiFi]) == [false, false])
  }

  @Test("cellular to Wi-Fi, Wi-Fi to another Wi-Fi, and a VPN toggle are changes")
  func interfaceAndGatewayChangesAreChanges() {
    #expect(
      changes(for: [cellular, homeWiFi, otherWiFi, homeWiFi, homeWiFiWithVPN])
        == [false, true, true, true, true])
  }

  @Test("losing the network is not a change; coming back elsewhere is")
  func unsatisfiedPathsAreIgnored() {
    #expect(
      changes(for: [homeWiFi, nil, homeWiFi, nil, cellular])
        == [false, false, false, false, true])
  }

  @Test("signatures compare independent of reported order")
  func orderIndependent() {
    #expect(
      NetworkSignature(interfaces: ["wifi", "other"], gateways: ["b", "a"])
        == NetworkSignature(interfaces: ["other", "wifi"], gateways: ["a", "b"]))
  }

  private func changes(for signatures: [NetworkSignature?]) -> [Bool] {
    var detector = NetworkChangeDetector()
    return signatures.map { detector.observe($0) }
  }
}
