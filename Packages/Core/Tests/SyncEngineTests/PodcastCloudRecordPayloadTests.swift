import Foundation
import Testing

@testable import SyncEngine

/// The outbox payload is a durability contract: a row written by one build is decoded by the next,
/// so these tests pin the format's behaviour, not just its round trip.
@Suite struct PodcastCloudRecordPayloadTests {
  private func stamp(_ physical: Int64, _ logical: Int64 = 0) throws -> PodcastCloudMutationStamp {
    try PodcastCloudMutationStamp(
      physicalMilliseconds: physical, logicalCounter: logical,
      installationUUID: UUID(uuidString: "00000000-0000-4000-8000-00000000000a")!,
      mutationUUID: UUID(uuidString: "00000000-0000-4000-8000-00000000000b")!)
  }

  private func savedRecord(isSaved: Bool, savedAt: Date?) throws -> PodcastCloudRecordFields {
    try PodcastCloudRecordCodec.encode(
      savedRegister: PodcastCloudSavedRegister(
        isSaved: isSaved, savedAt: savedAt, stamp: try stamp(1_700_000_000_123, 4)),
      identity: PodcastCloudEpisodeIdentityFields(
        identityKey: "key", alternateIdentityKey: nil, guid: "guid", enclosureURL: nil,
        aliases: ["a", "b"]),
      recordName: "v1.saved.\(String(repeating: "0", count: 8))-0000-8000-8000-000000000000."
        + String(repeating: "ab", count: 32))
  }

  // MARK: - Round trip

  @Test func aSavedRemovalRecordSurvivesTheRoundTripAsTheSameValue() throws {
    let original = try savedRecord(isSaved: false, savedAt: nil)

    let decoded = try PodcastCloudRecordPayload.decode(
      try PodcastCloudRecordPayload.encode(original))

    #expect(decoded == original)
    // And still decodes as the register it was, which is what the send path will do with it.
    let register = try PodcastCloudRecordCodec.decodeSavedRegister(decoded)
    #expect(register.isSaved == false)
    #expect(register.savedAt == nil)
    #expect(register.stamp == (try stamp(1_700_000_000_123, 4)))
  }

  @Test func theCompartmentSplitSurvivesTheRoundTrip() throws {
    let original = try savedRecord(isSaved: true, savedAt: Date(timeIntervalSince1970: 1_000))

    let decoded = try PodcastCloudRecordPayload.decode(
      try PodcastCloudRecordPayload.encode(original))

    #expect(Set(decoded.plaintext.keys) == [PodcastCloudRecordLayout.schemaFieldName])
    #expect(decoded.encrypted["isSaved"] == .boolean(true))
    #expect(decoded.encrypted["savedAt"] == .date(Date(timeIntervalSince1970: 1_000)))
  }

  /// Every kind the layout declares, because a kind added to `ValueKind` and forgotten in the
  /// tagged representation would be a payload that cannot be read back.
  @Test(arguments: [
    PodcastCloudRecordValue.string("text"),
    .string(""),
    .integer(0),
    .integer(Int64.max),
    .integer(Int64.min),
    .boolean(true),
    .boolean(false),
    .double(0.1),
    .double(-0.0),
    .double(Double.leastNonzeroMagnitude),
    .double(Double.greatestFiniteMagnitude),
    .date(Date(timeIntervalSince1970: 0)),
    .date(Date(timeIntervalSince1970: 1_700_000_000.75)),
    .data(Data()),
    .data(Data([0x00, 0xff, 0x7f])),
    .stringList([]),
    .stringList(["", "b"]),
  ])
  func everyValueKindRoundTripsExactly(value: PodcastCloudRecordValue) throws {
    // Carried in a real field of a record type that declares that kind, so validation accepts it.
    let (type, fieldName) = try Self.carrier(for: value.kind)
    let original = PodcastCloudRecordFields(
      recordType: type.name, recordName: "v1.globals",
      plaintext: [PodcastCloudRecordLayout.schemaFieldName: .integer(1)],
      encrypted: [fieldName: value])

    let decoded = try PodcastCloudRecordPayload.decode(
      try PodcastCloudRecordPayload.encode(original))

    #expect(decoded.encrypted[fieldName] == value)
  }

  /// The first encrypted field of that kind anywhere in the inventory, with its owning record
  /// type. Searching the table rather than hardcoding pairs means a kind that loses its last
  /// field fails here instead of quietly going untested.
  private static func carrier(for kind: PodcastCloudRecordLayout.ValueKind) throws -> (
    PodcastCloudRecordLayout.RecordType, String
  ) {
    for type in PodcastCloudRecordLayout.allRecordTypes {
      if let field = type.fields.first(where: { $0.kind == kind && $0.isEncrypted }) {
        return (type, field.name)
      }
    }
    throw PodcastCloudRecordPayload.PayloadError.unknownValueKind(kind.rawValue)
  }

  // MARK: - Determinism

  @Test func encodingTheSameFieldsTwiceProducesTheSameBytes() throws {
    let fields = try savedRecord(isSaved: false, savedAt: nil)

    #expect(
      try PodcastCloudRecordPayload.encode(fields)
        == (try PodcastCloudRecordPayload.encode(fields)))
  }

  /// Dictionaries have no order, so without sorted keys two encodes of equal values could differ
  /// and a caller comparing payloads would see a change that did not happen.
  @Test func twoEqualRecordsBuiltSeparatelyEncodeIdentically() throws {
    #expect(
      try PodcastCloudRecordPayload.encode(try savedRecord(isSaved: false, savedAt: nil))
        == (try PodcastCloudRecordPayload.encode(try savedRecord(isSaved: false, savedAt: nil))))
  }

  @Test func aRealisticRecordFitsTheOutboxPayloadCeiling() throws {
    let payload = try PodcastCloudRecordPayload.encode(
      try savedRecord(isSaved: true, savedAt: Date(timeIntervalSince1970: 1_700_000_000)))

    #expect(payload.count <= 65_536)
  }

  // MARK: - Refusals

  @Test func anUnsupportedVersionIsRefusedRatherThanReadAsBestEffort() throws {
    let payload = try PodcastCloudRecordPayload.encode(
      try savedRecord(isSaved: false, savedAt: nil))
    let bumped = try Self.rewritingVersion(payload, to: PodcastCloudRecordPayload.version + 1)

    #expect(throws: PodcastCloudRecordPayload.PayloadError.unsupportedVersion(2)) {
      try PodcastCloudRecordPayload.decode(bumped)
    }
  }

  @Test func anUnknownRecordTypeIsRefused() throws {
    let fields = PodcastCloudRecordFields(
      recordType: "PodcastSomethingElse", recordName: "v1.globals", plaintext: [:], encrypted: [:])

    #expect(throws: PodcastCloudRecordPayload.PayloadError.unknownRecordType("PodcastSomethingElse")) {
      try PodcastCloudRecordPayload.decode(try PodcastCloudRecordPayload.encode(fields))
    }
  }

  @Test func anUnknownValueKindIsRefused() throws {
    let payload = Data(
      """
      {"encrypted":{},"plaintext":{"schema":{"kind":"quaternion","value":1}},\
      "recordName":"v1.globals","recordType":"PodcastGlobalSettings","version":1}
      """.utf8)

    #expect(throws: PodcastCloudRecordPayload.PayloadError.unknownValueKind("quaternion")) {
      try PodcastCloudRecordPayload.decode(payload)
    }
  }

  /// The check that matters most: an encrypted field sitting in `plaintext` must not come back,
  /// because the App adapter would write exactly what it is handed.
  @Test func anEncryptedFieldArrivingInTheClearIsRefused() throws {
    let smuggled = PodcastCloudRecordFields(
      recordType: PodcastCloudRecordLayout.savedEpisode.name, recordName: "v1.globals",
      plaintext: [
        PodcastCloudRecordLayout.schemaFieldName: .integer(1), "identityKey": .string("secret"),
      ],
      encrypted: [:])

    #expect(
      throws: PodcastCloudRecordPayload.PayloadError.wrongCompartment(
        field: "identityKey", encryptedInLayout: true)
    ) {
      try PodcastCloudRecordPayload.decode(try PodcastCloudRecordPayload.encode(smuggled))
    }
  }

  @Test func theSchemaMarkerArrivingEncryptedIsRefused() throws {
    let misplaced = PodcastCloudRecordFields(
      recordType: PodcastCloudRecordLayout.savedEpisode.name, recordName: "v1.globals",
      plaintext: [:], encrypted: [PodcastCloudRecordLayout.schemaFieldName: .integer(1)])

    #expect(
      throws: PodcastCloudRecordPayload.PayloadError.wrongCompartment(
        field: PodcastCloudRecordLayout.schemaFieldName, encryptedInLayout: false)
    ) {
      try PodcastCloudRecordPayload.decode(try PodcastCloudRecordPayload.encode(misplaced))
    }
  }

  @Test func aFieldTheRecordTypeDoesNotDeclareIsRefused() throws {
    let fields = PodcastCloudRecordFields(
      recordType: PodcastCloudRecordLayout.savedEpisode.name, recordName: "v1.globals",
      plaintext: [PodcastCloudRecordLayout.schemaFieldName: .integer(1)],
      encrypted: ["inventedField": .string("x")])

    #expect(throws: PodcastCloudRecordMappingError.undeclaredField("inventedField")) {
      try PodcastCloudRecordPayload.decode(try PodcastCloudRecordPayload.encode(fields))
    }
  }

  @Test func aValueWhoseKindContradictsTheLayoutIsRefused() throws {
    let fields = PodcastCloudRecordFields(
      recordType: PodcastCloudRecordLayout.savedEpisode.name, recordName: "v1.globals",
      plaintext: [PodcastCloudRecordLayout.schemaFieldName: .integer(1)],
      encrypted: ["isSaved": .string("true")])

    #expect(
      throws: PodcastCloudRecordMappingError.kindMismatch(field: "isSaved", expected: .boolean)
    ) {
      try PodcastCloudRecordPayload.decode(try PodcastCloudRecordPayload.encode(fields))
    }
  }

  @Test(arguments: [Data(), Data("not json".utf8), Data([0x00, 0x01])])
  func malformedBytesAreRefused(payload: Data) throws {
    #expect(throws: PodcastCloudRecordPayload.PayloadError.malformed) {
      try PodcastCloudRecordPayload.decode(payload)
    }
  }

  /// Rewrites only the envelope's version, leaving the rest of the payload as encoded.
  private static func rewritingVersion(_ payload: Data, to version: Int) throws -> Data {
    guard var object = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
      throw PodcastCloudRecordPayload.PayloadError.malformed
    }
    object["version"] = version
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}
