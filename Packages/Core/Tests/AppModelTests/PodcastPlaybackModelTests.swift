import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite(.timeLimit(.minutes(1)))
struct PodcastPlaybackModelTests {
  @MainActor
  @Test("same episode resumes in place while a sibling episode starts a new session")
  func fullEpisodeIdentityControlsResumeAndSwitch() async {
    let (model, _, sync, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))

    await model.start(itemID: "show", episodeID: "episode-a")
    await model.start(itemID: "show", episodeID: "episode-a")
    #expect(
      sync.calls.filter { $0 == .startSession(itemID: "show", episodeID: "episode-a") }.count == 1)

    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-b")))
    await model.start(itemID: "show", episodeID: "episode-b")
    #expect(sync.calls.contains(.startSession(itemID: "show", episodeID: "episode-b")))
    #expect(model.activeEpisodeID == "episode-b")
    #expect(model.loadedEpisodeID == "episode-b")
  }

  @MainActor
  @Test("episodes of one show use the show's one playback override")
  func episodesOfOneShowResolveAgainstTheShowOverride() async {
    let store = FakeItemPlaybackSettingsAccess()
    let coordinator = PlaybackRateCoordinator(
      reading: store,
      writing: store,
      preferences: FakePlaybackPreferences(initialRate: 1.25),
      player: FakePlaybackControlling())
    coordinator.setOverride(1.8, itemID: "show")
    await coordinator.waitForPendingWrites()

    let (model, player, sync, _) = Self.makeModel(rateCoordinator: coordinator)
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")

    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-b")))
    await model.start(itemID: "show", episodeID: "episode-b")

    #expect(Self.loadRates(player.intents) == [1.8, 1.8])
  }

  @MainActor
  @Test("a successful episode preparation bookmarks the full episode identity")
  func episodeBookmarkKeepsIdentity() async {
    let sync = FakePlaybackSyncing()
    let bookmarks = FakePlaybackBookmarkStoring()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    let model = PlaybackModelHarness(sync: sync, bookmarkStore: bookmarks).model

    await model.start(itemID: "show", episodeID: "episode-a")

    #expect(
      bookmarks.setBookmarkIdentityCalls == [
        .init(itemID: "show", episodeID: "episode-a")
      ])
  }

  @MainActor
  @Test("a cold retained podcast bookmark resumes the same episode at its saved position")
  func retainedEpisodeResumeKeepsIdentity() async {
    let sync = FakePlaybackSyncing()
    let bookmarks = FakePlaybackBookmarkStoring()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    let playback = PlaybackModelHarness(sync: sync, bookmarkStore: bookmarks)
    let model = playback.model
    let player = playback.player
    let bookmark = PlaybackBookmark(
      serverItemId: "show", episodeID: "episode-a", episodeTitle: "Episode A",
      showTitle: "Show", title: "Episode A", author: nil, durationSeconds: 100,
      positionSeconds: 42, isFinished: false)
    bookmarks.push(bookmark)
    await waitUntil { model.displayedItem == bookmark }

    await model.play(itemID: "show")

    #expect(sync.calls.contains(.startSession(itemID: "show", episodeID: "episode-a")))
    #expect(player.intents.last == .seek(toGlobalOffset: 42))
  }

  @MainActor
  @Test("progress forwards the loaded episode identity and rejects a stale sibling tick")
  func progressUsesFullEpisodeIdentity() async {
    let (model, player, sync, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "show", episodeID: "episode-a", phase: .playing,
        currentTime: 10, listenedDelta: 1))
    await waitUntil { sync.progressIdentityCalls.isEmpty == false }
    #expect(
      sync.progressIdentityCalls == [
        .init(itemID: "show", episodeID: "episode-a")
      ])

    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-b")))
    await model.start(itemID: "show", episodeID: "episode-b")
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "show", episodeID: "episode-a", phase: .playing,
        currentTime: 20, listenedDelta: 1))
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 3, itemId: "show", episodeID: "episode-b", phase: .playing,
        currentTime: 21, listenedDelta: 1))
    await waitUntil {
      sync.progressIdentityCalls.last?.episodeID == "episode-b"
    }
    #expect(
      sync.progressIdentityCalls
        == [.init(itemID: "show", episodeID: "episode-a"), .init(itemID: "show", episodeID: "episode-b")])
  }

  @MainActor
  @Test("completion closes before popping and starts exactly the returned queue head")
  func completionClosesPopsAndAdvancesOnce() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")

    await queue.configure(
      rows: [try Self.queueRow(episodeID: "episode-b")], syncCalls: { sync.calls })
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-b")))
    let ended = PlaybackProgressEvent(
      sequence: 1, itemId: "show", episodeID: "episode-a", phase: .ended,
      currentTime: 100, listenedDelta: 1)
    player.pushProgress(ended)

    await sync.waitForCalls {
      $0.contains(.startSession(itemID: "show", episodeID: "episode-b"))
    }
    #expect(await queue.peekCount == 1)
    #expect(await queue.sawCloseBeforePeek)

    player.pushProgress(ended)
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "show", episodeID: "episode-b", phase: .playing,
        currentTime: 1, listenedDelta: 1))
    await waitUntil { sync.progressIdentityCalls.last?.episodeID == "episode-b" }
    #expect(await queue.peekCount == 1)
  }

  @MainActor
  @Test("an empty queue closes and stops without inventing a next episode")
  func emptyQueueStops() async {
    let (model, player, sync, queue) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")
    await queue.configure(rows: [])

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "show", episodeID: "episode-a", phase: .ended,
        currentTime: 100, listenedDelta: 1))
    await queue.waitForPeek()

    #expect(model.phase == .idle)
    #expect(model.activeItemID == nil)
    #expect(
      sync.calls.filter {
        if case .startSession = $0 { return true }
        return false
      }.count == 1)
  }

  @MainActor
  @Test("failed preparation leaves the next row queued and reports a recoverable error")
  func failedAdvanceKeepsNextRow() async throws {
    let (model, player, sync, queue) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")
    let queuedEpisode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode-b"))
    await queue.configure(rows: [try Self.queueRow(episodeID: "episode-b")])
    sync.stubStartSession(.failure(FixtureFailure.failed))

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "show", episodeID: "episode-a", phase: .ended,
        currentTime: 100, listenedDelta: 1))
    await waitUntil { model.startFailureMessage != nil }

    #expect(
      await queue.identities == [queuedEpisode],
      "a failed preparation leaves the next row exactly where it was")
    #expect(model.phase == .recoverableError)
    #expect(model.activeItemID == "show")
    #expect(model.activeEpisodeID == "episode-b")
    #expect(model.startFailureMessage == PlaybackCopy.genericStartFailure)
  }

  @MainActor
  @Test("a close failure never pops the completed queue row")
  func closeFailureDoesNotPop() async {
    let (model, player, sync, queue) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")
    sync.stubStopSession(throwing: FixtureFailure.failed)

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "show", episodeID: "episode-a", phase: .ended,
        currentTime: 100, listenedDelta: 1))
    await waitUntil { model.phase == .recoverableError }

    #expect(await queue.peekCount == 0)
    #expect(model.startFailureMessage == PlaybackCopy.genericStartFailure)
  }

  @MainActor
  @Test("manual stop invalidates an ended event whose persistence is still in flight")
  func manualStopCancelsPendingAdvance() async {
    let (model, player, sync, queue) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")
    sync.holdRecordProgressTicks()
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "show", episodeID: "episode-a", phase: .ended,
        currentTime: 100, listenedDelta: 1))
    await sync.waitForCalls {
      $0.contains {
        if case .recordProgressTick = $0 { return true }
        return false
      }
    }

    await model.stop()
    sync.releaseRecordProgressTicks()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-b")))
    await model.start(itemID: "show", episodeID: "episode-b")
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "show", episodeID: "episode-b", phase: .playing,
        currentTime: 1, listenedDelta: 0))
    await waitUntil { sync.progressIdentityCalls.last?.episodeID == "episode-b" }
    #expect(await queue.peekCount == 0)
  }

  @MainActor
  @Test("a sibling start cannot be closed by an older ended event still persisting")
  func siblingStartCancelsPendingAdvance() async {
    let (model, player, sync, queue) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")
    sync.holdRecordProgressTicks()
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "show", episodeID: "episode-a", phase: .ended,
        currentTime: 100, listenedDelta: 1))
    await sync.waitForCalls {
      $0.contains {
        if case .recordProgressTick = $0 { return true }
        return false
      }
    }

    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-b")))
    await model.start(itemID: "show", episodeID: "episode-b")
    sync.releaseRecordProgressTicks()
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "show", episodeID: "episode-b", phase: .playing,
        currentTime: 1, listenedDelta: 1))
    await waitUntil { sync.progressIdentityCalls.last?.episodeID == "episode-b" }

    #expect(await queue.peekCount == 0)
    #expect(sync.calls.filter { $0 == .stopSession }.isEmpty)
    #expect(model.loadedEpisodeID == "episode-b")
  }

  @MainActor
  @Test("sibling preparation disables old controls and resets cadence and seek state")
  func siblingSwitchResetsTransientState() async {
    let (model, player, sync, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "show", episodeID: "episode-a", phase: .seeking,
        currentTime: 10, listenedDelta: 0))
    await waitUntil { sync.progressIdentityCalls.isEmpty == false }

    sync.holdStartSession()
    let siblingStart = Task { await model.start(itemID: "show", episodeID: "episode-b") }
    await sync.waitForCalls {
      $0.contains(.startSession(itemID: "show", episodeID: "episode-b"))
    }
    let intentCount = player.intents.count
    model.togglePlayPause(itemID: "show")
    model.seek(itemID: "show", toGlobalOffset: 50)
    #expect(player.intents.count == intentCount)

    sync.releaseStartSession(with: .success(Self.prepared(episodeID: "episode-b")))
    await siblingStart.value
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "show", episodeID: "episode-b", phase: .playing,
        currentTime: 1, listenedDelta: 1))
    await waitUntil {
      sync.progressIdentityCalls.last?.episodeID == "episode-b"
        && sync.notifyPlaybackPhaseCalls.last == .playing
    }
    #expect(
      sync.calls.filter { $0 == .notifyImmediateSyncTrigger(.seekCompleted) }.isEmpty)
    #expect(sync.notifyPlaybackPhaseCalls.last == .playing)
  }

  /// The item-scoped `isPlaybackIntended(for:)` answers "this show", which every episode of that
  /// show shares, so a card for episode B would light up as playing while episode A ran. The
  /// episode-scoped overload is what a per-episode play/pause affordance has to read.
  @MainActor
  @Test("episode-scoped playback intent rejects a sibling episode of the same show")
  func episodeScopedIntentRejectsASibling() async {
    let (model, player, sync, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")
    player.isPlaybackIntended = true

    #expect(model.isPlaybackIntended(for: "show", episodeID: "episode-a"))
    #expect(model.isPlaybackIntended(for: "show", episodeID: "episode-b") == false)
    #expect(model.isPlaybackIntended(for: "show", episodeID: nil) == false)
    #expect(model.isPlaybackIntended(for: "other-show", episodeID: "episode-a") == false)

    player.isPlaybackIntended = false
    #expect(model.isPlaybackIntended(for: "show", episodeID: "episode-a") == false)
  }

  /// The card's paused state has to be told apart from "never started": one resumes the prepared
  /// session, the other prepares a new one. `nowPlayingIdentity` cannot make that call: it keeps
  /// answering with the retained bookmark after `stop()`, which would leave the card offering a
  /// Resume that toggles nothing.
  @MainActor
  @Test("a stopped episode is no longer loaded, however it is still retained")
  func aStoppedEpisodeIsNoLongerLoaded() async {
    let (model, _, sync, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")

    #expect(model.isLoaded(itemID: "show", episodeID: "episode-a"))
    #expect(model.isLoaded(itemID: "show", episodeID: "episode-b") == false)
    #expect(model.isLoaded(itemID: "show", episodeID: nil) == false)
    #expect(model.isLoaded(itemID: "other-show", episodeID: "episode-a") == false)

    await model.stop()
    #expect(model.isLoaded(itemID: "show", episodeID: "episode-a") == false)
  }

  @MainActor
  @Test("episode-scoped toggle only reaches the player for the loaded episode")
  func episodeScopedToggleOnlyReachesTheLoadedEpisode() async {
    let (model, player, sync, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.prepared(episodeID: "episode-a")))
    await model.start(itemID: "show", episodeID: "episode-a")
    let baseline = player.intents.count

    model.togglePlayPause(itemID: "show", episodeID: "episode-b")
    model.togglePlayPause(itemID: "show", episodeID: nil)
    model.togglePlayPause(itemID: "other-show", episodeID: "episode-a")
    #expect(player.intents.count == baseline)

    model.togglePlayPause(itemID: "show", episodeID: "episode-a")
    #expect(player.intents.count == baseline + 1)
    #expect(player.intents.last == .toggle)
  }

  @MainActor
  private static func makeModel(rateCoordinator: PlaybackRateCoordinator? = nil) -> (
    PlaybackModel, FakePlaybackControlling, FakePlaybackSyncing, RecordingListeningQueue
  ) {
    let queue = RecordingListeningQueue()
    let playback = PlaybackModelHarness(listeningQueue: queue, rateCoordinator: rateCoordinator)
    return (playback.model, playback.player, playback.sync, queue)
  }

  private static func prepared(episodeID: String) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: "show", episodeID: episodeID, startPosition: 0, duration: 100,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 100,
          url: URL(string: "https://example.test/episode.mp3")!,
          mimeType: "audio/mpeg", title: episodeID)
      ],
      chapters: [])
  }

  private static func queueRow(episodeID: String) throws -> ListeningQueueItem {
    let identity = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: episodeID))
    return ListeningQueueItem(
      id: 1, position: 0,
      identity: identity,
      primaryTitle: episodeID, secondaryTitle: "Show", category: .podcast, isTombstone: false)
  }

  private static func loadRates(_ intents: [PlayerIntent]) -> [Double] {
    intents.compactMap { intent in
      if case .load(_, _, let rate, _) = intent { return rate }
      return nil
    }
  }
}

private enum FixtureFailure: Error { case failed }
