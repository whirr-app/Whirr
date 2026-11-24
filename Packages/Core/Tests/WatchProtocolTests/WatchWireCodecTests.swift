import Foundation
import Testing

@testable import WatchProtocol

@Suite("Bounded Watch wire codec")
struct WatchWireCodecTests {
  private struct Probe: WatchWireValue, Equatable {
    static let maxWireBytes = 128
    let z: String
    let a: Date

    func validate() throws {
      guard z != "invalid" else { throw WatchProtocolCodingError.invalidValue }
    }
  }

  @Test func oversizeInputIsRejectedBeforeJSONDecode() {
    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchWireCodec.decode(Probe.self, from: Data(repeating: 0xff, count: Probe.maxWireBytes + 1))
    }
  }

  @Test func oversizeOutputIsRejected() {
    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchWireCodec.encode(Probe(z: String(repeating: "x", count: 128), a: Date(timeIntervalSince1970: 0)))
    }
  }

  @Test func encodeValidatesBeforeEncodingAndDecodeValidatesAfterDecoding() {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchWireCodec.encode(Probe(z: "invalid", a: Date(timeIntervalSinceReferenceDate: .nan)))
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchWireCodec.decode(Probe.self, from: Data(#"{"a":0,"z":"invalid"}"#.utf8))
    }
  }

  @Test func datesAreSecondsSinceReferenceDateAndKeysAreSorted() throws {
    let value = Probe(z: "valid", a: Date(timeIntervalSince1970: 0))
    let data = try WatchWireCodec.encode(value)
    #expect(String(decoding: data, as: UTF8.self) == #"{"a":-978307200,"z":"valid"}"#)
    #expect(try WatchProtocolFixtures.roundTrip(value) == value)
    let intervals: [Double] = [
      0, -978_307_200, 3_124_137_600, 0.123456789, -0.0,  // Includes 2100-01-01 and sub-millisecond precision.
      -1e-40, 1e-9, -0.1234567, 800_000_000.1234567, 1e15, -1e15,
    ]
    for interval in intervals {
      let probe = Probe(z: "valid", a: Date(timeIntervalSinceReferenceDate: interval))
      let encoded = try WatchWireCodec.encode(probe)
      let decoded = try WatchWireCodec.decode(Probe.self, from: encoded)
      #expect(decoded.a.timeIntervalSinceReferenceDate == interval)
      let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
      #expect(object["a"] is NSNumber)
      #expect(!(object["a"] is String))
    }
  }

  @Test func unsupportedVersionPrecedesSnapshotBodyValidation() throws {
    let snapshot = try WatchProtocolFixtures.snapshot()
    let data = try WatchWireCodec.encode(snapshot)
    #expect(try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: data) == snapshot)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "accountStamp")
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
    object["version"] = 99
    #expect(throws: WatchProtocolCodingError.unsupportedVersion(99)) {
      try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    }
  }

  @Test func versionPreflightAppliesBeforeDecodingUnversionedValueBody() {
    #expect(throws: WatchProtocolCodingError.unsupportedVersion(99)) {
      try WatchWireCodec.decode(Probe.self, from: Data(#"{"version":99,"a":"invalid","z":"invalid"}"#.utf8))
    }
  }

  @Test func valueWithoutVersionRoundTrips() throws {
    let value = Probe(z: "valid", a: Date(timeIntervalSinceReferenceDate: 42))
    let data = try WatchWireCodec.encode(value)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["version"] == nil)
    #expect(try WatchWireCodec.decode(Probe.self, from: data) == value)
  }

  @Test func browseDecodeRejectsInvalidRequestPageAndReply() throws {
    let request = try WatchBrowseRequest(accountStamp: WatchProtocolFixtures.accountStamp(), scope: .shows)
    var object = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(request)) as? [String: Any])
    object["pageSize"] = 0
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchWireCodec.decode(WatchBrowseRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }
    let page = try WatchProtocolFixtures.browsePage()
    var pageObject = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(page)) as? [String: Any])
    pageObject["generation"] = 0
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchWireCodec.decode(WatchBrowsePage.self, from: JSONSerialization.data(withJSONObject: pageObject))
    }
    let reply = try WatchBrowseReply(request: request, status: .accepted, page: page)
    var replyObject = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(reply)) as? [String: Any])
    replyObject.removeValue(forKey: "page")
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchWireCodec.decode(WatchBrowseReply.self, from: JSONSerialization.data(withJSONObject: replyObject))
    }
  }

  @Test func commandReplyIsBoundedAndValidated() throws {
    let reply = WatchReply.accepted(commandID: UUID())
    #expect(WatchReply.maxWireBytes == 8 * 1024)
    #expect(try WatchProtocolFixtures.roundTrip(reply) == reply)
    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchWireCodec.decode(WatchReply.self, from: Data(repeating: 0, count: WatchReply.maxWireBytes + 1))
    }
    var object = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(reply)) as? [String: Any])
    object["status"] = "rejected"
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchWireCodec.decode(WatchReply.self, from: JSONSerialization.data(withJSONObject: object))
    }
  }

  /// A cache or skewed phone may still carry the retired lease. It is ignored, in any
  /// shape, and the rest of the snapshot survives.
  @Test func aRetiredPlaybackLeaseIsIgnoredOnDecode() throws {
    let stamp = WatchProtocolFixtures.accountStamp()
    let snapshot = try WatchCatalogueSnapshot(
      accountStamp: stamp, items: [WatchProtocolFixtures.catalogueItem()], playbackState: .paused,
      authenticatedAccountStamp: stamp)
    var object = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(snapshot)) as? [String: Any])
    object["playbackLease"] = ["owner": "watch", "generation": "not-a-number"]
    let decoded = try WatchWireCodec.decode(
      WatchCatalogueSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded == snapshot)
  }

  @Test func fractionalDatesPreserveExactSetupChallengeIdentity() throws {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000.1234567)
    let hello = try WatchSetupHello(id: UUID(), accountStamp: WatchProtocolFixtures.accountStamp(), issuedAt: now)
    var admission = WatchSetupAdmission()
    let challenge = admission.begin(try WatchProtocolFixtures.roundTrip(hello), existingAccount: nil, now: now)
    let receivedChallenge = try WatchProtocolFixtures.roundTrip(challenge)
    #expect(receivedChallenge == challenge)
    let credentials = try WatchProtocolFixtures.setupCredentials(for: receivedChallenge)
    #expect(try admission.admit(WatchProtocolFixtures.roundTrip(credentials), now: now) == false)
    for date in [now, Date(), Date(timeIntervalSinceReferenceDate: -0.1234567)] {
      let value = Probe(z: "valid", a: date)
      #expect(try WatchProtocolFixtures.roundTrip(value) == value)
    }
  }
}
