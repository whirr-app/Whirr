import Foundation
import Testing

@testable import SyncEngine

@Suite struct PodcastCloudRecordCodecTests {
  private func stamp(_ physical: Int64, _ logical: Int64 = 0) throws -> PodcastCloudMutationStamp {
    try PodcastCloudMutationStamp(
      physicalMilliseconds: physical, logicalCounter: logical,
      installationUUID: UUID(uuidString: "00000000-0000-4000-8000-00000000000a")!,
      mutationUUID: UUID(uuidString: "00000000-0000-4000-8000-00000000000b")!)
  }

  // MARK: - The encryption rule, enforced structurally

  @Test func everyFieldOfEveryRecordTypeIsEncryptedExceptTheSchemaMarker() throws {
    for type in PodcastCloudRecordLayout.allRecordTypes {
      #expect(
        type.plaintextFieldNames == [PodcastCloudRecordLayout.schemaFieldName],
        "\(type.name) declares a plaintext field other than the schema marker")
    }
  }

  @Test func abuiltRecordPutsNothingButTheSchemaMarkerInTheClear() throws {
    let fields = try PodcastCloudRecordCodec.encode(
      globalSettings: StampedGlobalSettings(
        autoDownloadEnabled: true, keepLatestCount: 5, deleteAfterPlayed: false,
        allowCellularAutoDownload: true, enabledAt: Date(timeIntervalSince1970: 10),
        showOrderMode: "alphabetical", writeStamp: try stamp(1_000)),
      recordName: "v1.globals")

    #expect(Set(fields.plaintext.keys) == [PodcastCloudRecordLayout.schemaFieldName])
    #expect(fields.encrypted.isEmpty == false)
    #expect(fields.encrypted["showOrderMode"] == .string("alphabetical"))
    #expect(fields.plaintext[PodcastCloudRecordLayout.schemaFieldName] == .integer(1))
  }

  @Test func theBuilderRefusesAFieldTheLayoutDoesNotDeclare() throws {
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.globalSettings, recordName: "v1.globals")
    #expect(throws: PodcastCloudRecordMappingError.undeclaredField("feedURL")) {
      try builder.set("feedURL", .string("https://example.com/feed"))
    }
  }

  @Test func theBuilderRefusesAValueOfTheWrongKind() throws {
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.globalSettings, recordName: "v1.globals")
    #expect(
      throws: PodcastCloudRecordMappingError.kindMismatch(field: "keepLatestCount", expected: .integer)
    ) {
      try builder.set("keepLatestCount", .string("5"))
    }
  }

  @Test func theBuilderRefusesANonFiniteDouble() throws {
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.episodeState, recordName: "v1.state.a")
    #expect(throws: PodcastCloudRecordMappingError.nonFiniteValue("position")) {
      try builder.set("position", .double(.infinity))
    }
  }

  @Test func aReaderWillNotAcceptAnEncryptedFieldDeliveredInTheClear() throws {
    // A writer that placed `showOrderMode` in the plaintext compartment must not be readable as if
    // it had been encrypted: that is the shape a downgrade would take.
    let smuggled = PodcastCloudRecordFields(
      recordType: PodcastCloudRecordLayout.globalSettings.name, recordName: "v1.globals",
      plaintext: [
        PodcastCloudRecordLayout.schemaFieldName: .integer(1), "showOrderMode": .string("alphabetical"),
      ],
      encrypted: [:])
    let reader = PodcastCloudRecordReader(
      type: PodcastCloudRecordLayout.globalSettings, fields: smuggled)
    #expect(try reader.value("showOrderMode") == nil)
  }

  @Test func aReaderRejectsAnUnknownSchemaVersion() throws {
    let future = PodcastCloudRecordFields(
      recordType: PodcastCloudRecordLayout.globalSettings.name, recordName: "v1.globals",
      plaintext: [PodcastCloudRecordLayout.schemaFieldName: .integer(99)], encrypted: [:])
    let reader = PodcastCloudRecordReader(
      type: PodcastCloudRecordLayout.globalSettings, fields: future)
    #expect(throws: PodcastCloudRecordMappingError.schemaMismatch(99)) { try reader.validateSchema() }
  }

  // MARK: - Round trips

  @Test func globalSettingsRoundTripsIncludingAnAbsentOptional() throws {
    for enabledAt in [Date(timeIntervalSince1970: 1_234), nil] {
      let original = StampedGlobalSettings(
        autoDownloadEnabled: false, keepLatestCount: 3, deleteAfterPlayed: true,
        allowCellularAutoDownload: false, enabledAt: enabledAt, showOrderMode: "mostRecent",
        writeStamp: try stamp(2_000, 4))
      let decoded = try PodcastCloudRecordCodec.decodeGlobalSettings(
        try PodcastCloudRecordCodec.encode(globalSettings: original, recordName: "v1.globals"))
      #expect(decoded == original)
    }
  }

  @Test func subscriptionRoundTripsWithAndWithoutItsCustomOrderRegister() throws {
    let subscriptionUUID = UUID(uuidString: "00000000-0000-8000-8000-00000000000c")!
    let lifecycle = PodcastCloudFollowRegister(
      subscriptionUUID: subscriptionUUID,
      generationUUID: UUID(uuidString: "00000000-0000-4000-8000-00000000000d")!, isFollowed: true,
      stamp: try stamp(3_000))

    for customOrder in [StampedCustomOrder(value: 7, stamp: try stamp(3_500)), nil] {
      let original = SubscriptionSnapshot(
        subscriptionUUID: subscriptionUUID, canonicalizationVersion: 1,
        normalizedURL: "https://example.com/feed", title: "A Show", author: "An Author",
        subscribedAt: Date(timeIntervalSince1970: 99), lifecycle: lifecycle, customOrder: customOrder)
      let decoded = try PodcastCloudRecordCodec.decodeSubscription(
        try PodcastCloudRecordCodec.encode(subscription: original, recordName: "v1.sub.x"),
        subscriptionUUID: subscriptionUUID)
      #expect(decoded.normalizedURL == original.normalizedURL)
      #expect(decoded.title == original.title)
      #expect(decoded.author == original.author)
      #expect(decoded.lifecycle == original.lifecycle)
      #expect(decoded.customOrder == original.customOrder)
    }
  }

  @Test func aRetiredSubscriptionSurvivesTheRoundTripAsContentRatherThanAbsence() throws {
    let subscriptionUUID = UUID(uuidString: "00000000-0000-8000-8000-00000000000c")!
    let retired = SubscriptionSnapshot(
      subscriptionUUID: subscriptionUUID, normalizedURL: "https://example.com/feed", title: "A Show",
      lifecycle: PodcastCloudFollowRegister(
        subscriptionUUID: subscriptionUUID,
        generationUUID: UUID(uuidString: "00000000-0000-4000-8000-00000000000d")!, isFollowed: false,
        stamp: try stamp(4_000)))
    let decoded = try PodcastCloudRecordCodec.decodeSubscription(
      try PodcastCloudRecordCodec.encode(subscription: retired, recordName: "v1.sub.x"),
      subscriptionUUID: subscriptionUUID)
    #expect(decoded.lifecycle.isFollowed == false)
    #expect(decoded.lifecycle.generationUUID == retired.lifecycle.generationUUID)
  }

  @Test func feedSettingsRoundTripsWithItsOptionalsAbsent() throws {
    let original = FeedSettingsSnapshot(
      autoDownload: "inherit", keepLatest: nil, deleteAfterPlayed: nil, rateStep: nil,
      includeInLatest: true, notificationOverride: "off", stamp: try stamp(5_000))
    let decoded = try PodcastCloudRecordCodec.decodeFeedSettings(
      try PodcastCloudRecordCodec.encode(feedSettings: original, recordName: "v1.settings.x.y"))
    #expect(decoded == original)
  }

  @Test func feedSettingsCarryTheTrimSilencesAndVoiceBoostOverrides() throws {
    let original = FeedSettingsSnapshot(
      autoDownload: "inherit", keepLatest: nil, deleteAfterPlayed: nil, rateStep: nil, includeInLatest: true,
      notificationOverride: "inherit", trimSilencesOverride: "inherit", voiceBoostOverride: "on",
      stamp: try stamp(5_000))
    let decoded = try PodcastCloudRecordCodec.decodeFeedSettings(
      try PodcastCloudRecordCodec.encode(feedSettings: original, recordName: "v1.settings.x.y"))
    #expect(decoded == original)
  }

  /// A record from a build before Trim Silences has no such fields; a newer build's value this
  /// build does not know reads the same way, so neither can overwrite the local setting.
  @Test func feedSettingsWithoutOrWithUnknownOverridesReadAsAbsent() throws {
    let older = FeedSettingsSnapshot(
      autoDownload: "inherit", keepLatest: 3, deleteAfterPlayed: nil, rateStep: nil, includeInLatest: true,
      notificationOverride: "inherit", stamp: try stamp(5_000))
    let fields = try PodcastCloudRecordCodec.encode(feedSettings: older, recordName: "v1.settings.x.y")
    #expect(fields.encrypted["trimSilencesOverride"] == nil && fields.encrypted["voiceBoostOverride"] == nil)
    let decoded = try PodcastCloudRecordCodec.decodeFeedSettings(fields)
    #expect(decoded.trimSilencesOverride == nil && decoded.voiceBoostOverride == nil)

    var encrypted = fields.encrypted
    encrypted["trimSilencesOverride"] = .string("gentle")
    encrypted["voiceBoostOverride"] = .string("strong")
    let future = PodcastCloudRecordFields(
      recordType: fields.recordType, recordName: fields.recordName, plaintext: fields.plaintext,
      encrypted: encrypted)
    let read = try PodcastCloudRecordCodec.decodeFeedSettings(future)
    #expect(read.trimSilencesOverride == nil && read.voiceBoostOverride == nil)
    #expect(read.keepLatest == 3)
  }

  @Test func episodeStateRoundTripsWithItsIdentityEvidence() throws {
    let identity = PodcastCloudEpisodeIdentityFields(
      identityKey: "key-a", alternateIdentityKey: "key-b", guid: "guid-1",
      enclosureURL: "https://example.com/ep.mp3", aliases: ["key-a", "key-b"], title: "Episode One",
      publishedAt: Date(timeIntervalSince1970: 500), duration: 1_800.5,
      updatedAt: Date(timeIntervalSince1970: 600))
    let state = try PodcastCloudEpisodeState(
      position: 123.25, isFinished: false, isDismissed: false, explicitEpoch: try stamp(6_000),
      writeStamp: try stamp(6_500))

    let decoded = try PodcastCloudRecordCodec.decodeEpisodeState(
      try PodcastCloudRecordCodec.encode(
        episodeState: state, identity: identity, recordName: "v1.state.x.y.z"))
    #expect(decoded.state == state)
    #expect(decoded.identity == identity)
  }

  @Test func anExplicitZeroPositionSurvivesAsAPresentValue() throws {
    // Absence and an explicit zero are different intents in this schema: a zero must not decode as
    // "no state".
    let state = try PodcastCloudEpisodeState(
      position: 0, isFinished: false, isDismissed: false, writeStamp: try stamp(7_000))
    let decoded = try PodcastCloudRecordCodec.decodeEpisodeState(
      try PodcastCloudRecordCodec.encode(
        episodeState: state, identity: PodcastCloudEpisodeIdentityFields(identityKey: "key-a"),
        recordName: "v1.state.x.y.z"))
    #expect(decoded.state.position == 0)
    #expect(decoded.state == state)
  }

  @Test func theSavedRegisterRoundTripsBothWaysIncludingItsRemovalMarker() throws {
    let identity = PodcastCloudEpisodeIdentityFields(identityKey: "key-a")
    for original in [
      try PodcastCloudSavedRegister(
        isSaved: true, savedAt: Date(timeIntervalSince1970: 800), stamp: try stamp(8_000)),
      try PodcastCloudSavedRegister(isSaved: false, savedAt: nil, stamp: try stamp(8_500)),
    ] {
      let decoded = try PodcastCloudRecordCodec.decodeSavedRegister(
        try PodcastCloudRecordCodec.encode(
          savedRegister: original, identity: identity, recordName: "v1.saved.x.y.z"))
      #expect(decoded == original)
    }
  }

  @Test func aSavedRecordWhoseFieldsContradictEachOtherIsRefusedOnDecode() throws {
    // `isSaved == (savedAt != nil)` is the register's invariant. A remote writer that breaks it
    // (an older build, or a record edited outside the app) must fail the decode rather than
    // produce a register the domain type would never allow locally.
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.savedEpisode, recordName: "v1.saved.a")
    try builder.set("identityKey", .string("key-a"))
    try builder.set("isSaved", .boolean(true))
    try builder.set(stamp: try stamp(9_000), prefix: "saved")

    #expect(throws: PodcastCloudSavedRegister.ValidationError.inconsistentValue) {
      try PodcastCloudRecordCodec.decodeSavedRegister(try builder.build())
    }
  }

  @Test func theKeyringRoundTripsItsKeyAndCarriesNoStamp() throws {
    let key = Data(repeating: 7, count: 32)
    let fields = try PodcastCloudRecordCodec.encodeKeyring(recordNameKey: key)
    #expect(fields.recordName == PodcastCloudIdentity.keyringRecordName)
    #expect(Set(fields.plaintext.keys) == [PodcastCloudRecordLayout.schemaFieldName])
    #expect(try PodcastCloudRecordCodec.decodeKeyring(fields) == key)
  }

  @Test func everyEncodedRecordUsesOnlyFieldsItsLayoutDeclares() throws {
    let identity = PodcastCloudEpisodeIdentityFields(identityKey: "key-a")
    let encoded: [(PodcastCloudRecordLayout.RecordType, PodcastCloudRecordFields)] = [
      (
        PodcastCloudRecordLayout.globalSettings,
        try PodcastCloudRecordCodec.encode(
          globalSettings: StampedGlobalSettings(
            autoDownloadEnabled: true, keepLatestCount: 1, deleteAfterPlayed: true,
            allowCellularAutoDownload: true, showOrderMode: "custom", writeStamp: try stamp(1)),
          recordName: "v1.globals")
      ),
      (
        PodcastCloudRecordLayout.savedEpisode,
        try PodcastCloudRecordCodec.encode(
          savedRegister: try PodcastCloudSavedRegister(
            isSaved: true, savedAt: Date(timeIntervalSince1970: 2), stamp: try stamp(2)),
          identity: identity, recordName: "v1.saved.a")
      ),
      (PodcastCloudRecordLayout.keyring, try PodcastCloudRecordCodec.encodeKeyring(recordNameKey: Data([1]))),
    ]
    for (type, fields) in encoded {
      let declared = Set(type.fields.map(\.name))
      #expect(Set(fields.plaintext.keys).subtracting(declared).isEmpty)
      #expect(Set(fields.encrypted.keys).subtracting(declared).isEmpty)
      #expect(fields.recordType == type.name)
    }
  }
}
