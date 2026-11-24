import Foundation
import Testing

@testable import WatchProtocol

/// The playing report gains an optional native field beside the ABS-only `selection` (ADR 0019
/// decision 3). Old reports must decode unchanged.
struct WatchPlayingReportTests {
  private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

  @Test func anOlderReportWithoutANativeFieldDecodesAsNil() throws {
    let legacy = try WatchPlayingReport(
      accountStamp: WatchProtocolFixtures.accountStamp(),
      selection: WatchABSSelection(itemID: "book", episodeID: nil), playing: true, observedAt: now)
    var object = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(legacy)) as? [String: Any])
    #expect(object["nativeSelection"] == nil)
    object.removeValue(forKey: "nativeSelection")
    let decoded = try WatchWireCodec.decode(
      WatchPlayingReport.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(decoded == legacy)
    #expect(decoded.nativeSelection == nil)
    #expect(decoded.selection?.itemID == "book")
  }

  @Test func aNativeOnlyPlayingReportRoundTrips() throws {
    let report = try WatchPlayingReport(
      accountStamp: WatchProtocolFixtures.accountStamp(), selection: nil, playing: true, observedAt: now,
      nativeSelection: WatchNativeSelection(feedID: "feed", episodeID: "episode"))
    let decoded = try WatchProtocolFixtures.roundTrip(report)
    #expect(decoded == report)
    #expect(decoded.selection == nil)
    #expect(decoded.nativeSelection?.feedID == "feed")
    #expect(decoded.isPlaying(for: WatchProtocolFixtures.accountStamp(), at: now))
  }

  @Test func theExistingInitialiserSignatureIsUnchanged() throws {
    // The new parameter is trailing with a default, so every existing call site is unchanged.
    let report = try WatchPlayingReport(
      accountStamp: WatchProtocolFixtures.accountStamp(), selection: nil, playing: false, observedAt: now)
    #expect(report.nativeSelection == nil)
    #expect(try WatchWireCodec.encode(report).count <= WatchPlayingReport.maxWireBytes)
  }

  @Test func bothSelectionsAtOnceAreRefused() throws {
    #expect(throws: WatchHandoffError.invalidValue) {
      try WatchPlayingReport(
        accountStamp: WatchProtocolFixtures.accountStamp(),
        selection: WatchABSSelection(itemID: "book", episodeID: nil), playing: true, observedAt: now,
        nativeSelection: WatchNativeSelection(feedID: "feed", episodeID: "episode"))
    }
  }

  @Test func playingWithNeitherSelectionIsRefused() throws {
    #expect(throws: WatchHandoffError.invalidValue) {
      try WatchPlayingReport(
        accountStamp: WatchProtocolFixtures.accountStamp(), selection: nil, playing: true, observedAt: now)
    }
  }

  @Test func aMalformedNativeSelectionIsRefusedOnDecode() throws {
    let report = try WatchPlayingReport(
      accountStamp: WatchProtocolFixtures.accountStamp(), selection: nil, playing: true, observedAt: now,
      nativeSelection: WatchNativeSelection(feedID: "feed", episodeID: "episode"))
    var object = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(report)) as? [String: Any])
    var native = try #require(object["nativeSelection"] as? [String: Any])
    native["feedID"] = ""
    object["nativeSelection"] = native
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: WatchProtocolCodingError.invalidSelection) {
      try WatchWireCodec.decode(WatchPlayingReport.self, from: data)
    }
  }
}
