import Foundation
import Testing

@testable import WidgetProtocol

@Suite struct WidgetSnapshotCodecTests {

  @Test func everyShapeRoundTrips() throws {
    let stamp = try WidgetFixtures.stamp()
    let item = try WidgetFixtures.item()
    let snapshots = try [
      WidgetSnapshot.signedOut(generatedAt: WidgetFixtures.generatedAt),
      WidgetSnapshot(generatedAt: WidgetFixtures.generatedAt, accountStamp: stamp, skipBackSeconds: 15),
      WidgetSnapshot(
        generatedAt: WidgetFixtures.generatedAt, accountStamp: stamp,
        nowPlaying: WidgetNowPlaying(token: item.token, isPlaying: true), skipBackSeconds: 30,
        continueListening: [item],
        latestEpisodes: [WidgetFixtures.item(token: "e1", kind: .feedEpisode, chapterNumber: nil)],
        stats: WidgetFixtures.stats()),
      WidgetFixtures.largest(),
    ]
    for snapshot in snapshots {
      #expect(try WidgetSnapshotCodec.decode(WidgetSnapshotCodec.encode(snapshot)) == snapshot)
    }
  }

  /// The publisher skips a write and a timeline reload when the bytes are unchanged, so equal
  /// snapshots must encode to equal bytes.
  @Test func equalSnapshotsEncodeToIdenticalBytes() throws {
    let first = try WidgetSnapshotCodec.encode(WidgetFixtures.largest())
    let second = try WidgetSnapshotCodec.encode(WidgetFixtures.largest())
    #expect(first == second)
  }

  /// The bound is a backstop against a file that is not a snapshot, so the largest valid
  /// snapshot must fit with room to spare.
  @Test func largestValidSnapshotFitsWellInsideTheBound() throws {
    let bytes = try WidgetSnapshotCodec.encode(WidgetFixtures.largest()).count
    #expect(bytes < WidgetSnapshotLimits.maxEncodedBytes / 2, "largest valid snapshot is \(bytes) bytes")
  }

  @Test func oversizedInputIsRefusedBeforeDecoding() {
    let data = Data(repeating: UInt8(ascii: " "), count: WidgetSnapshotLimits.maxEncodedBytes + 1)
    #expect(throws: WidgetProtocolError.tooLarge) { try WidgetSnapshotCodec.decode(data) }
  }

  /// A file left by a newer or older build draws the placeholder rather than a misread.
  @Test func otherSchemaVersionsAreRefusedByNumber() throws {
    var object = try #require(
      JSONSerialization.jsonObject(with: WidgetSnapshotCodec.encode(WidgetFixtures.largest()))
        as? [String: Any])
    object["schemaVersion"] = 2
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: WidgetProtocolError.unsupportedVersion(2)) { try WidgetSnapshotCodec.decode(data) }
  }

  /// Validation runs after decoding as well as on construction: a hand-edited or corrupted file
  /// that parses is still refused.
  @Test func decodingValidatesEveryNestedValue() throws {
    let encoded = try WidgetSnapshotCodec.encode(WidgetFixtures.largest())
    let text = try #require(String(data: encoded, encoding: .utf8))
    let tampered = [
      text.replacingOccurrences(of: "\"skipBackSeconds\":90", with: "\"skipBackSeconds\":20"),
      text.replacingOccurrences(of: "\"progressFraction\":0.42", with: "\"progressFraction\":4.2"),
      text.replacingOccurrences(of: ".jpg\"", with: ".png\""),
      text.replacingOccurrences(of: WidgetFixtures.accountHash, with: "someone"),
    ]
    for variant in tampered {
      #expect(variant != text)
      #expect(throws: (any Error).self) { try WidgetSnapshotCodec.decode(Data(variant.utf8)) }
    }
  }

  @Test func encodingRevalidates() throws {
    // `signedOut` skips the throwing initializer, so the encoder is where its date is checked.
    let snapshot = WidgetSnapshot.signedOut(generatedAt: Date(timeIntervalSinceReferenceDate: .nan))
    #expect(throws: WidgetProtocolError.invalidValue) { try WidgetSnapshotCodec.encode(snapshot) }
  }
}
