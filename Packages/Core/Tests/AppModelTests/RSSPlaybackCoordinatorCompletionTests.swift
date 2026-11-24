import ABSApi
import Foundation
import Persistence
import PodcastFeeds
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

extension RSSPlaybackCoordinatorTests {
  // MARK: - Natural completion

  @Test func naturalCompletionDeletesTheDownloadOncePerWitnessedTransition() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let deletions = RSSPlaybackFixtures.RSSFinishedDeletionRecorder()
    let coordinator = Self.makeCoordinator(
      fixture: fixture,
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: true),
      requestFinishedDownloadDeletion: { await deletions.record(itemID: $0, episodeID: $1) })
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")

    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 30, isFinished: false)
    #expect(await deletions.values.isEmpty)
    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 120, isFinished: true)
    #expect(
      await deletions.values == [
        RSSPlaybackFixtures.RSSFinishedDeletionIdentity(itemID: fixture.itemID, episodeID: "episode")
      ])
    // A repeated finished tick on the same stream is not a second completion.
    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 120, isFinished: true)
    #expect(await deletions.values.count == 1)
  }

  @Test func aStreamThatStartsAlreadyFinishedNeverDeletesOnItsFirstTick() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    _ = try await RSSEpisodeStateStore(database: fixture.database).recordTick(
      episodeId: try #require(fixture.episodeIDs["episode"]), position: 120, finished: true,
      capturedSequence: 0, now: Self.date(50))
    let deletions = RSSPlaybackFixtures.RSSFinishedDeletionRecorder()
    let coordinator = Self.makeCoordinator(
      fixture: fixture,
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: true),
      requestFinishedDownloadDeletion: { await deletions.record(itemID: $0, episodeID: $1) })
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")

    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 120, isFinished: true)

    #expect(await deletions.values.isEmpty)
  }

  @Test func finishingAnEpisodeRequestsOneAutoDownloadReapPerTransition() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let reaps = RSSPlaybackFixtures.RSSReapCounter()
    let coordinator = Self.makeCoordinator(
      fixture: fixture, requestPodcastAutoDownloadReap: { await reaps.record() })
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")

    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 30, isFinished: false)
    #expect(await reaps.count == 0)
    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 120, isFinished: true)
    #expect(await reaps.count == 1)
    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 120, isFinished: true)
    #expect(await reaps.count == 1)
    // Replaying and finishing again is a second genuine completion.
    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 10, isFinished: false)
    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 120, isFinished: true)
    #expect(await reaps.count == 2)
  }

  @Test func aReapIsRequestedEvenWhenDeleteAfterPlayingIsOff() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let reaps = RSSPlaybackFixtures.RSSReapCounter()
    let coordinator = Self.makeCoordinator(
      fixture: fixture, downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: false),
      requestPodcastAutoDownloadReap: { await reaps.record() })
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")

    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 120, isFinished: true)

    #expect(await reaps.count == 1)
  }

  @Test func naturalCompletionRetainsTheDownloadWhenDeleteAfterPlayingIsOff() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let deletions = RSSPlaybackFixtures.RSSFinishedDeletionRecorder()
    let coordinator = Self.makeCoordinator(
      fixture: fixture,
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: false),
      requestFinishedDownloadDeletion: { await deletions.record(itemID: $0, episodeID: $1) })
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")

    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 30, isFinished: false)
    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 120, isFinished: true)

    #expect(await deletions.values.isEmpty)
    #expect(
      try await RSSEpisodeStateStore(database: fixture.database).fetchState(
        episodeId: try #require(fixture.episodeIDs["episode"]))?.finished == true)
  }

  @Test func aFinishingWriteThatFailsDefersDeletionUntilOneLands() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let episodeRowID = try #require(fixture.episodeIDs["episode"])
    let stateStore = RSSEpisodeStateStore(database: fixture.database)
    let deletions = RSSPlaybackFixtures.RSSFinishedDeletionRecorder()
    let coordinator = Self.makeCoordinator(
      fixture: fixture,
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: true),
      requestFinishedDownloadDeletion: { await deletions.record(itemID: $0, episodeID: $1) })
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 30, isFinished: false)

    // Another writer moves the row on, so the coordinator's captured sequence goes stale and its
    // finishing write is rejected. Cleanup must wait for a finish that actually persisted.
    let current = try #require(try await stateStore.fetchState(episodeId: episodeRowID))
    _ = try await stateStore.recordTick(
      episodeId: episodeRowID, position: 45, finished: false,
      capturedSequence: current.localSequence, now: Self.date(60))
    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 120, isFinished: true)
    #expect(await deletions.values.isEmpty)
    #expect(try await stateStore.fetchState(episodeId: episodeRowID)?.finished == false)

    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 120, isFinished: true)
    #expect(try await stateStore.fetchState(episodeId: episodeRowID)?.finished == true)
    #expect(
      await deletions.values == [
        RSSPlaybackFixtures.RSSFinishedDeletionIdentity(itemID: fixture.itemID, episodeID: "episode")
      ])
  }

  @Test func naturalCompletionClearsOnlyTheSavedEpisodeThatFinished() async throws {
    let fixture = try await Self.makeFixture(
      episodes: [Self.episode(identityKey: "episode"), Self.episode(identityKey: "sibling")])
    let accountID = try await Self.insertAccount(fixture)
    let savedShelf = SavedShelfStore(database: fixture.database, accountId: accountID)
    try await savedShelf.save(.rssEpisode(itemID: fixture.itemID, episodeID: "episode"))
    try await savedShelf.save(.rssEpisode(itemID: fixture.itemID, episodeID: "sibling"))
    let coordinator = Self.makeCoordinator(fixture: fixture)
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")

    // The first tick lands at the position playback started from, which is a save-resolving start
    // for a positive position but not for a fresh one; the finish is what must clear this save.
    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 0, isFinished: false)
    let savedBefore = try await fixture.database.readAsync { db in
      try Int64.fetchAll(db, sql: "SELECT rssEpisodeId FROM rssSavedShelfEntry ORDER BY id")
    }
    #expect(savedBefore == [fixture.episodeIDs["episode"], fixture.episodeIDs["sibling"]].compactMap { $0 })

    await Self.tick(coordinator, fixture: fixture, episodeID: "episode", currentTime: 120, isFinished: true)

    let savedAfter = try await fixture.database.readAsync { db in
      try Int64.fetchAll(db, sql: "SELECT rssEpisodeId FROM rssSavedShelfEntry ORDER BY id")
    }
    #expect(savedAfter == [fixture.episodeIDs["sibling"]].compactMap { $0 })
  }

  /// Pausing lets iOS suspend the app within seconds, so the position the final tick wrote is
  /// handed to cloud sync at once rather than left for a debounce that may never run.
  @Test func aPauseOrCloseTellsCloudSyncThePositionHasSettled() async throws {
    let fixture = try await Self.makeFixture(episodes: [Self.episode(identityKey: "episode")])
    let observer = RSSPlaybackFixtures.RSSSettleRecorder()
    let coordinator = Self.makeCoordinator(fixture: fixture, settleObserver: observer)

    await coordinator.notifyImmediateSyncTrigger(.seekCompleted)
    await coordinator.notifyImmediateSyncTrigger(.itemSwitching)
    await coordinator.notifyImmediateSyncTrigger(.backgrounded)
    await coordinator.notifyImmediateSyncTrigger(.catchUp)
    #expect(observer.count == 0, "only a pause or a close ends a listen")

    await coordinator.notifyImmediateSyncTrigger(.paused)
    await coordinator.notifyImmediateSyncTrigger(.closing)
    #expect(observer.count == 2)
  }

  // MARK: - Save throttle

  /// A stream that has started playing and has had its first tick saved at 10 s, with a second
  /// tick at 12 s held in memory, as an ordinary listen looks between checkpoints.
  struct HeldTick {
    let fixture: Fixture
    let episodeRowID: Int64
    let coordinator: RSSPlaybackCoordinator
    let clock: FakeSyncClock
    let stateStore: RSSEpisodeStateStore

    func position() async throws -> Double? {
      try await stateStore.fetchState(episodeId: episodeRowID)?.position
    }

    func tick(_ currentTime: Double, isFinished: Bool = false, isSeek: Bool = false) async {
      await coordinator.recordProgressTick(
        itemID: fixture.itemID, episodeID: "episode", currentTime: currentTime, listenedDelta: 0.5,
        isFinished: isFinished, isSeek: isSeek)
    }
  }

  static func makeHeldTick(
    episodes: [RSSEpisodeUpsert] = [Self.episode(identityKey: "episode")],
    deletions: RSSPlaybackFixtures.RSSFinishedDeletionRecorder? = nil,
    settleObserver: (any PodcastPlaybackSettleObserving)? = nil
  ) async throws -> HeldTick {
    let fixture = try await Self.makeFixture(episodes: episodes)
    let clock = FakeSyncClock(now: Self.date(100))
    let coordinator = Self.makeCoordinator(
      fixture: fixture,
      downloadPreferences: FakeDownloadPreferences(deleteWhenFinished: deletions != nil),
      requestFinishedDownloadDeletion: { await deletions?.record(itemID: $0, episodeID: $1) },
      settleObserver: settleObserver,
      now: { clock.now() })
    let held = HeldTick(
      fixture: fixture, episodeRowID: try #require(fixture.episodeIDs["episode"]),
      coordinator: coordinator, clock: clock,
      stateStore: RSSEpisodeStateStore(database: fixture.database))
    _ = try await coordinator.startSession(itemID: fixture.itemID, episodeID: "episode")
    await coordinator.notifyPlaybackPhase(.playing)
    await held.tick(10)
    clock.advance(by: 2)
    await held.tick(12)
    #expect(try await held.position() == 10, "the first tick of a stream saves; the next is held")
    return held
  }

  /// The show page, Home and the mini-player all observe this row, so a save per 0.5 s tick
  /// rebuilt them twice a second. One durable write per interval is the ABS rule.
  @Test func playingTicksSaveOncePerInterval() async throws {
    let held = try await Self.makeHeldTick()

    for step in 1...25 {
      held.clock.advance(by: 0.5)
      await held.tick(12 + Double(step) * 0.5)
    }
    #expect(try await held.position() == 10, "14.5 s after the first save")
    held.clock.advance(by: 0.5)
    await held.tick(25.5)

    let state = try await held.stateStore.fetchState(episodeId: held.episodeRowID)
    #expect(state?.position == 25.5)
    #expect(state?.localSequence == 2)
    #expect(state?.updatedAt == Self.date(115))
  }

  @Test func aSeekWhilePlayingSavesTheHeldTickAndThenTheSeek() async throws {
    let held = try await Self.makeHeldTick()

    held.clock.advance(by: 1)
    await held.tick(300, isSeek: true)

    let state = try await held.stateStore.fetchState(episodeId: held.episodeRowID)
    #expect(state?.position == 300)
    #expect(state?.localSequence == 3)
  }

  @Test func leavingPlayingSavesTheHeldTickAndEveryTickAfter() async throws {
    let held = try await Self.makeHeldTick()

    await held.coordinator.notifyPlaybackPhase(.paused)
    #expect(try await held.position() == 12)

    held.clock.advance(by: 0.5)
    await held.tick(12.2)
    #expect(try await held.position() == 12.2)
  }

  enum Teardown: CaseIterable, Sendable {
    case closing, paused, stop, background, logout, restart
  }

  /// Every path that ends or suspends a listen must leave the held tick durable: these are the
  /// moments iOS may suspend the app, or the router may hand the next start to another child.
  @Test(arguments: Teardown.allCases)
  func everyTeardownSavesTheHeldTick(_ teardown: Teardown) async throws {
    let held = try await Self.makeHeldTick()
    let coordinator = held.coordinator

    switch teardown {
    case .closing: await coordinator.notifyImmediateSyncTrigger(.closing)
    case .paused: await coordinator.notifyImmediateSyncTrigger(.paused)
    case .stop: try await coordinator.stopSession()
    case .background: await coordinator.handleAppBackgrounded()
    case .logout: await coordinator.quiesceForLogout()
    case .restart:
      _ = try await coordinator.startSession(itemID: held.fixture.itemID, episodeID: "episode")
    }

    #expect(try await held.position() == 12)
  }

  /// `PlaybackModel.stop()` records the final position as an ordinary tick and then closes. The
  /// throttle may hold that tick, so the close must save it before cloud sync is told to send.
  @Test func theStopPathsFinalTickIsDurableBeforeCloudSyncIsTold() async throws {
    let settled = RSSPlaybackFixtures.RSSSettlePositionRecorder()
    let held = try await Self.makeHeldTick(settleObserver: settled)
    settled.watch(database: held.fixture.database, episodeRowID: held.episodeRowID)

    held.clock.advance(by: 0.4)
    await held.tick(12.4)
    await held.coordinator.notifyImmediateSyncTrigger(.closing)
    try await held.coordinator.stopSession()

    #expect(try await held.position() == 12.4)
    #expect(settled.positions == [12.4])
  }

  @Test func finishingWhilePlayingSavesAtOnceAndDeletesOnce() async throws {
    let deletions = RSSPlaybackFixtures.RSSFinishedDeletionRecorder()
    let held = try await Self.makeHeldTick(deletions: deletions)

    held.clock.advance(by: 0.5)
    await held.tick(120, isFinished: true)

    let state = try await held.stateStore.fetchState(episodeId: held.episodeRowID)
    #expect(state?.position == 120)
    #expect(state?.finished == true)
    #expect(
      await deletions.values == [
        RSSPlaybackFixtures.RSSFinishedDeletionIdentity(itemID: held.fixture.itemID, episodeID: "episode")
      ])
  }
}
