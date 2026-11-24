import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

extension PlaybackModelTests {
  // MARK: - Exact states and copy (preparing/buffering/playing/paused/seeking/error/ended)

  struct PhaseFixture: Sendable {
    let playerPhase: PlayerPhase
    let displayPhase: PlaybackModel.Phase
    let copy: String
  }

  nonisolated static let requiredPhaseFixtures: [PhaseFixture] = [
    PhaseFixture(playerPhase: .preparing, displayPhase: .preparing, copy: "Loading…"),
    PhaseFixture(playerPhase: .buffering, displayPhase: .buffering, copy: "Buffering…"),
    PhaseFixture(playerPhase: .stalled, displayPhase: .stalled, copy: "Playback stopped"),
    PhaseFixture(playerPhase: .playing, displayPhase: .playing, copy: "Playing"),
    PhaseFixture(playerPhase: .paused, displayPhase: .paused, copy: "Paused"),
    PhaseFixture(playerPhase: .seeking, displayPhase: .seeking, copy: "Seeking…"),
    PhaseFixture(
      playerPhase: .failed(AudioEngineFailure(isRecoverable: true, message: "transient")),
      displayPhase: .recoverableError, copy: "Playback hit a snag. Tap to retry."),
    PhaseFixture(playerPhase: .ended, displayPhase: .ended, copy: "Finished"),
  ]

  @Test(arguments: PlaybackModelTests.requiredPhaseFixtures)
  func everyRequiredPhaseMapsToItsExactDisplayPhaseAndCopy(fixture: PhaseFixture) async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: fixture.playerPhase, currentTime: 1, listenedDelta: 0))

    // `handle(progressEvent:)` assigns `phase` before recording the tick, so once the tick is on
    // the record the reads below see the mapped phase.
    await sync.waitForCalls { Self.tickCalls($0).isEmpty == false }

    #expect(model.phase == fixture.displayPhase)
    #expect(model.phase.copyText == fixture.copy)
  }

  @Test func anUnrecoverableFailureMapsToItsOwnDistinctPhase() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .failed(AudioEngineFailure(isRecoverable: false, message: "fatal")),
        currentTime: 1, listenedDelta: 0))

    await sync.waitForCalls { Self.tickCalls($0).isEmpty == false }
    #expect(model.phase == .unrecoverableError)
  }

  @Test func aStalledPhaseUsesBufferingCadenceWithoutBufferingCopy() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    let phaseCallsBefore = sync.notifyPlaybackPhaseCalls
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .stalled, currentTime: 1, listenedDelta: 0))

    await sync.waitForCalls {
      Self.cadencePhaseCalls($0).count > phaseCallsBefore.count
    }

    #expect(model.phase == .stalled)
    #expect(model.phase.copyText == "Playback stopped")
    #expect(Array(sync.notifyPlaybackPhaseCalls.dropFirst(phaseCallsBefore.count)) == [.buffering])
  }

  @Test func aStalledTickReachesTheSyncBoundaryWithTheLastKnownPosition() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .playing, currentTime: 84, listenedDelta: 4))
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "item-1", phase: .buffering, currentTime: 84, listenedDelta: 0))
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 3, itemId: "item-1", phase: .stalled, currentTime: 84, listenedDelta: 0))

    await sync.waitForCalls { Self.tickCalls($0).count >= 3 }
    let ticks = Self.tickCalls(sync.calls)
    #expect(ticks.last?.currentTime == 84)
    #expect(ticks.last?.itemID == "item-1")
  }

  @Test func reachabilityProbeFiresOnlyWhenEnteringStalled() async {
    let probe = ReachabilityProbeCounter()
    let (model, player, sync, _, _) = await Self.makeStartedModel(requestReachabilityProbe: {
      probe.fire()
    })
    _ = model

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .buffering, currentTime: 10, listenedDelta: 0))
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "item-1", phase: .playing, currentTime: 10, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).count >= 2 }
    #expect(probe.count == 0)

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 3, itemId: "item-1", phase: .stalled, currentTime: 10, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).count >= 3 }
    #expect(probe.count == 1)

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 4, itemId: "item-1", phase: .stalled, currentTime: 10, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).count >= 4 }
    #expect(probe.count == 1)
  }

  @Test func rssPlaybackNeverProbesABSReachability() async throws {
    let clock = FakePlaybackBufferingClock()
    let probe = ReachabilityProbeCounter()
    let (model, player, sync, _, _) = Self.makeModel(
      { probe.fire() }, bufferingClock: clock)
    let rssItemID = try #require(PodcastSourceIdentity.rss(feedId: 42)).itemId
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .streaming)))
    await model.start(itemID: rssItemID)

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: rssItemID, phase: .buffering, currentTime: 10, listenedDelta: 0))
    await waitUntil { model.phase == .buffering && clock.pendingSleepCount == 1 }
    await clock.advance()
    await Task.yield()
    #expect(probe.count == 0)

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: rssItemID, phase: .stalled, currentTime: 10, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).count >= 2 }
    #expect(probe.count == 0)
  }

  @Test func reachabilityRecoveryNeverInitiatesPlayback() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    player.isPlaybackIntended = true
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .stalled, currentTime: 12, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).contains { $0.currentTime == 12 } }

    let startsBefore = sync.calls.filter {
      if case .startSession = $0 { return true }
      return false
    }.count
    let intentsBefore = player.intents
    let monitor = Self.makeReachabilityMonitor()
    let connectivity = ConnectivityModel(monitor: monitor)

    await monitor.receive(probeOutcome: .didNotReach)
    #expect(
      await waitUntil {
        if case .unreachable = connectivity.reachability { return true }
        return false
      })
    await monitor.receive(probeOutcome: .reached)
    #expect(await waitUntil { connectivity.reachability == .reachable })

    #expect(model.phase == .stalled)
    #expect(
      sync.calls.filter {
        if case .startSession = $0 { return true }
        return false
      }.count == startsBefore)
    #expect(player.intents == intentsBefore)
  }

  @Test func makePlayerItemMapsStreamingAndLocalPreparedSources() async throws {
    let (streamingModel, streamingPlayer, streamingSync, _, _) = Self.makeModel()
    streamingSync.stubStartSession(
      .success(Self.preparedPlayback(startPosition: 0, source: .streaming)))
    await streamingModel.start(itemID: "item-1")

    let streamingItem = try #require(Self.loadedItems(from: streamingPlayer.intents).first)
    #expect(streamingItem.isStreaming)

    let (localModel, localPlayer, localSync, _, _) = Self.makeModel()
    localSync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .local)))
    await localModel.start(itemID: "item-1")

    let localItem = try #require(Self.loadedItems(from: localPlayer.intents).first)
    #expect(localItem.isStreaming == false)
    #expect(localModel.isStreamingSource == false)
  }

  @Test func makePlayerItemKeepsChapterlessEpisodeOutOfChapterMetadata() throws {
    let prepared = Self.preparedPlayback(
      itemID: "rss:1", episodeID: "episode-1", startPosition: 0, chapters: [],
      source: .streaming)

    let item = try PlaybackModel.makePlayerItem(itemID: prepared.itemID, prepared: prepared)

    #expect(item.episodeID == "episode-1")
    #expect(item.chapters.chapters.isEmpty)
  }

  @Test func streamingSourceProjectionSurvivesOrdinaryPhaseFlapping() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .streaming)))
    await model.start(itemID: "item-1")

    let phases: [(PlayerPhase, PlaybackModel.Phase)] = [
      (.playing, .playing),
      (.buffering, .buffering),
      (.paused, .paused),
      (.playing, .playing),
    ]
    for (index, phase) in phases.enumerated() {
      player.pushProgress(
        PlaybackProgressEvent(
          sequence: index + 1, itemId: "item-1", phase: phase.0,
          currentTime: Double(index), listenedDelta: 0))
      await Self.waitForDisplayState(model) { $0.phase == phase.1 }
      #expect(model.isStreamingSource, "phase changes must not change the loaded source kind")
    }
  }

  @Test func replacingAStreamWithALocalPreparationClearsTheStreamingSourceProjection() async {
    let (model, _, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-a", startPosition: 0, source: .streaming)))
    await model.start(itemID: "item-a")
    #expect(model.isStreamingSource)

    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-b", startPosition: 0, source: .local)))
    await model.start(itemID: "item-b")

    #expect(model.loadedItemID == "item-b")
    #expect(model.isStreamingSource == false)
  }

  @Test func stoppingPlaybackClearsTheStreamingSourceProjection() async {
    let (model, _, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .streaming)))
    await model.start(itemID: "item-1")

    await model.stop()

    #expect(model.loadedItemID == nil)
    #expect(model.isStreamingSource == false)
  }

  @Test func preparingForLogoutClearsTheStreamingSourceProjection() async {
    let (model, _, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .streaming)))
    await model.start(itemID: "item-1")

    await model.prepareForLogout()

    #expect(model.loadedItemID == nil)
    #expect(model.isStreamingSource == false)
  }

  @Test func completingPlaybackClearsTheStreamingSourceProjection() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .streaming)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .ended, currentTime: 100, listenedDelta: 0))
    await sync.waitForCalls { $0.contains(.stopSession) }
    await Self.waitForDisplayState(model) { $0.phase == .idle }

    #expect(model.loadedItemID == nil)
    #expect(model.isStreamingSource == false)
  }

  // MARK: - Sustained buffering reachability probe

  @Test func sustainedStreamingBufferingProbesOnceAfterTheClockAdvances() async {
    let clock = FakePlaybackBufferingClock()
    let probe = ReachabilityProbeCounter()
    let (model, player, sync, _, _) = Self.makeModel(
      { probe.fire() }, bufferingClock: clock)
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .streaming)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .buffering, currentTime: 10, listenedDelta: 0))
    await waitUntil { model.phase == .buffering && clock.pendingSleepCount == 1 }
    #expect(probe.count == 0)

    await clock.advance()
    await waitUntil { probe.count == 1 }

    player.pushProgress(
      PlaybackProgressEvent(sequence: 2, itemId: "item-1", phase: .buffering, currentTime: 10, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).count >= 2 }
    #expect(probe.count == 1)
  }

  /// A complete download that pauses to read from disk is not evidence about the server, and the
  /// probe it would otherwise fire is the first step of an affordance that must never appear over
  /// local playback at all.
  @Test func bufferingALocalSourceNeverArmsTheProbe() async {
    let clock = FakePlaybackBufferingClock()
    let probe = ReachabilityProbeCounter()
    let (model, player, sync, _, _) = Self.makeModel(
      { probe.fire() }, bufferingClock: clock)
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .local)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .buffering, currentTime: 10, listenedDelta: 0))
    await waitUntil { model.phase == .buffering }

    #expect(clock.pendingSleepCount == 0)
    #expect(probe.count == 0)
  }

  @Test func bufferingProbeIsCancelledWhenBufferingResolves() async {
    let clock = FakePlaybackBufferingClock()
    let probe = ReachabilityProbeCounter()
    let (model, player, sync, _, _) = Self.makeModel(
      { probe.fire() }, bufferingClock: clock)
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .streaming)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .buffering, currentTime: 10, listenedDelta: 0))
    await waitUntil { model.phase == .buffering && clock.pendingSleepCount == 1 }
    player.pushProgress(
      PlaybackProgressEvent(sequence: 2, itemId: "item-1", phase: .playing, currentTime: 10, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).count >= 2 }
    await waitUntil { model.phase == .playing && clock.pendingSleepCount == 0 }

    player.pushProgress(
      PlaybackProgressEvent(sequence: 3, itemId: "item-1", phase: .buffering, currentTime: 10, listenedDelta: 0))
    await waitUntil { model.phase == .buffering && clock.pendingSleepCount == 1 }
    await clock.advance()
    await waitUntil { probe.count == 1 }
    #expect(probe.count == 1, "the resolved episode's canceled task must not also probe")
  }

  @Test func bufferingProbeIsCancelledWhenPlaybackIsPaused() async {
    let clock = FakePlaybackBufferingClock()
    let probe = ReachabilityProbeCounter()
    let (model, player, sync, _, _) = Self.makeModel(
      { probe.fire() }, bufferingClock: clock)
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .streaming)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .buffering, currentTime: 10, listenedDelta: 0))
    await waitUntil { model.phase == .buffering && clock.pendingSleepCount == 1 }
    player.pushProgress(
      PlaybackProgressEvent(sequence: 2, itemId: "item-1", phase: .paused, currentTime: 10, listenedDelta: 0))
    await sync.waitForCalls { Self.tickCalls($0).count >= 2 }
    await waitUntil { model.phase == .paused && clock.pendingSleepCount == 0 }

    player.pushProgress(
      PlaybackProgressEvent(sequence: 3, itemId: "item-1", phase: .buffering, currentTime: 10, listenedDelta: 0))
    await waitUntil { model.phase == .buffering && clock.pendingSleepCount == 1 }
    await clock.advance()
    await waitUntil { probe.count == 1 }
    #expect(probe.count == 1, "the paused episode's canceled task must not also probe")
  }

  @Test func bufferingProbeIsCancelledWhenTheLoadedItemChanges() async {
    let clock = FakePlaybackBufferingClock()
    let probe = ReachabilityProbeCounter()
    let (model, player, sync, _, _) = Self.makeModel(
      { probe.fire() }, bufferingClock: clock)
    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-a", startPosition: 0, source: .streaming)))
    await model.start(itemID: "item-a")
    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-a", phase: .buffering, currentTime: 10, listenedDelta: 0))
    await waitUntil { model.phase == .buffering && clock.pendingSleepCount == 1 }

    sync.stubStartSession(.success(Self.preparedPlayback(itemID: "item-b", startPosition: 0, source: .local)))
    await model.start(itemID: "item-b")
    #expect(model.loadedItemID == "item-b")
    #expect(model.isStreamingSource == false)
    await waitUntil { clock.pendingSleepCount == 0 }

    clock.resumePending()
    await awaitQuiescence("the cancelled buffering probe to settle", of: { "\(probe.count)" })
    #expect(probe.count == 0, "a canceled buffering episode must not probe after item replacement")
  }

  @Test func bufferingProbeIsCancelledAcrossLogout() async {
    let clock = FakePlaybackBufferingClock()
    let probe = ReachabilityProbeCounter()
    let (model, player, sync, _, _) = Self.makeModel(
      { probe.fire() }, bufferingClock: clock)
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .streaming)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .buffering, currentTime: 10, listenedDelta: 0))
    await waitUntil { model.phase == .buffering && clock.pendingSleepCount == 1 }

    await model.prepareForLogout()
    #expect(model.isQuiescedForLogout)
    #expect(clock.pendingSleepCount == 0)

    #expect(probe.count == 0, "a pre-logout buffering token must never request a probe")
  }
}
