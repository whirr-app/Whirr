import Foundation
import Testing

@testable import WatchProtocol

@Suite("Watch status report")
struct WatchStatusReportTests {
  private let account = WatchProtocolFixtures.accountStamp()
  private let checkedAt = Date(timeIntervalSinceReferenceDate: 4_000)
  private let reportedAt = Date(timeIntervalSinceReferenceDate: 4_100)

  @Test func aStatusReportRoundTripsWithItsCheckTimeAndCapabilities() throws {
    let report = try WatchStatusReport(
      accountStamp: account, health: .healthy, checkedAt: checkedAt, reportedAt: reportedAt,
      capabilities: [WatchStatusCapability.enclosureFetch])

    let decoded = try WatchProtocolFixtures.roundTrip(report)

    #expect(decoded == report)
    #expect(decoded.checkedAt == checkedAt)
    #expect(decoded.capabilities == [WatchStatusCapability.enclosureFetch])
  }

  /// A Watch that can take Audiobookshelf sends says so separately from RSS enclosure fetch, so a
  /// phone can keep RSS working for a Watch that has only the older capability (ADR 0021 Decision 6).
  @Test func theAudiobookshelfSendCapabilityIsItsOwnName() throws {
    #expect(WatchStatusCapability.absSend == "absSend")
    #expect(WatchStatusReport.isValidCapability(WatchStatusCapability.absSend))
    let report = try WatchStatusReport(
      accountStamp: account, reportedAt: reportedAt,
      capabilities: [WatchStatusCapability.enclosureFetch, WatchStatusCapability.absSend])
    #expect(try WatchProtocolFixtures.roundTrip(report).capabilities.contains(WatchStatusCapability.absSend))
  }

  @Test func aSignedOutReportCarriesNoHealthOrCheckTime() throws {
    let report = try WatchStatusReport(accountStamp: nil, reportedAt: reportedAt)

    let decoded = try WatchProtocolFixtures.roundTrip(report)

    #expect(decoded == report)
    #expect(decoded.accountStamp == nil)
    #expect(decoded.health == nil)
    #expect(decoded.checkedAt == nil)
    #expect(decoded.capabilities.isEmpty)
  }

  @Test func theTransportKeyIsItsOwnValue() {
    #expect(WatchStatusReport.transportKey == "whirr.watch.status-report.v1")
    #expect(WatchTransportKey.statusReport == WatchStatusReport.transportKey)
    #expect(WatchStatusReport.maxWireBytes == 4 * 1024)
  }

  @Test func unknownHealthDecodesAsNoVerdictRatherThanFailingTheReport() throws {
    let report = try WatchStatusReport(accountStamp: account, health: .healthy, checkedAt: checkedAt)
    var object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(report)) as? [String: Any])

    object["health"] = "serverRetired"
    let unknown = try WatchWireCodec.decode(
      WatchStatusReport.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(unknown.health == nil)
    #expect(unknown.accountStamp == account)

    object["health"] = 7
    let wrongType = try WatchWireCodec.decode(
      WatchStatusReport.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(wrongType.health == nil)
  }

  @Test func unknownShapedCapabilitiesAreDroppedNotFatal() throws {
    let report = try WatchStatusReport(accountStamp: account, reportedAt: reportedAt)
    var object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(report)) as? [String: Any])
    object["capabilities"] = [
      "enclosureFetch", "future.flag-2", "", String(repeating: "a", count: 65), "bad/name", "space name",
    ]

    let decoded = try WatchWireCodec.decode(
      WatchStatusReport.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.capabilities == ["enclosureFetch", "future.flag-2"])
  }

  @Test func aMissingCapabilitiesKeyDecodesAsEmpty() throws {
    let report = try WatchStatusReport(accountStamp: account, health: .serverUnreachable, checkedAt: checkedAt)
    var object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(report)) as? [String: Any])
    object.removeValue(forKey: "capabilities")

    let decoded = try WatchWireCodec.decode(
      WatchStatusReport.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded.capabilities.isEmpty)
    #expect(decoded.health == .serverUnreachable)
  }

  @Test func capabilityBoundsFailClosed() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      _ = try WatchStatusReport(
        accountStamp: account,
        capabilities: Set((0...WatchStatusReport.maxCapabilities).map { "cap-\($0)" }))
    }
    for invalid in ["", String(repeating: "a", count: WatchStatusReport.maxCapabilityBytes + 1), "a/b", "a b"] {
      #expect(throws: WatchProtocolCodingError.invalidValue) {
        _ = try WatchStatusReport(accountStamp: account, capabilities: [invalid])
      }
    }
  }

  @Test func tooManyValidCapabilitiesOnTheWireFailClosed() throws {
    let report = try WatchStatusReport(accountStamp: account, reportedAt: reportedAt)
    var object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(report)) as? [String: Any])
    object["capabilities"] = (0...WatchStatusReport.maxCapabilities).map { "cap-\($0)" }

    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchWireCodec.decode(
        WatchStatusReport.self, from: JSONSerialization.data(withJSONObject: object))
    }
  }

  @Test func nonFiniteDatesAndVersionsFailClosed() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      _ = try WatchStatusReport(
        accountStamp: account, checkedAt: Date(timeIntervalSinceReferenceDate: .nan))
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      _ = try WatchStatusReport(
        accountStamp: account, reportedAt: Date(timeIntervalSinceReferenceDate: .infinity))
    }

    let report = try WatchStatusReport(accountStamp: account)
    var object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(report)) as? [String: Any])
    object["version"] = 99
    #expect(throws: WatchProtocolCodingError.unsupportedVersion(99)) {
      try WatchWireCodec.decode(
        WatchStatusReport.self, from: JSONSerialization.data(withJSONObject: object))
    }
  }

  @Test func aFullCapabilitySetStaysUnderTheWireCap() throws {
    let capabilities = Set(
      (0..<WatchStatusReport.maxCapabilities).map { index in
        "capability-\(index)-" + String(repeating: "x", count: 40)
      })
    let report = try WatchStatusReport(
      accountStamp: account, health: .signInRejected, checkedAt: checkedAt, capabilities: capabilities)

    let data = try WatchWireCodec.encode(report)
    #expect(data.count < WatchStatusReport.maxWireBytes)
    #expect(try WatchWireCodec.decode(WatchStatusReport.self, from: data) == report)

    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchWireCodec.decode(
        WatchStatusReport.self, from: Data(repeating: 0, count: WatchStatusReport.maxWireBytes + 1))
    }
  }

  @Test func anAccountStampOnTheReportIsValidated() throws {
    let report = try WatchStatusReport(accountStamp: account)
    var object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(report)) as? [String: Any])
    var stamp = try #require(object["accountStamp"] as? [String: Any])
    stamp["accountIdentityHash"] = "unsafe\nhash"
    object["accountStamp"] = stamp

    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchWireCodec.decode(
        WatchStatusReport.self, from: JSONSerialization.data(withJSONObject: object))
    }
  }
}
