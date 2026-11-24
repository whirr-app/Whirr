import Foundation
import Testing

@testable import WatchProtocol

@Suite("WatchProtocol wire values")
struct WatchWireValueTests {
  private let account = WatchProtocolFixtures.accountStamp()

  @Test func playbackPreferencesSurviveWireRoundTrip() throws {
    // Construct the incoming phone payload independently of the Watch's memberwise API.
    let legacy = try WatchCatalogueSnapshot(accountStamp: account, items: [])
    var object = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(legacy)) as? [String: Any])
    object["skipBackwardSeconds"] = 15
    object["skipForwardSeconds"] = 45
    object["playbackRatePresets"] = [0.9, 1, 1.1, 1.35]
    let decoded = try WatchWireCodec.decode(
      WatchCatalogueSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
    let encoded = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(decoded)) as? [String: Any])
    #expect(encoded["skipBackwardSeconds"] as? Int == 15)
    #expect(encoded["skipForwardSeconds"] as? Int == 45)
    #expect(encoded["playbackRatePresets"] as? [Double] == [0.9, 1, 1.1, 1.35])
    let cache = try WatchCatalogueCache(expectedAccountStamp: account, snapshot: decoded)
    let restored = try WatchWireCodec.decode(WatchCatalogueCache.self, from: WatchWireCodec.encode(cache))
    #expect(restored.snapshot == decoded)
    #expect(legacy.skipBackwardSeconds == nil && legacy.skipForwardSeconds == nil && legacy.playbackRatePresets == nil)

    for (key, invalid) in [
      ("skipBackwardSeconds", 0 as Any), ("skipForwardSeconds", 999 as Any),
      ("playbackRatePresets", [] as [Double]), ("playbackRatePresets", [0.1, 5.0]),
      ("playbackRatePresets", Array(repeating: 1.0, count: 9)),
    ] {
      var malformed = object
      malformed[key] = invalid
      #expect(throws: WatchProtocolCodingError.invalidValue) {
        try WatchWireCodec.decode(
          WatchCatalogueSnapshot.self, from: JSONSerialization.data(withJSONObject: malformed))
      }
    }
  }

  @Test func followedPodcastsFlagRoundTripsAndStaysOptional() throws {
    for enabled in [true, false] {
      let snapshot = try WatchCatalogueSnapshot(accountStamp: account, items: [], followedPodcastsEnabled: enabled)
      let decoded = try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: WatchWireCodec.encode(snapshot))
      #expect(decoded.followedPodcastsEnabled == enabled)
      let cache = try WatchCatalogueCache(expectedAccountStamp: account, snapshot: decoded)
      let restored = try WatchWireCodec.decode(WatchCatalogueCache.self, from: WatchWireCodec.encode(cache))
      #expect(restored.snapshot?.followedPodcastsEnabled == enabled)
    }

    // An older phone does not send the flag.
    let legacy = try WatchCatalogueSnapshot(accountStamp: account, items: [])
    let object = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(legacy)) as? [String: Any])
    #expect(object["followedPodcastsEnabled"] == nil)
    #expect(legacy.followedPodcastsEnabled == nil)

    // The signed-out snapshot carries no account preferences.
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchCatalogueSnapshot(accountStamp: nil, items: [], followedPodcastsEnabled: true)
    }
  }

  /// The phone setting that removes a played copy from the Watch rides the catalogue the way
  /// the followed-podcasts flag does. nil from an older phone means on.
  @Test func removePlayedNativeEpisodesRoundTripsAndStaysOptional() throws {
    for enabled in [true, false] {
      let snapshot = try WatchCatalogueSnapshot(
        accountStamp: account, items: [], removePlayedNativeEpisodes: enabled)
      let decoded = try WatchWireCodec.decode(
        WatchCatalogueSnapshot.self, from: WatchWireCodec.encode(snapshot))
      #expect(decoded.removePlayedNativeEpisodes == enabled)
      let cache = try WatchCatalogueCache(expectedAccountStamp: account, snapshot: decoded)
      let restored = try WatchWireCodec.decode(WatchCatalogueCache.self, from: WatchWireCodec.encode(cache))
      #expect(restored.snapshot?.removePlayedNativeEpisodes == enabled)
    }

    // An older phone does not send the setting; the Watch treats nil as on.
    let legacy = try WatchCatalogueSnapshot(accountStamp: account, items: [])
    let object = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(legacy)) as? [String: Any])
    #expect(object["removePlayedNativeEpisodes"] == nil)
    #expect(legacy.removePlayedNativeEpisodes == nil)

    // The signed-out snapshot carries no account preferences.
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchCatalogueSnapshot(accountStamp: nil, items: [], removePlayedNativeEpisodes: false)
    }
  }

  @Test func catalogueArtworkRevisionRoundTripsAndStaysOptional() throws {
    let selection = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
    let capabilities = WatchSelectionCapabilities(phonePlayable: true, watchPlayable: true)
    let item = try WatchCatalogueItem(
      id: "row", selection: selection, title: "Gilead", capabilities: capabilities,
      artworkRevision: "1790000000123")
    let snapshot = try WatchCatalogueSnapshot(accountStamp: account, items: [item])
    let decoded = try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: WatchWireCodec.encode(snapshot))
    #expect(decoded.items.map(\.artworkRevision) == ["1790000000123"])

    // An older phone omits the field; the row still decodes, with no revision to learn.
    let legacy = try WatchCatalogueItem(id: "row", selection: selection, title: "Gilead", capabilities: capabilities)
    let legacyDecoded = try WatchWireCodec.decode(
      WatchCatalogueSnapshot.self,
      from: WatchWireCodec.encode(WatchCatalogueSnapshot(accountStamp: account, items: [legacy])))
    #expect(legacyDecoded.items.map(\.artworkRevision) == [nil])

    for invalid in ["", "https://server/cover", String(repeating: "1", count: 129)] {
      #expect(throws: WatchProtocolCodingError.invalidValue) {
        try WatchCatalogueItem(
          id: "row", selection: selection, title: "Gilead", capabilities: capabilities, artworkRevision: invalid)
      }
    }
  }

  /// The phone dates its own last listen to its current title; an older phone sends none.
  @Test func catalogueLastListenedRoundTripsAndStaysOptional() throws {
    let selection = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
    let capabilities = WatchSelectionCapabilities(phonePlayable: true, watchPlayable: true)
    let listened = Date(timeIntervalSince1970: 1_790_000_000.5)
    let item = try WatchCatalogueItem(
      id: "row", selection: selection, title: "Gilead", isCurrentPlayback: true, capabilities: capabilities,
      lastListenedAt: listened)
    let data = try WatchWireCodec.encode(WatchCatalogueSnapshot(accountStamp: account, items: [item]))
    let decoded = try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: data)
    #expect(decoded.items.map(\.lastListenedAt) == [listened])

    let legacy = try WatchCatalogueItem(id: "row", selection: selection, title: "Gilead", capabilities: capabilities)
    let legacyDecoded = try WatchWireCodec.decode(
      WatchCatalogueSnapshot.self,
      from: WatchWireCodec.encode(WatchCatalogueSnapshot(accountStamp: account, items: [legacy])))
    #expect(legacyDecoded.items.map(\.lastListenedAt) == [nil])
  }

  @Test func playbackRateRoundTripsAndLegacySnapshotsRemainUnknown() throws {
    let snapshot = try WatchCatalogueSnapshot(accountStamp: account, items: [], playbackRate: 1.35)
    let data = try WatchWireCodec.encode(snapshot)
    #expect(try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: data).playbackRate == 1.35)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "playbackRate")
    #expect(
      try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        .playbackRate == nil)
    for rate in [Double.nan, .infinity, 0, 0.24, 4.01] {
      #expect(throws: WatchProtocolCodingError.invalidValue) {
        try WatchCatalogueSnapshot(accountStamp: account, items: [], playbackRate: rate)
      }
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchCatalogueSnapshot(accountStamp: nil, items: [], playbackRate: 1)
    }
  }

  @Test func authenticatedStampPreservesExistingHashes() throws {
    #if canImport(CryptoKit)
      let stamp = try WatchAccountStamp.authenticated(serverIdentity: "https://example.com", userID: "user-123")
      #expect(stamp.accountIdentityHash == "2d0c9797a13293b0c2c8cc9e8b539631d1d30f3dea24482f396e38a926c9d755")
      #expect(stamp.serverIdentityHash == "100680ad546ce6a577f42f52df33b4cfdca756859e664b8d7de329b150d09ce9")
    #else
      #expect(throws: WatchProtocolCodingError.cryptographyUnavailable) {
        try WatchAccountStamp.authenticated(serverIdentity: "https://example.com", userID: "user-123")
      }
    #endif
  }

  @Test func bothSourcesRoundTrip() throws {
    let values: [WatchSelection] = [
      WatchProtocolFixtures.absSelection().watchSelection,
      WatchProtocolFixtures.nativeSelection(),
    ]
    for selection in values {
      let command = try WatchCommand(id: UUID(), accountStamp: account, selection: selection)
      #expect(try WatchProtocolFixtures.roundTrip(command) == command)
    }
  }

  @Test func versionIsRejectedDuringDecode() throws {
    let command = try WatchCommand(accountStamp: account, selection: .nativeFeed(feedID: "f", episodeID: "e"))
    var object = try #require(JSONSerialization.jsonObject(with: WatchWireCodec.encode(command)) as? [String: Any])
    object["version"] = 99
    let bytes = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: WatchProtocolCodingError.unsupportedVersion(99)) {
      try WatchWireCodec.decode(WatchCommand.self, from: bytes)
    }
  }

  @Test func snapshotIsBoundedAndContainsNoURLFields() throws {
    let snapshot = try WatchProtocolFixtures.snapshot(account: account)
    let data = try WatchWireCodec.encode(snapshot)
    #expect(try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: data) == snapshot)
    #expect(!String(decoding: data, as: UTF8.self).contains("http"))
  }

  @Test func oversizedMetadataAndRowsFailClosed() throws {
    #expect(throws: WatchProtocolCodingError.oversizedMetadata) {
      try WatchCatalogueItem(
        id: "x", selection: .nativeFeed(feedID: "f", episodeID: "e"),
        title: String(repeating: "x", count: WatchProtocolVersion.maxMetadataStringBytes + 1),
        capabilities: WatchSelectionCapabilities(phonePlayable: true, watchPlayable: false))
    }
    let items = try (0..<WatchProtocolVersion.maxRows + 1).map { index in
      try WatchCatalogueItem(
        id: "\(index)", selection: .audiobookshelf(itemID: "\(index)", episodeID: nil), title: "\(index)",
        capabilities: WatchSelectionCapabilities(phonePlayable: true, watchPlayable: false))
    }
    #expect(throws: WatchProtocolCodingError.tooManyRows) {
      try WatchCatalogueSnapshot(accountStamp: account, items: items)
    }
  }

  @Test func acceptedReplyMeansAdmissionOnly() throws {
    let command = try WatchCommand(accountStamp: account, selection: .audiobookshelf(itemID: "book", episodeID: nil))
    let reply = WatchReply.accepted(commandID: command.id)
    #expect(reply.status == .accepted)
    #expect(reply.errorCode == nil)
    #expect(reply.matches(command))
  }

  @Test func controlCommandsCarryOnlyTheValuesThatNeedValues() throws {
    let selection = WatchSelection.audiobookshelf(itemID: "book", episodeID: nil)
    for action in [WatchCommandAction.play, .pause, .resume] {
      let command = try WatchCommand(accountStamp: account, selection: selection, action: action)
      #expect(command.value == nil)
      #expect(try WatchProtocolFixtures.roundTrip(command) == command)
    }
    let seek = try WatchCommand(accountStamp: account, selection: selection, action: .seek, value: 42)
    let skipForward = try WatchCommand(
      accountStamp: account, selection: selection, action: .skip, value: 30)
    let skipBack = try WatchCommand(
      accountStamp: account, selection: selection, action: .skip, value: -30)
    let rate = try WatchCommand(accountStamp: account, selection: selection, action: .setRate, value: 1.5)
    #expect(seek.value == 42)
    #expect(try WatchProtocolFixtures.roundTrip(skipForward) == skipForward)
    #expect(try WatchProtocolFixtures.roundTrip(skipBack) == skipBack)
    #expect(rate.value == 1.5)
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchCommand(accountStamp: account, selection: selection, action: .pause, value: 1)
    }
    // Continue on iPhone hands over where the Watch paused; a play needs no position.
    let handover = try WatchCommand(accountStamp: account, selection: selection, action: .play, value: 61.5)
    #expect(try WatchProtocolFixtures.roundTrip(handover) == handover)
    #expect(try WatchCommand(accountStamp: account, selection: selection, action: .play).value == nil)
    for invalid in [-1, Double.nan, .infinity] {
      #expect(throws: WatchProtocolCodingError.invalidValue) {
        try WatchCommand(accountStamp: account, selection: selection, action: .play, value: invalid)
      }
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchCommand(accountStamp: account, selection: selection, action: .setRate, value: 10)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchCommand(accountStamp: account, selection: selection, action: .skip, value: 0)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchCommand(accountStamp: account, selection: selection, action: .skip, value: 301)
    }
  }

  @Test func invalidIDsDatesAndNativeWatchCapabilitiesFailClosed() throws {
    #expect(throws: WatchProtocolCodingError.invalidSelection) {
      let selection = WatchSelection.nativeFeed(feedID: "/tmp/feed", episodeID: "episode")
      _ = try JSONEncoder().encode(selection)
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchCatalogueItem(
        id: "episode", selection: .nativeFeed(feedID: "feed", episodeID: "episode"), title: "Episode",
        capabilities: WatchSelectionCapabilities(phonePlayable: true, watchPlayable: true))
    }
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchCommand(
        accountStamp: account, selection: .audiobookshelf(itemID: "book", episodeID: nil),
        issuedAt: Date(timeIntervalSinceReferenceDate: .nan))
    }
  }

  @Test func controlCharactersAreRejectedFromIdentitySelectionAndMetadataWire() throws {
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try WatchAccountStamp(accountIdentityHash: "account\rhash", serverIdentityHash: "server-hash")
    }

    let command = try WatchCommand(
      accountStamp: account, selection: .nativeFeed(feedID: "feed", episodeID: "episode"))
    var commandObject = try #require(
      JSONSerialization.jsonObject(with: WatchWireCodec.encode(command)) as? [String: Any])
    var selectionObject = try #require(commandObject["selection"] as? [String: Any])
    selectionObject["episodeID"] = "episode\rX"
    commandObject["selection"] = selectionObject
    let commandData = try JSONSerialization.data(withJSONObject: commandObject)
    #expect(throws: WatchProtocolCodingError.invalidSelection) {
      try WatchWireCodec.decode(WatchCommand.self, from: commandData)
    }

    let item = try WatchCatalogueItem(
      id: "book", selection: .audiobookshelf(itemID: "book", episodeID: nil), title: "Book",
      capabilities: WatchSelectionCapabilities(phonePlayable: true, watchPlayable: false))
    var itemObject = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
    itemObject["title"] = "Book\rX"
    let itemData = try JSONSerialization.data(withJSONObject: itemObject)
    #expect(throws: WatchProtocolCodingError.invalidValue) {
      try JSONDecoder().decode(WatchCatalogueItem.self, from: itemData)
    }
  }
}
