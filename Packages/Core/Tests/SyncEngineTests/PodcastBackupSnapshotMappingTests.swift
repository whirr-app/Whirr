import Foundation
import Persistence
import Testing

@testable import SyncEngine

@Suite struct PodcastBackupSnapshotMappingTests {
  @Test func mapsAFullDeviceAndSurvivesTheFileRoundTrip() throws {
    let result = try PodcastBackupSnapshotMapping.snapshot(from: Self.contents(), exportedAt: Self.date(900))
    #expect(result.skippedFeeds == 0 && result.skippedEpisodes == 0)
    let snapshot = result.snapshot
    let decoded = try PodcastStateSnapshotCodec.decodeWrapped(PodcastStateSnapshotCodec.encodeWrapped(snapshot))
    #expect(try PodcastStateSnapshotCodec.encode(decoded) == PodcastStateSnapshotCodec.encode(snapshot))

    #expect(snapshot.globalSettings.showOrderMode == "mostRecent")
    #expect(snapshot.globalSettings.keepLatestCount == 7)
    let subscription = try #require(snapshot.subscriptions.first)
    #expect(subscription.normalizedURL == "https://example.com/feed")
    #expect(subscription.lifecycle.isFollowed)
    #expect(subscription.feedSettings?.autoDownload == "enabled")
    #expect(subscription.feedSettings?.trimSilencesOverride == "off")
    #expect(subscription.feedSettings?.voiceBoostOverride == "off")
    #expect(subscription.customOrder?.value == 2)

    let byKey = Dictionary(uniqueKeysWithValues: snapshot.episodes.map { ($0.identityKey, $0) })
    #expect(byKey["zero"]?.state?.state.position == 0)
    #expect(byKey["zero"]?.state?.state.explicitEpoch == .bottom)
    #expect(byKey["finished"]?.state?.state.isFinished == true)
    #expect(byKey["finished"]?.state?.state.explicitEpoch == byKey["finished"]?.state?.state.writeStamp)
    #expect(byKey["saved"]?.state == nil && byKey["saved"]?.saved?.savedAt == Self.date(300))
    #expect(snapshot.lastPlayed?.reference?.representativeDigest == byKey["saved"]?.representativeDigest)
  }

  /// A never-synced device has no registry, so the generation is the derived initial one; a
  /// registered re-follow's generation is carried instead.
  @Test func usesTheRegisteredGenerationWhenPresent() throws {
    let url = "https://example.com/feed"
    let uuid = try #require(PodcastCloudIdentity.subscriptionUUID(feedURL: url))
    let derived = try PodcastBackupSnapshotMapping.snapshot(from: Self.contents(), exportedAt: Self.date(900))
    #expect(
      derived.snapshot.subscriptions[0].lifecycle.generationUUID
        == PodcastCloudIdentity.initialGenerationUUID(subscriptionUUID: uuid))

    let refollowed = UUID()
    var contents = Self.contents()
    contents.followedGenerations = [uuid.uuidString.lowercased(): refollowed.uuidString.lowercased()]
    let registered = try PodcastBackupSnapshotMapping.snapshot(from: contents, exportedAt: Self.date(900))
    #expect(registered.snapshot.subscriptions[0].lifecycle.generationUUID == refollowed)
    #expect(registered.snapshot.episodes.allSatisfy { $0.generationUUID == refollowed })
  }

  @Test func identicalContentsProduceIdenticalFiles() throws {
    let first = try PodcastBackupSnapshotMapping.snapshot(from: Self.contents(), exportedAt: Self.date(900))
    let second = try PodcastBackupSnapshotMapping.snapshot(from: Self.contents(), exportedAt: Self.date(900))
    #expect(
      try PodcastStateSnapshotCodec.encodeWrapped(first.snapshot)
        == PodcastStateSnapshotCodec.encodeWrapped(second.snapshot))
  }

  /// Unusable addresses are skipped and counted rather than failing the whole backup; their
  /// episodes go with them. A credentialed enclosure is dropped, not the episode.
  @Test func skipsWhatTheFileCannotCarryAndCountsIt() throws {
    var contents = Self.contents()
    contents.feeds += [
      Self.feed("https://user:secret@example.com/private"),
      Self.feed("not a url"),
      Self.feed("HTTPS://EXAMPLE.com:443/feed"),
    ]
    contents.episodes += [Self.episode("orphan", feed: "not a url", state: nil)]
    contents.episodes[0].enclosureURL = "https://user:pw@cdn.example.com/a.mp3"
    contents.episodes[1].alternateIdentityKey = contents.episodes[1].identityKey

    let result = try PodcastBackupSnapshotMapping.snapshot(from: contents, exportedAt: Self.date(900))
    #expect(result.skippedFeeds == 3)
    #expect(result.skippedEpisodes == 1)
    #expect(result.snapshot.subscriptions.count == 1)
    #expect(result.snapshot.episodes.first { $0.identityKey == "zero" }?.enclosureURL == nil)
    #expect(result.snapshot.episodes.first { $0.identityKey == "finished" }?.alternateIdentityKey == nil)
    _ = try PodcastStateSnapshotCodec.encodeWrapped(result.snapshot)
  }

  @Test func clipsOversizedTitlesAtACharacterBoundary() throws {
    var contents = Self.contents()
    contents.feeds[0].title = String(repeating: "é", count: 3000)
    let result = try PodcastBackupSnapshotMapping.snapshot(from: contents, exportedAt: Self.date(900))
    let title = result.snapshot.subscriptions[0].title
    #expect(title.utf8.count == 4096)
    #expect(title.allSatisfy { $0 == "é" })
  }

  /// Device → file → a clean device reproduces the same shows, settings, order, state, saves and
  /// bookmark, independent of local row IDs.
  @Test func aBackupRestoredOnACleanDeviceReadsBackTheSame() async throws {
    let source = try AppDatabase.inMemory()
    _ = try await NativePodcastBackupRestorer(database: source).restore(Self.contents())
    let original = try await NativePodcastBackupReader(database: source).contents()

    let file = try PodcastStateSnapshotCodec.encodeWrapped(
      PodcastBackupSnapshotMapping.snapshot(from: original, exportedAt: Self.date(900)).snapshot)
    let restored = PodcastBackupSnapshotMapping.contents(from: try PodcastStateSnapshotCodec.decodeWrapped(file))

    let target = try AppDatabase.inMemory()
    let outcome = try await NativePodcastBackupRestorer(database: target).restore(restored)
    #expect(outcome.showsAdded == 1 && outcome.episodesUnmatched == 0)
    let copy = try await NativePodcastBackupReader(database: target).contents()
    #expect(copy.feeds == original.feeds)
    // Row IDs order the reader's episodes; the file orders them by digest.
    #expect(
      copy.episodes.sorted { $0.identityKey < $1.identityKey }
        == original.episodes.sorted { $0.identityKey < $1.identityKey })
    #expect(copy.bookmark == original.bookmark)
    #expect(copy.globalSettings == original.globalSettings)
    #expect(copy.showOrderMode == original.showOrderMode)
    #expect(copy.followedGenerations == original.followedGenerations)
  }

  /// Only followed shows are restored, and a save's removal marker alone brings nothing back.
  @Test func restoreInputLeavesOutUnfollowedShowsAndRemovalOnlyEpisodes() throws {
    let snapshot = try PodcastBackupSnapshotMapping.snapshot(from: Self.contents(), exportedAt: Self.date(900))
      .snapshot
    let removed = try #require(snapshot.episodes.first { $0.identityKey == "zero" })
    let unfollowedURL = "https://example.com/gone"
    let unfollowedUUID = try #require(PodcastCloudIdentity.subscriptionUUID(feedURL: unfollowedURL))
    let edited = PodcastStateSnapshot(
      exportedAt: snapshot.exportedAt, globalSettings: snapshot.globalSettings,
      subscriptions: snapshot.subscriptions + [
        SubscriptionSnapshot(
          subscriptionUUID: unfollowedUUID, normalizedURL: unfollowedURL, title: "Gone",
          lifecycle: PodcastCloudFollowRegister(
            subscriptionUUID: unfollowedUUID, generationUUID: UUID(), isFollowed: false, stamp: .bottom))
      ],
      lastPlayed: snapshot.lastPlayed, episodeIdentities: snapshot.episodeIdentities,
      episodes: snapshot.episodes.map { episode in
        guard episode == removed else { return episode }
        return EpisodeSnapshot(
          subscriptionUUID: episode.subscriptionUUID, generationUUID: episode.generationUUID,
          representativeDigest: episode.representativeDigest, identityKey: episode.identityKey,
          guid: episode.guid, enclosureURL: episode.enclosureURL, title: episode.title,
          saved: try? PodcastCloudSavedRegister(isSaved: false, stamp: .bottom), resolution: .resolved)
      })

    let contents = PodcastBackupSnapshotMapping.contents(from: edited)
    #expect(contents.feeds.map(\.feedURL) == ["https://example.com/feed"])
    #expect(Set(contents.episodes.map(\.identityKey)) == ["finished", "saved"])
    #expect(contents.bookmark?.identityKey == "saved")
  }

  static func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

  static func feed(_ url: String) -> NativePodcastBackupContents.Feed {
    NativePodcastBackupContents.Feed(
      feedURL: url, title: "Feed", author: "Author", subscribedAt: date(100), customSortIndex: 2,
      settings: NativePodcastBackupContents.FeedSettings(
        autoDownload: "enabled", keepLatest: 5, deleteAfterPlayed: nil, rateStep: nil, includeInLatest: true,
        notificationOverride: "inherit", trimSilencesOverride: "off", voiceBoostOverride: "off"))
  }

  static func episode(
    _ key: String, feed: String = "https://example.com/feed", state: NativePodcastBackupContents.EpisodeState?,
    savedAt: Date? = nil
  ) -> NativePodcastBackupContents.Episode {
    NativePodcastBackupContents.Episode(
      feedURL: feed, identityKey: key, alternateIdentityKey: nil, guid: "guid-\(key)",
      enclosureURL: "https://example.com/\(key).mp3", title: key, publishedAt: date(50), duration: 600,
      state: state, savedAt: savedAt)
  }

  static func contents() -> NativePodcastBackupContents {
    NativePodcastBackupContents(
      globalSettings: NativePodcastSettingsRecord(autoDownloadEnabled: true, keepLatestCount: 7),
      showOrderMode: "mostRecent",
      feeds: [feed("https://example.com/feed")],
      episodes: [
        episode("zero", state: .init(position: 0, finished: false, dismissed: false, updatedAt: date(200))),
        episode("finished", state: .init(position: 600, finished: true, dismissed: false, updatedAt: date(210))),
        episode("saved", state: nil, savedAt: date(300)),
      ],
      bookmark: NativePodcastBackupContents.Bookmark(
        feedURL: "https://example.com/feed", identityKey: "saved", updatedAt: date(400)),
      followedGenerations: [:])
  }
}
