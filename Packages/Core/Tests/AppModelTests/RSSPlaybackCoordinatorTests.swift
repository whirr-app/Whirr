import ABSApi
import Foundation
import Persistence
import PodcastFeeds
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite(.timeLimit(.minutes(1))) struct RSSPlaybackCoordinatorTests {
  // MARK: - Session, identity, and authorization

  @Test func streamingPlaybackWithoutStoredCredentialCarriesNilAuthorization() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let stateStore = RSSEpisodeStateStore(database: fixture.database)
    _ = try await stateStore.recordTick(
      episodeId: try #require(fixture.episodeIDs["episode"]), position: 37.5, finished: false,
      capturedSequence: 0, now: Self.date(100))
    let coordinator = Self.makeCoordinator(fixture: fixture)

    let prepared = try await coordinator.startSession(
      itemID: fixture.itemID, episodeID: "episode")

    #expect(prepared.itemID == fixture.itemID)
    #expect(prepared.episodeID == "episode")
    #expect(prepared.startPosition == 37.5)
    #expect(prepared.duration == 120)
    #expect(prepared.source == .streaming)
    #expect(prepared.streamAuthorization == nil)
    #expect(prepared.chapters.isEmpty)
    #expect(prepared.tracks.count == 1)
    let track = try #require(prepared.tracks.first)
    #expect(track.index == 0)
    #expect(track.startOffset == 0)
    #expect(track.duration == 120)
    #expect(track.url == Self.episodeURL)
    #expect(track.mimeType == "audio/mpeg")
    #expect(track.title == "Episode")
  }

  @Test func missingDurationMakesTheEpisodeUnplayableByConstruction() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode", durationSeconds: nil)])
    let coordinator = Self.makeCoordinator(fixture: fixture)

    await #expect(
      throws: RSSPlaybackCoordinatorError.durationUnavailable(
        itemID: fixture.itemID, episodeID: "episode")
    ) {
      try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    }
  }

  @Test func absAndUndecodableItemIdsAreNotRSSItems() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let coordinator = Self.makeCoordinator(fixture: fixture)

    await #expect(
      throws: RSSPlaybackCoordinatorError.notAnRSSItem(itemID: "abs-item")
    ) {
      try await coordinator.startSession(itemID: "abs-item", episodeID: "episode")
    }
    await #expect(
      throws: RSSPlaybackCoordinatorError.notAnRSSItem(itemID: "rss:not-a-feed")
    ) {
      try await coordinator.startSession(itemID: "rss:not-a-feed", episodeID: "episode")
    }
  }

  @Test func unknownIdentityKeyIsRejectedWithoutUsingTheAlternateKey() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [
        RSSEpisodeUpsert(
          identityKey: "canonical", alternateIdentityKey: "alternate", enclosureURL: Self.episodeURL,
          durationSeconds: 120)
      ])
    let coordinator = Self.makeCoordinator(fixture: fixture)

    await #expect(
      throws: RSSPlaybackCoordinatorError.unknownEpisode(
        itemID: fixture.itemID, episodeID: "alternate")
    ) {
      try await coordinator.startSession(itemID: fixture.itemID, episodeID: "alternate")
    }
  }

  @Test func activeTickPersistsTheLatestPosition() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let coordinator = Self.makeCoordinator(fixture: fixture)
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")

    await coordinator.recordProgressTick(
      itemID: fixture.itemID, episodeID: "episode", currentTime: 48,
      listenedDelta: 11, isFinished: false, isSeek: false)

    #expect(
      try await RSSEpisodeStateStore(database: fixture.database).fetchState(episodeId: episodeID)
        == RSSEpisodeStateRecord(
          episodeId: episodeID, position: 48, finished: false, localSequence: 1,
          updatedAt: Self.date(100)))
  }

  @Test func siblingEpisodeTickIsDroppedEvenOnTheSameFeed() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [
        Self.episode(identityKey: "first"),
        Self.episode(identityKey: "sibling", title: "Sibling"),
      ])
    let siblingID = try #require(fixture.episodeIDs["sibling"])
    let coordinator = Self.makeCoordinator(fixture: fixture)
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "first")

    await coordinator.recordProgressTick(
      itemID: fixture.itemID, episodeID: "sibling", currentTime: 48,
      listenedDelta: 11, isFinished: false, isSeek: false)

    #expect(try await RSSEpisodeStateStore(database: fixture.database).fetchState(episodeId: siblingID) == nil)
  }

  @Test func tickWithNoActiveSessionIsDropped() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let coordinator = Self.makeCoordinator(fixture: fixture)

    await coordinator.recordProgressTick(
      itemID: fixture.itemID, episodeID: "episode", currentTime: 48,
      listenedDelta: 11, isFinished: false, isSeek: false)

    #expect(try await RSSEpisodeStateStore(database: fixture.database).fetchState(episodeId: episodeID) == nil)
  }

  @Test func staleTickIsDroppedAndTheNextTickUsesTheAdoptedSequence() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let stateStore = RSSEpisodeStateStore(database: fixture.database)
    let coordinator = Self.makeCoordinator(fixture: fixture)
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    _ = try await stateStore.recordTick(
      episodeId: episodeID, position: 10, finished: false, capturedSequence: 0, now: Self.date(100))

    await coordinator.recordProgressTick(
      itemID: fixture.itemID, episodeID: "episode", currentTime: 20,
      listenedDelta: 10, isFinished: false, isSeek: false)
    #expect(try await stateStore.fetchState(episodeId: episodeID)?.position == 10)
    #expect(try await stateStore.fetchState(episodeId: episodeID)?.localSequence == 1)

    await coordinator.recordProgressTick(
      itemID: fixture.itemID, episodeID: "episode", currentTime: 30,
      listenedDelta: 10, isFinished: false, isSeek: false)
    #expect(try await stateStore.fetchState(episodeId: episodeID)?.position == 30)
    #expect(try await stateStore.fetchState(episodeId: episodeID)?.localSequence == 2)
  }

  @Test func stopSessionMakesSubsequentTicksNoOps() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let coordinator = Self.makeCoordinator(fixture: fixture)
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    try await coordinator.stopSession()

    await coordinator.recordProgressTick(
      itemID: fixture.itemID, episodeID: "episode", currentTime: 48,
      listenedDelta: 11, isFinished: false, isSeek: false)

    #expect(try await RSSEpisodeStateStore(database: fixture.database).fetchState(episodeId: episodeID) == nil)
  }

  @Test func stopSessionSupersedesPreparationAlreadyWaitingOnDuration() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode", durationSeconds: nil)])
    let tracker = RSSActivePlaybackTracker()
    let loader = RSSPlaybackFixtures.BlockingDurationLoader(result: 120)
    let coordinator = Self.makeCoordinator(fixture: fixture, loader: loader, tracker: tracker)
    let starting = Task<PreparedPlayback, Error> {
      try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    }

    await loader.waitUntilStarted()
    try await coordinator.stopSession()
    await loader.release()

    await #expect(throws: CancellationError.self) {
      try await starting.value
    }
    #expect(tracker.activeEpisodeRowIDs.isEmpty)
  }

  @Test func quiesceForLogoutUsesTheSharedPlaybackError() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let coordinator = Self.makeCoordinator(fixture: fixture)
    await coordinator.quiesceForLogout()

    await #expect(throws: PlaybackCoordinatorError.quiescedForLogout) {
      try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    }
  }

  @Test func recoverOpenSessionsReturnsWithoutResolvingAnything() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode", durationSeconds: nil)])
    let loader = RSSPlaybackFixtures.DurationLoaderSpy(result: 99)
    let coordinator = Self.makeCoordinator(fixture: fixture, loader: loader)

    await coordinator.recoverOpenSessions()

    #expect(await loader.callCount == 0)
  }

  @Test func anEnclosureStreamNeverCarriesAnAuthorization() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let coordinator = Self.makeCoordinator(fixture: fixture)
    let prepared = try await coordinator.startSession(
      itemID: fixture.itemID, episodeID: "episode")

    #expect(prepared.streamAuthorization == nil)
    #expect(try await coordinator.renewStreamAuthorization() == nil)
  }

  @Test func aPrivateFeedEnclosureUsesItsStoredCredential() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let credentialStore = InMemoryFeedCredentialStore()
    let credential = try FeedCredential.basic(username: "feed-user", password: "feed-password")
    try credentialStore.save(credential, forFeedID: fixture.feedID)
    let coordinator = Self.makeCoordinator(fixture: fixture, credentialStore: credentialStore)

    let prepared = try await coordinator.startSession(
      itemID: fixture.itemID, episodeID: "episode")
    let authorization = try #require(prepared.streamAuthorization)

    #expect(authorization.httpHeaderFields(for: Self.episodeURL) == credential.headerFields)
  }

  @Test func aFeedNeverUsesAnotherFeedsCredential() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let otherFeedID = try await RSSFeedStore(database: fixture.database).subscribe(
      feedURL: URL(string: "https://other.example.test/show.xml")!,
      title: "Other", author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Self.date(1))
    let credentialStore = InMemoryFeedCredentialStore()
    try credentialStore.save(
      try FeedCredential.basic(username: "other-user", password: "other-password"),
      forFeedID: otherFeedID)
    let coordinator = Self.makeCoordinator(fixture: fixture, credentialStore: credentialStore)

    let prepared = try await coordinator.startSession(
      itemID: fixture.itemID, episodeID: "episode")

    #expect(prepared.streamAuthorization == nil)
  }

  @Test func anEnclosureOnAnotherHostReceivesNoCredential() async throws {
    let fixture = try await Self.makeFixture(
      feedURL: URL(string: "https://feeds.example.test/show.xml")!,
      episodes: [
        Self.episode(
          identityKey: "episode",
          enclosureURL: URL(string: "https://media.example.test/episode.mp3")!)
      ])
    let credentialStore = InMemoryFeedCredentialStore()
    let credential = try FeedCredential.basic(username: "feed-user", password: "feed-password")
    try credentialStore.save(credential, forFeedID: fixture.feedID)
    let coordinator = Self.makeCoordinator(fixture: fixture, credentialStore: credentialStore)

    let prepared = try await coordinator.startSession(
      itemID: fixture.itemID, episodeID: "episode")
    let authorization = try #require(prepared.streamAuthorization)

    #expect(
      authorization.httpHeaderFields(for: URL(string: "https://media.example.test:443/episode.mp3")!)
        .isEmpty)
  }

  @Test func rssAuthorizationTreatsDefaultPortsAsTheSameOriginAndRejectsLocalFiles() throws {
    let credential = try FeedCredential(authorization: "Basic default-port-canary")
    let authorization = try #require(
      RSSPlaybackStreamAuthorization(
        credential: credential, feedURL: URL(string: "https://feeds.example.test/show.xml")!))

    #expect(
      authorization.httpHeaderFields(
        for: URL(string: "https://feeds.example.test:443/episode.mp3")!) == credential.headerFields)
    #expect(authorization.httpHeaderFields(for: URL(fileURLWithPath: "/tmp/episode.mp3")).isEmpty)
  }

  @Test func rssAuthorizationDescriptionsNeverRevealCredentialMaterial() throws {
    let canary = "Basic CANARY-RSS-CREDENTIAL-MUST-NOT-LEAK"
    let credential = try FeedCredential(authorization: canary)
    let authorization = try #require(
      RSSPlaybackStreamAuthorization(
        credential: credential, feedURL: URL(string: "https://feeds.example.test/show.xml")!))

    #expect(String(describing: authorization).contains(canary) == false)
    #expect(String(reflecting: authorization).contains(canary) == false)
  }

  @Test func completedRSSFileUsesLocalPlaybackAndMissingFileFallsBackToStreaming() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let downloads = try RSSDownloadStore(database: fixture.database)
    let row = try await downloads.claimOrCreateAsync(episodeId: episodeID)
    _ = try await downloads.transitionAsync(downloadId: row.id!, to: .downloading)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = try RSSFileStore(
      rootURL: root, fileAttributes: InertFileAttributes(), downloadStore: downloads)
    let temporary = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try Data([1, 2, 3, 4]).write(to: temporary)
    _ = try files.completeTransfer(
      downloadId: row.id!, temporaryFileURL: temporary,
      response: DownloadTransferResponse(httpStatusCode: 200, mimeType: "audio/mpeg", contentLength: 4))

    let coordinator = Self.makeCoordinator(fixture: fixture, fileStore: files)
    let local = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    #expect(local.source == .local)
    #expect(local.streamAuthorization == nil)
    let localURL = try #require(local.tracks.first?.url)

    // A file that does not match the persisted transfer metadata is not trusted for playback.
    try Data([1]).write(to: localURL)
    let invalidFallback = try await Self.makeCoordinator(fixture: fixture, fileStore: files)
      .startSession(itemID: fixture.itemID, episodeID: "episode")
    #expect(invalidFallback.source == .streaming)
    #expect(invalidFallback.tracks.first?.url == Self.episodeURL)

    try FileManager.default.removeItem(at: localURL)
    let missingFallback = try await Self.makeCoordinator(fixture: fixture, fileStore: files)
      .startSession(itemID: fixture.itemID, episodeID: "episode")
    #expect(missingFallback.source == .streaming)
    #expect(missingFallback.tracks.first?.url == Self.episodeURL)
  }

  // MARK: - Active playback tracking

  @Test func activePlaybackTrackerPublishesAndClearsTheRSSEpisodeRow() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    let tracker = RSSActivePlaybackTracker()
    let coordinator = Self.makeCoordinator(fixture: fixture, tracker: tracker)

    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    #expect(tracker.activeEpisodeRowIDs == [episodeID])
    try await coordinator.stopSession()
    #expect(tracker.activeEpisodeRowIDs.isEmpty)

    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    #expect(tracker.activeEpisodeRowIDs == [episodeID])
    await coordinator.quiesceForLogout()
    #expect(tracker.activeEpisodeRowIDs.isEmpty)
  }

  @Test func activePlaybackIsExcludedWhileStartSessionIsPreparing() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode", durationSeconds: nil)])
    let episodeID = try #require(fixture.episodeIDs["episode"])
    try await RSSFeedSettingsStore(database: fixture.database).setKeepLatestOverride(
      feedId: fixture.feedID, count: 0)
    let downloads = try RSSDownloadStore(database: fixture.database)
    let download = try await downloads.claimOrCreateAsync(episodeId: episodeID)
    _ = try await downloads.transitionAsync(downloadId: try #require(download.id), to: .downloading)
    _ = try await downloads.completeAsync(
      downloadId: try #require(download.id), actualBytes: 100)

    let tracker = RSSActivePlaybackTracker()
    let loader = RSSPlaybackFixtures.BlockingDurationLoader(result: 120)
    let coordinator = Self.makeCoordinator(fixture: fixture, loader: loader, tracker: tracker)
    let startTask = Task<PreparedPlayback, Error> {
      try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    }

    await loader.waitUntilStarted()
    #expect(tracker.activeEpisodeRowIDs == [episodeID])

    let eviction = StorageEvictionStore(
      database: fixture.database, accountId: 0,
      activeRSSExclusionProvider: { tracker.activeEpisodeRowIDs })
    #expect(try await eviction.claimUnion(targetBytes: 1).isEmpty)

    await loader.release()
    _ = try await startTask.value
    try await coordinator.stopSession()
  }

  @Test func failedReplacementStartClearsActivePlaybackExclusion() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [
        Self.episode(identityKey: "active"),
        Self.episode(identityKey: "failed", durationSeconds: nil),
      ])
    let tracker = RSSActivePlaybackTracker()
    let activeCoordinator = Self.makeCoordinator(fixture: fixture, tracker: tracker)
    _ = try await activeCoordinator.startSession(itemID: fixture.itemID, episodeID: "active")
    #expect(tracker.activeEpisodeRowIDs == [try #require(fixture.episodeIDs["active"])])

    let failingCoordinator = Self.makeCoordinator(
      fixture: fixture, loader: RSSPlaybackFixtures.DurationLoaderSpy(result: nil), tracker: tracker)
    await #expect(
      throws: RSSPlaybackCoordinatorError.durationUnavailable(
        itemID: fixture.itemID, episodeID: "failed")
    ) {
      try await failingCoordinator.startSession(itemID: fixture.itemID, episodeID: "failed")
    }

    #expect(tracker.activeEpisodeRowIDs.isEmpty)
  }

  @Test func cancelledStartClearsActivePlaybackExclusion() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode", durationSeconds: nil)])
    let tracker = RSSActivePlaybackTracker()
    let loader = RSSPlaybackFixtures.BlockingDurationLoader(result: 120)
    let coordinator = Self.makeCoordinator(fixture: fixture, loader: loader, tracker: tracker)
    let startTask = Task<PreparedPlayback, Error> {
      try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    }

    await loader.waitUntilStarted()
    #expect(tracker.activeEpisodeRowIDs.count == 1)
    startTask.cancel()
    await loader.release()

    await #expect(throws: CancellationError.self) {
      try await startTask.value
    }
    #expect(tracker.activeEpisodeRowIDs.isEmpty)
  }

  @Test func retentionSweepSkipsActiveEpisodeButStillDeletesDroppedInactiveEpisode() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "active"), Self.episode(identityKey: "inactive")])
    let activeID = try #require(fixture.episodeIDs["active"])
    let inactiveID = try #require(fixture.episodeIDs["inactive"])
    let tracker = RSSActivePlaybackTracker()
    // The sweeping store receives the tracker explicitly, exactly as the refresh composition root
    // wires it. A store built without it excludes nothing, which is what every non-sweeping caller
    // wants.
    let store = RSSEpisodeStore(
      database: fixture.database,
      activeRSSExclusionProvider: { [tracker] in tracker.activeEpisodeRowIDs })
    let coordinator = Self.makeCoordinator(fixture: fixture, tracker: tracker)
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "active")

    _ = try await store.applyRefresh(feedId: fixture.feedID, episodes: [])
    let sweep = try await store.sweepDroppedEpisodes(feedId: fixture.feedID)

    #expect(sweep.deleted == 1)
    #expect(try await store.fetchEpisode(episodeId: activeID) != nil)
    #expect(try await store.fetchEpisode(episodeId: inactiveID) == nil)

    try await coordinator.stopSession()
    let afterStop = try await store.sweepDroppedEpisodes(feedId: fixture.feedID)
    #expect(afterStop.deleted == 1)
    #expect(try await store.fetchEpisode(episodeId: activeID) == nil)
  }

  @Test func anRSSItemNamedWithoutAnEpisodeIsItsOwnFailure() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let coordinator = Self.makeCoordinator(fixture: fixture)

    await #expect(throws: RSSPlaybackCoordinatorError.missingEpisodeID(itemID: fixture.itemID)) {
      try await coordinator.startSession(itemID: fixture.itemID, episodeID: nil)
    }
  }
}
