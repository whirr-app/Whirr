import ABSApi
import Foundation
import Persistence
import PodcastFeeds
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// The composed graph `AppEnvironment` builds: a `PlaybackModel` whose `PlaybackSyncing` is the
/// router, with the real `RSSPlaybackCoordinator` and the account's ABS coordinator behind it.
/// `RoutingPlaybackSyncingTests` pins the routing; these add what only the composition can get
/// wrong: the launch-recovery gate opens for both origins, and a play intent reaches the right
/// coordinator and returns a real preparation.
@MainActor
@Suite("Routed playback recovery")
struct RoutedPlaybackRecoveryTests {
  // MARK: - The launch gate

  /// An account with no subscriptions behaves as if there were no router: one recovery, then the
  /// start it was holding back.
  @Test func anABSOnlyAccountRecoversAndThenStarts() async throws {
    let harness = try await Harness()
    harness.abs.stubStartSession(.success(Self.absPreparation))

    await harness.model.start(itemID: "li_book")

    // The pre-start `.buffering` reaches the ABS child because the announcement derives this
    // item's ABS origin (`anRSSOnlyAccountStartsFromItsLocalState` covers RSS).
    #expect(
      harness.abs.calls == [
        .recoverOpenSessions, .notifyPlaybackPhase(.buffering),
        .startSession(itemID: "li_book", episodeID: nil),
      ])
    #expect(harness.model.activeItemID == "li_book")
  }

  /// The RSS coordinator has no sessions to recover, so nothing on its own side would ever make a
  /// device-owned episode wait. It waits because the gate is the router's, and the router's
  /// recovery is not finished until the ABS side has answered too.
  @Test func anRSSStartWaitsForTheABSSideOfRecovery() async throws {
    let harness = try await Harness()
    harness.abs.holdRecoverOpenSessions()

    let start = Task { await harness.model.start(itemID: harness.itemID, episodeID: "episode") }
    await harness.abs.waitForCalls { $0.contains(.recoverOpenSessions) }
    #expect(
      harness.model.activeItemID == nil,
      "a device-owned episode must not open while server recovery is still running")

    harness.abs.releaseRecoverOpenSessions()
    await start.value

    #expect(harness.model.activeItemID == harness.itemID)
    #expect(harness.model.activeEpisodeID == "episode")
  }

  /// The whole point of the RSS side: a preparation built from the native tables, with the stored
  /// position as the resume point and no server call anywhere in it.
  @Test func anRSSOnlyAccountStartsFromItsLocalState() async throws {
    let harness = try await Harness()
    _ = try await harness.stateStore.recordTick(
      episodeId: harness.episodeRowID, position: 42, finished: false, capturedSequence: 0,
      now: Self.date(200))

    await harness.model.start(itemID: harness.itemID, episodeID: "episode")

    #expect(harness.model.activeItemID == harness.itemID)
    let loadedPosition = harness.player.intents.compactMap { intent -> Double? in
      if case .load(_, let initialGlobalPosition, _, _) = intent { return initialGlobalPosition }
      return nil
    }
    #expect(loadedPosition == [42], "the enclosure loads at the position the local row holds")
    #expect(
      harness.abs.calls == [.recoverOpenSessions],
      "the server coordinator recovers at launch and is not touched again")
  }

  /// Mixed: both origins are playable in one session, and switching between them leaves no ABS
  /// session behind. The router closes the outgoing one because the RSS coordinator never sees it.
  /// The ABS buffering phase belongs to its own announced start; the missing second buffering phase
  /// proves the RSS announcement did not touch ABS.
  @Test func aMixedAccountSwitchesBetweenOriginsAndClosesTheOutgoingSession() async throws {
    let harness = try await Harness()
    harness.abs.stubStartSession(.success(Self.absPreparation))

    await harness.model.start(itemID: "li_book")
    await harness.model.start(itemID: harness.itemID, episodeID: "episode")

    #expect(harness.model.activeItemID == harness.itemID)
    #expect(
      harness.abs.calls == [
        .recoverOpenSessions, .notifyPlaybackPhase(.buffering),
        .startSession(itemID: "li_book", episodeID: nil), .stopSession,
      ])
  }

  // MARK: - Logout

  /// Logout tears the account down while a device-owned episode is playing. Both coordinators have
  /// to refuse further work. The RSS tables outlive the account, but nothing may keep writing to
  /// them through a model the logout has already quiesced.
  @Test func logoutDuringRSSPlaybackQuiescesBothCoordinators() async throws {
    let harness = try await Harness()
    await harness.model.start(itemID: harness.itemID, episodeID: "episode")
    #expect(harness.model.activeItemID == harness.itemID)

    await harness.model.prepareForLogout()

    #expect(harness.model.isQuiescedForLogout)
    #expect(harness.model.activeItemID == nil)
    #expect(harness.abs.calls.contains(.quiesceForLogout))
    await #expect(throws: PlaybackCoordinatorError.quiescedForLogout) {
      try await harness.rss.startSession(itemID: harness.itemID, episodeID: "episode")
    }
  }

  /// The position reached before logout is already durable (every RSS tick is written where it is
  /// received), so quiescing must not be the thing that decides whether it survives.
  @Test func logoutLeavesTheDeviceOwnedPositionInPlace() async throws {
    let harness = try await Harness()
    await harness.model.start(itemID: harness.itemID, episodeID: "episode")
    await harness.rss.recordProgressTick(
      itemID: harness.itemID, episodeID: "episode", currentTime: 75, listenedDelta: 75,
      isFinished: false, isSeek: false)

    await harness.model.prepareForLogout()

    let state = try await harness.stateStore.fetchState(episodeId: harness.episodeRowID)
    #expect(state?.position == 75)
  }

  // MARK: - Harness

  private struct Harness {
    let model: PlaybackModel
    let abs: FakePlaybackSyncing
    let rss: RSSPlaybackCoordinator
    let player: FakePlaybackControlling
    let stateStore: RSSEpisodeStateStore
    let itemID: String
    let episodeRowID: Int64

    @MainActor
    init() async throws {
      let database = try AppDatabase.inMemory()
      let feedID = try await RSSFeedStore(database: database).subscribe(
        feedURL: URL(string: "https://example.com/feed-\(UUID().uuidString).xml")!,
        title: "Feed", author: nil, synopsis: nil, artworkURL: nil, subscribedAt: date(1))
      let episodeStore = RSSEpisodeStore(database: database)
      _ = try await episodeStore.applyRefresh(
        feedId: feedID,
        episodes: [
          RSSEpisodeUpsert(
            identityKey: "episode", title: "Episode", enclosureURL: episodeURL,
            enclosureType: "audio/mpeg", durationSeconds: 120)
        ])
      let rows = try await database.readAsync { db in
        try RSSEpisodeRecord.fetchAll(
          db, sql: "SELECT * FROM rssEpisode WHERE feedId = ?", arguments: [feedID])
      }
      episodeRowID = try #require(rows.first?.id)
      itemID = try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId
      stateStore = RSSEpisodeStateStore(database: database)
      rss = RSSPlaybackCoordinator(
        episodeStore: episodeStore,
        stateStore: stateStore,
        durationResolver: RSSEpisodeDurationResolver(episodeStore: episodeStore),
        feedStore: RSSFeedStore(database: database),
        credentialStore: InMemoryFeedCredentialStore(),
        now: { date(200) })
      abs = FakePlaybackSyncing()
      player = FakePlaybackControlling()
      model = PlaybackModel(
        sync: RoutingPlaybackSyncing(abs: abs, rss: rss),
        player: player,
        account: FakeAccountLifecycle(),
        appLifecycle: FakeAppLifecycle())
    }
  }

  private nonisolated static let episodeURL = URL(string: "https://example.com/episode.mp3")!

  private nonisolated static func date(_ time: TimeInterval) -> Date {
    Date(timeIntervalSince1970: time)
  }

  private static let absPreparation = PreparedPlayback(
    itemID: "li_book",
    episodeID: nil,
    startPosition: 0,
    duration: 3_600,
    tracks: [
      PreparedPlaybackTrack(
        index: 0, startOffset: 0, duration: 3_600,
        url: URL(string: "https://books.example.test/file.m4b")!, mimeType: "audio/mp4",
        title: "Book")
    ],
    chapters: [],
    source: .streaming,
    streamAuthorization: nil)
}
