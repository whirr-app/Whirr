import Foundation
import Persistence
import Testing

@testable import SyncEngine

@Suite struct PodcastStateSnapshotCodecTests {
  @Test func completeSparseStateAndWrapperRoundTrip() throws {
    let source = try fixture()
    let wrapped = try PodcastStateSnapshotCodec.encodeWrapped(source)
    let decoded = try PodcastStateSnapshotCodec.decodeWrapped(wrapped)
    #expect(try PodcastStateSnapshotCodec.encode(decoded) == PodcastStateSnapshotCodec.encode(source))
    #expect(decoded.globalSettings.enabledAt == Date(timeIntervalSince1970: 50))
    #expect(decoded.lastPlayed != nil)
    #expect(decoded.lastPlayed?.reference == nil)
    #expect(decoded.episodes.contains { $0.state == nil && $0.saved?.isSaved == true })
    #expect(decoded.episodes.contains { $0.state?.state.position == 0 && $0.saved?.isSaved == false })
  }

  @Test func collectionPermutationProducesTheSameBytes() throws {
    let source = try fixture()
    let reversed = replacing(
      source, identities: source.episodeIdentities.reversed(), episodes: source.episodes.reversed())
    #expect(try PodcastStateSnapshotCodec.encodeWrapped(source) == PodcastStateSnapshotCodec.encodeWrapped(reversed))
  }

  @Test func omissionAndStampedClearRemainDifferent() throws {
    let source = try fixture()
    let omitted = PodcastStateSnapshot(
      exportedAt: source.exportedAt, globalSettings: source.globalSettings,
      subscriptions: source.subscriptions, episodeIdentities: source.episodeIdentities, episodes: source.episodes)
    let roundTrip = try PodcastStateSnapshotCodec.decode(PodcastStateSnapshotCodec.encode(omitted))
    #expect(roundTrip.lastPlayed == nil)
    #expect(try PodcastStateSnapshotCodec.encode(source) != PodcastStateSnapshotCodec.encode(omitted))
  }

  @Test func wrapperDetectsTamperingWithExactPayloadBytes() throws {
    let source = try fixture()
    let bytes = try PodcastStateSnapshotCodec.encodeWrapped(source)
    var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    object["payload"] = (object["payload"] as! String) + " "
    let changed = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: PodcastStateSnapshotCodecError.digestMismatch) {
      try PodcastStateSnapshotCodec.decodeWrapped(changed)
    }
  }

  @Test func rejectsDuplicateMissingParentAndMalformedDigest() throws {
    let source = try fixture()
    #expect(throws: PodcastStateSnapshotCodecError.duplicateIdentity) {
      try PodcastStateSnapshotCodec.encode(replacing(source, episodes: source.episodes + [source.episodes[0]]))
    }
    let missingParent = PodcastStateSnapshot(
      exportedAt: source.exportedAt, globalSettings: source.globalSettings,
      subscriptions: [], episodeIdentities: source.episodeIdentities, episodes: source.episodes)
    #expect(throws: PodcastStateSnapshotCodecError.invalidValue) { try PodcastStateSnapshotCodec.encode(missingParent) }
    var object = try #require(
      JSONSerialization.jsonObject(with: PodcastStateSnapshotCodec.encode(source)) as? [String: Any])
    var identities = object["episodeIdentities"] as! [[String: Any]]
    identities[0]["digest"] = String(repeating: "z", count: 64)
    object["episodeIdentities"] = identities
    let malformed = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: PodcastStateSnapshotCodecError.invalidValue) { try PodcastStateSnapshotCodec.decode(malformed) }
  }

  @Test func rejectsFormatVersionDepthAndTitleBounds() throws {
    let data = try PodcastStateSnapshotCodec.encode(fixture())
    let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var wrongVersion = original
    wrongVersion["version"] = 99
    let versionData = try JSONSerialization.data(withJSONObject: wrongVersion)
    #expect(throws: PodcastStateSnapshotCodecError.unsupportedVersion(99)) {
      try PodcastStateSnapshotCodec.decode(versionData)
    }
    var wrongFormat = original
    wrongFormat["format"] = "not-whirr"
    let formatData = try JSONSerialization.data(withJSONObject: wrongFormat)
    #expect(throws: PodcastStateSnapshotCodecError.invalidFormat) { try PodcastStateSnapshotCodec.decode(formatData) }
    let nesting = Data((String(repeating: "[", count: 17) + "0" + String(repeating: "]", count: 17)).utf8)
    #expect(throws: PodcastStateSnapshotCodecError.invalidValue) { try PodcastStateSnapshotCodec.decode(nesting) }
    var largeTitle = original
    var episodes = largeTitle["episodes"] as! [[String: Any]]
    episodes[0]["title"] = String(repeating: "é", count: 2049)
    largeTitle["episodes"] = episodes
    let titleData = try JSONSerialization.data(withJSONObject: largeTitle)
    #expect(throws: PodcastStateSnapshotCodecError.oversizedString) { try PodcastStateSnapshotCodec.decode(titleData) }
  }

  /// Native shows order by the native mode set, which includes `mostRecent`; the ABS enum does not.
  @Test func acceptsEveryNativeShowOrderModeAndRejectsOthers() throws {
    let data = try PodcastStateSnapshotCodec.encode(fixture())
    for mode in NativePodcastShowSortMode.allCases.map(\.rawValue) + ["newest"] {
      var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      var globals = object["globalSettings"] as! [String: Any]
      globals["showOrderMode"] = mode
      object["globalSettings"] = globals
      let changed = try JSONSerialization.data(withJSONObject: object)
      if mode == "newest" {
        #expect(throws: PodcastStateSnapshotCodecError.invalidValue) { try PodcastStateSnapshotCodec.decode(changed) }
      } else {
        #expect(try PodcastStateSnapshotCodec.decode(changed).globalSettings.showOrderMode == mode)
      }
    }
  }

  /// A snapshot from a build before Trim Silences carries neither override and stays valid; a
  /// value outside either set is refused rather than written into a CHECKed column.
  @Test func feedSettingsOverridesAreOptionalButMustBeKnown() throws {
    let data = try PodcastStateSnapshotCodec.encode(fixture())
    for (key, value, valid) in [
      ("trimSilencesOverride", "maximum", true), ("trimSilencesOverride", "gentle", false),
      ("voiceBoostOverride", "on", true), ("voiceBoostOverride", "loud", false),
    ] {
      var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      var subscriptions = try #require(object["subscriptions"] as? [[String: Any]])
      let index = try #require(subscriptions.firstIndex { $0["feedSettings"] != nil })
      var settings = try #require(subscriptions[index]["feedSettings"] as? [String: Any])
      #expect(settings[key] == nil)
      settings[key] = value
      subscriptions[index]["feedSettings"] = settings
      object["subscriptions"] = subscriptions
      let changed = try JSONSerialization.data(withJSONObject: object)
      if valid {
        let decoded = try PodcastStateSnapshotCodec.decode(changed)
        let feedSettings = try #require(decoded.subscriptions.compactMap(\.feedSettings).first)
        #expect(
          (key == "trimSilencesOverride" ? feedSettings.trimSilencesOverride : feedSettings.voiceBoostOverride)
            == value)
      } else {
        #expect(throws: PodcastStateSnapshotCodecError.invalidValue) { try PodcastStateSnapshotCodec.decode(changed) }
      }
    }
  }

  @Test func rejectsEmptyOrUnregisteredResolvedEpisodeIdentity() throws {
    let bytes = try PodcastStateSnapshotCodec.encode(fixture())
    for invalidKey in ["", "unregistered"] {
      var object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
      var episodes = object["episodes"] as! [[String: Any]]
      episodes[0]["identityKey"] = invalidKey
      object["episodes"] = episodes
      let invalid = try JSONSerialization.data(withJSONObject: object)
      #expect(throws: PodcastStateSnapshotCodecError.invalidValue) {
        try PodcastStateSnapshotCodec.decode(invalid)
      }
    }
  }

  private func replacing(
    _ value: PodcastStateSnapshot,
    identities: [EpisodeIdentitySnapshot]? = nil, episodes: [EpisodeSnapshot]? = nil
  ) -> PodcastStateSnapshot {
    PodcastStateSnapshot(
      exportedAt: value.exportedAt, globalSettings: value.globalSettings,
      subscriptions: value.subscriptions, lastPlayed: value.lastPlayed,
      episodeIdentities: identities ?? value.episodeIdentities, episodes: episodes ?? value.episodes)
  }

  private func fixture() throws -> PodcastStateSnapshot {
    let url = "https://example.com/feed"
    let id = PodcastCloudIdentity.subscriptionUUID(feedURL: url)!
    let generation = UUID(uuidString: "22222222-2222-8222-8222-222222222222")!
    let stamp = try PodcastCloudMutationStamp(
      physicalMilliseconds: 1000, logicalCounter: 1,
      installationUUID: generation, mutationUUID: generation)
    let globals = StampedGlobalSettings(
      autoDownloadEnabled: true, keepLatestCount: 3,
      deleteAfterPlayed: true, allowCellularAutoDownload: false, enabledAt: Date(timeIntervalSince1970: 50),
      showOrderMode: "custom", writeStamp: stamp)
    let subscription = SubscriptionSnapshot(
      subscriptionUUID: id, normalizedURL: url, title: "Feed",
      lifecycle: PodcastCloudFollowRegister(
        subscriptionUUID: id, generationUUID: generation, isFollowed: true, stamp: stamp),
      feedSettings: FeedSettingsSnapshot(
        autoDownload: "inherit", keepLatest: 5, deleteAfterPlayed: nil,
        rateStep: nil, includeInLatest: true, notificationOverride: "disabled", stamp: stamp),
      customOrder: StampedCustomOrder(value: 0, stamp: stamp))
    let identities = ["b", "a"].map { key in
      let digest = PodcastCloudIdentity.episodeDigest(identityKey: key)
      return EpisodeIdentitySnapshot(
        subscriptionUUID: id, generationUUID: generation, digest: digest,
        representativeDigest: digest, aliases: [key], guid: key, enclosureURL: "https://example.com/\(key).mp3")
    }
    let episodes = try identities.enumerated().map { index, identity in
      EpisodeSnapshot(
        subscriptionUUID: id, generationUUID: generation, representativeDigest: identity.digest,
        identityKey: identity.aliases[0], title: "Episode \(index)", duration: 120.5,
        state: index == 0
          ? nil
          : EpisodeStateSnapshot(
            state: try PodcastCloudEpisodeState(
              position: 0, isFinished: false, isDismissed: true, explicitEpoch: stamp, writeStamp: stamp),
            updatedAt: Date(timeIntervalSince1970: 100)),
        saved: try PodcastCloudSavedRegister(
          isSaved: index == 0,
          savedAt: index == 0 ? Date(timeIntervalSince1970: 101) : nil, stamp: stamp), resolution: .resolved)
    }
    return PodcastStateSnapshot(
      exportedAt: Date(timeIntervalSince1970: 100.25), globalSettings: globals,
      subscriptions: [subscription], lastPlayed: StampedBookmark(reference: nil, writeStamp: stamp),
      episodeIdentities: identities, episodes: episodes)
  }
}
