import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

extension PlaybackModelTests {
  // MARK: - Progress events forwarded once, in order, and persisted

  @Test func progressEventsAreForwardedOnceAndInOrder() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .playing, currentTime: 10, listenedDelta: 1))
    player.pushProgress(
      PlaybackProgressEvent(sequence: 2, itemId: "item-1", phase: .playing, currentTime: 20, listenedDelta: 10))
    player.pushProgress(
      PlaybackProgressEvent(sequence: 3, itemId: "item-1", phase: .paused, currentTime: 21, listenedDelta: 1))

    await sync.waitForCalls { Self.tickCalls($0).count >= 3 }

    let ticks = Self.tickCalls(sync.calls)
    #expect(ticks.map(\.currentTime) == [10, 20, 21], "forwarded exactly once each, in the order they occurred")
  }

  /// Display updates must not queue behind the previous event's awaited persistence/network
  /// work, or `phase`/`currentTime` run seconds behind the audio. Display state must reflect an
  /// event while its own `recordProgressTick` is still parked in flight, and sync must still
  /// receive every tick, in order, once it unblocks.
  @Test func displayStateUpdatesWhileTheSyncTickIsStillInFlight() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()

    sync.holdRecordProgressTicks()
    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .playing, currentTime: 10, listenedDelta: 1))
    await Self.waitForDisplayState(model) { $0.phase == .playing && $0.currentTime == 10 }
    // Await the consumer reaching the held call, not the display update: they run on separate
    // tasks, so display state can land before the sync consumer resumes and the parked-count
    // assertion below reads 0. `>= 1` not `== 1`: an overshootable predicate would burn the
    // waiter's full timeout; the monotone form resumes on the first satisfying append.
    await sync.waitForCalls { Self.tickCalls($0).count >= 1 }

    // The first tick is still parked; a second event's display update must land regardless.
    player.pushProgress(
      PlaybackProgressEvent(sequence: 2, itemId: "item-1", phase: .paused, currentTime: 11, listenedDelta: 1))
    await Self.waitForDisplayState(model) { $0.phase == .paused && $0.currentTime == 11 }
    #expect(
      Self.tickCalls(sync.calls).count == 1,
      "the serialized sync consumer must still be parked on the first tick")

    sync.releaseRecordProgressTicks()
    await sync.waitForCalls { Self.tickCalls($0).count >= 2 }
    #expect(
      Self.tickCalls(sync.calls).map(\.currentTime) == [10, 11],
      "sync still receives every tick exactly once, in order")
  }

  @Test("a queued event cannot cross a same-identity generation replacement")
  func queuedSameIdentityEventCannotForwardAfterGenerationReplacement() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    sync.holdRecordProgressTicks()
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .playing, currentTime: 10, listenedDelta: 1))
    await sync.waitForCalls { Self.tickCalls($0).count >= 1 }

    // The second event has entered the display path and is queued behind the held durable tick.
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "item-1", phase: .paused, currentTime: 20, listenedDelta: 1))
    await Self.waitForDisplayState(model) { $0.phase == .paused && $0.currentTime == 20 }

    await model.stop()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    sync.releaseRecordProgressTicks()
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 3, itemId: "item-1", phase: .playing, currentTime: 30, listenedDelta: 1))
    await sync.waitForCalls { Self.tickCalls($0).contains { $0.currentTime == 30 } }

    #expect(
      Self.tickCalls(sync.calls).map(\.currentTime) == [10, 30],
      "the queued generation-N event must not be forwarded into generation N+1")
    #expect(
      sync.calls.contains(.notifyImmediateSyncTrigger(.paused)) == false,
      "a stale queued pause must not drain the replacement session")
    #expect(model.phase == .playing, "the stale event must not replace the new generation's display")
  }

  @Test("a same-identity event observed during replacement preparation stays in the old generation")
  func sameIdentityEventDuringReplacementPreparationIsRejectedAtIngress() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(
      .success(Self.preparedPlayback(startPosition: 0, source: .streaming)))
    await model.start(itemID: "item-1")
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .stalled, currentTime: 10, listenedDelta: 0))
    await Self.waitForDisplayState(model) { $0.phase == .stalled }

    sync.holdStartSession()
    let replacement = Task { await model.start(itemID: "item-1") }
    await sync.waitForCalls {
      $0.filter { if case .startSession = $0 { return true } else { return false } }.count == 2
    }

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "item-1", phase: .paused, currentTime: 20, listenedDelta: 1))
    await waitUntil { model.lastObservedPlayerEventSequence == 2 }
    #expect(model.phase == .preparing)

    sync.releaseStartSession(
      with: .success(Self.preparedPlayback(startPosition: 0, source: .streaming)))
    await replacement.value
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 3, itemId: "item-1", phase: .playing, currentTime: 30, listenedDelta: 1))
    await sync.waitForCalls { Self.tickCalls($0).contains { $0.currentTime == 30 } }

    #expect(Self.tickCalls(sync.calls).map(\.currentTime).contains(20) == false)
    #expect(sync.calls.contains(.notifyImmediateSyncTrigger(.paused)) == false)
    #expect(model.phase == .playing)
    #expect(model.currentTime == 30)
  }

  @Test("a queued event before manual stop cannot affect idle and the bridge remains reusable")
  func queuedPreStopEventCannotAffectIdleAndLaterStartStillWorks() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    sync.holdRecordProgressTicks()
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .playing, currentTime: 10, listenedDelta: 1))
    await sync.waitForCalls { Self.tickCalls($0).count >= 1 }
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "item-1", phase: .paused, currentTime: 20, listenedDelta: 1))
    await Self.waitForDisplayState(model) { $0.phase == .paused && $0.currentTime == 20 }

    await model.stop()
    #expect(model.phase == .idle)
    #expect(model.activeItemID == nil)
    #expect(model.loadedItemID == nil)

    sync.releaseRecordProgressTicks()
    #expect(model.phase == .idle, "a pre-stop event must not mutate the idle display")

    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 3, itemId: "item-1", phase: .playing, currentTime: 30, listenedDelta: 1))
    await sync.waitForCalls { Self.tickCalls($0).contains { $0.currentTime == 30 } }

    #expect(Self.tickCalls(sync.calls).map(\.currentTime) == [10, 30])
    #expect(model.phase == .playing)
    #expect(model.currentTime == 30)
  }

  @Test("logout terminally stops suspended and queued progress")
  func logoutStopsSuspendedAndQueuedProgressWithoutResurrection() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await model.start(itemID: "item-1")

    sync.holdRecordProgressTicks()
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .playing, currentTime: 10, listenedDelta: 1))
    await sync.waitForCalls { Self.tickCalls($0).count >= 1 }
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 2, itemId: "item-1", phase: .ended, currentTime: 20, listenedDelta: 1))
    await Self.waitForDisplayState(model) { $0.phase == .ended && $0.currentTime == 20 }

    await model.prepareForLogout()
    #expect(model.isQuiescedForLogout)
    #expect(model.phase == .idle)
    #expect(model.activeItemID == nil)
    #expect(model.loadedItemID == nil)

    sync.releaseRecordProgressTicks()
    await model.waitForEventBridgeTermination()

    #expect(
      Self.tickCalls(sync.calls).map(\.currentTime) == [10],
      "logout must reject the queued event after the in-flight call is released")
    #expect(
      sync.calls.contains(.notifyImmediateSyncTrigger(.closing)) == false,
      "logout must not let a stale ended event close or advance playback")
    #expect(model.phase == .idle)
    #expect(model.currentTime == 20, "no post-logout event may resurrect observable state")
  }

  @Test("model teardown cancels held forwarding and buffering work")
  func modelTeardownCancelsHeldForwardingAndBufferingWork() async {
    let player = FakePlaybackControlling()
    let sync = FakePlaybackSyncing()
    let account = FakeAccountLifecycle()
    let appLifecycle = FakeAppLifecycle()
    let clock = FakePlaybackBufferingClock()
    let probe = ReachabilityProbeCounter()
    weak var weakModel: PlaybackModel?

    do {
      let model = PlaybackModel(
        sync: sync, player: player, account: account, appLifecycle: appLifecycle,
        requestReachabilityProbe: { probe.fire() }, bufferingClock: clock)
      weakModel = model
      sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .streaming)))
      await model.start(itemID: "item-1")
      sync.holdRecordProgressTicks()
      player.pushProgress(
        PlaybackProgressEvent(
          sequence: 1, itemId: "item-1", phase: .buffering, currentTime: 10, listenedDelta: 1))
      await sync.waitForCalls { Self.tickCalls($0).count >= 1 }
      await waitUntil { clock.pendingSleepCount == 1 }
    }

    #expect(weakModel == nil, "the bridge tasks must not retain a released model")
    #expect(clock.pendingSleepCount == 0, "bridge deinit must cancel the buffering sleep")
    #expect(probe.count == 0)
    sync.releaseRecordProgressTicks()
    #expect(Self.tickCalls(sync.calls).map(\.currentTime) == [10])
  }

  @Test("held completion does not retain the model through bridge forwarding")
  func heldCompletionDoesNotRetainModel() async {
    let player = FakePlaybackControlling()
    let sync = FakePlaybackSyncing()
    weak var weakModel: PlaybackModel?

    do {
      let model = PlaybackModel(
        sync: sync, player: player, account: FakeAccountLifecycle(),
        appLifecycle: FakeAppLifecycle())
      weakModel = model
      sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
      await model.start(itemID: "item-1")
      sync.holdStopSession()
      player.pushProgress(
        PlaybackProgressEvent(
          sequence: 1, itemId: "item-1", phase: .ended, currentTime: 100,
          listenedDelta: 1))
      await sync.waitForCalls { $0.contains(.stopSession) }
    }

    #expect(weakModel == nil, "a cancellation-insensitive completion close must not form a cycle")
    sync.releaseStopSession()
  }

  @Test func playingPhaseNotificationIsNotBlockedByItsHeldProgressTick() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model

    sync.holdRecordProgressTicks()
    defer { sync.releaseRecordProgressTicks() }
    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .playing, currentTime: 10, listenedDelta: 1))

    await sync.waitForCalls { Self.tickCalls($0).count >= 1 }
    let phaseReachedWhileTickWasHeld = await waitUntil {
      sync.notifyPlaybackPhaseCalls.contains(.playing)
    }

    #expect(
      phaseReachedWhileTickWasHeld,
      "the playing cadence phase must be notified before its progress tick completes")
  }

  @Test func pausedPhaseNotificationIsNotBlockedByItsHeldProgressTick() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model

    sync.holdRecordProgressTicks()
    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .playing, currentTime: 10, listenedDelta: 1))
    await sync.waitForCalls { Self.tickCalls($0).count >= 1 }
    #expect(await waitUntil { sync.notifyPlaybackPhaseCalls.contains(.playing) })

    // The forwarding pump is ordered: let the playing event finish, then hold the paused event's
    // tick as well before checking that its eager phase notification gets through.
    sync.releaseRecordProgressTicks()
    sync.holdRecordProgressTicks()
    defer { sync.releaseRecordProgressTicks() }
    player.pushProgress(
      PlaybackProgressEvent(sequence: 2, itemId: "item-1", phase: .paused, currentTime: 11, listenedDelta: 1))

    await sync.waitForCalls { Self.tickCalls($0).count >= 2 }
    let phaseReachedWhileTickWasHeld = await waitUntil {
      sync.notifyPlaybackPhaseCalls.contains(.paused)
    }

    #expect(
      phaseReachedWhileTickWasHeld,
      "the paused cadence phase must be notified before its progress tick completes")
  }

  @Test func pauseDrainIsRequestedOnlyAfterItsFinalProgressTickPersists() async throws {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .playing, currentTime: 10, listenedDelta: 1))
    player.pushProgress(
      PlaybackProgressEvent(sequence: 2, itemId: "item-1", phase: .paused, currentTime: 11, listenedDelta: 1))

    await sync.waitForCalls { calls in
      calls.contains(.notifyImmediateSyncTrigger(.paused))
    }

    let pausedPhaseIndex = try #require(
      sync.calls.firstIndex(of: .notifyPlaybackPhase(.paused)))
    let finalTickIndex = try #require(
      sync.calls.firstIndex(
        of: .recordProgressTick(
          itemID: "item-1", currentTime: 11, listenedDelta: 1, isFinished: false, isSeek: false)))
    let pauseDrainIndex = try #require(
      sync.calls.firstIndex(of: .notifyImmediateSyncTrigger(.paused)))

    #expect(pausedPhaseIndex < finalTickIndex, "pause must still cancel cadence eagerly")
    #expect(finalTickIndex < pauseDrainIndex, "the drain must see the pause event's final position and delta")
  }

  @Test func sleepTimerExpiryIsForwardedAfterTheFinalTickWithoutRepeatingCadencePhase() async throws {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .local)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .paused, currentTime: 10, listenedDelta: 0,
        sleepTimerExpiry: .expired))
    await sync.waitForCalls { calls in
      calls.contains(.sleepTimerExpiry(itemID: "item-1", episodeID: nil))
    }

    let tickIndex = try #require(
      sync.calls.firstIndex(
        of: .recordProgressTick(
          itemID: "item-1", currentTime: 10, listenedDelta: 0, isFinished: false, isSeek: false)))
    let expiryIndex = try #require(
      sync.calls.firstIndex(of: .sleepTimerExpiry(itemID: "item-1", episodeID: nil)))
    #expect(tickIndex < expiryIndex)
    #expect(sync.notifyPlaybackPhaseCalls.filter { $0 == .paused }.count == 1)
    #expect(model.phase == .paused)
    #expect(model.isStreamingSource == false)
  }

  @Test func playAfterAClosedLocalSleepSessionPreparesAFreshSession() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .local)))
    await model.start(itemID: "item-1")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .paused, currentTime: 10, listenedDelta: 0,
        sleepTimerExpiry: .expired))
    await sync.waitForCalls { calls in
      calls.contains(.sleepTimerExpiry(itemID: "item-1", episodeID: nil))
    }

    model.togglePlayPause()
    await sync.waitForCalls { calls in
      calls.filter { if case .startSession = $0 { return true } else { return false } }.count == 2
    }
    await waitUntil {
      player.intents.filter { if case .load = $0 { return true } else { return false } }.count == 2
    }

    #expect(player.intents.filter { if case .load = $0 { return true } else { return false } }.count == 2)
  }

  @Test func aLockScreenPlayConsultsTheLatchAndOpensAFreshSessionInsteadOfABareIntent() async {
    let (model, player, sync, _, _) = Self.makeModel()
    sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0, source: .local)))
    await model.start(itemID: "item-1")

    #expect(
      model.resumeThroughFreshLocalSessionIfLatched() == false,
      "no expiry has happened - the remote command should send its bare intent")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 1, itemId: "item-1", phase: .paused, currentTime: 10, listenedDelta: 0,
        sleepTimerExpiry: .expired))
    await sync.waitForCalls { calls in
      calls.contains(.sleepTimerExpiry(itemID: "item-1", episodeID: nil))
    }

    #expect(model.resumeThroughFreshLocalSessionIfLatched() == true)
    await sync.waitForCalls { calls in
      calls.filter { if case .startSession = $0 { return true } else { return false } }.count == 2
    }
    #expect(player.intents.filter { if case .load = $0 { return true } else { return false } }.count == 2)
  }

  @Test func aPlayingTickIsRecordedAsAnOrdinaryNonSeekNonFinishedTick() async throws {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .playing, currentTime: 10, listenedDelta: 1))

    await sync.waitForCalls { Self.tickCalls($0).isEmpty == false }
    let tick = try #require(Self.tickCalls(sync.calls).first)
    #expect(tick.itemID == "item-1")
    #expect(tick.listenedDelta == 1)
    #expect(tick.isFinished == false)
    #expect(tick.isSeek == false)
  }

  @Test func aSeekingTickIsMarkedAsASeek() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .seeking, currentTime: 50, listenedDelta: 0))

    await sync.waitForCalls { Self.tickCalls($0).isEmpty == false }
    #expect(Self.tickCalls(sync.calls).first?.isSeek == true)
  }

  // MARK: - Cadence phase reporting is de-duplicated

  @Test func repeatedTicksOfTheSameCoarsePhaseReportItOnlyOnce() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model
    let phaseCallsBefore = sync.notifyPlaybackPhaseCalls

    for time in [10.0, 11.0, 12.0] {
      player.pushProgress(
        PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .playing, currentTime: time, listenedDelta: 1))
    }
    // Correct de-duplication means the repeated ticks leave no observable call, so a trailing
    // `.paused` tick serves as the drain marker: events are handled strictly in order, so its
    // `.paused` cadence report can only land after all three `.playing` ticks were fully
    // handled, which makes the assertion below conclusive about what those ticks reported.
    player.pushProgress(
      PlaybackProgressEvent(sequence: 2, itemId: "item-1", phase: .paused, currentTime: 13, listenedDelta: 1))

    await sync.waitForCalls { Self.cadencePhaseCalls($0).contains(.paused) }
    #expect(
      Array(sync.notifyPlaybackPhaseCalls.dropFirst(phaseCallsBefore.count)) == [.playing, .paused],
      "must not reschedule cadence on every position tick")
  }

  @Test func eachDistinctCoarsePhaseTransitionIsReported() async {
    let (model, player, sync, _, _) = await Self.makeStartedModel()
    _ = model
    let phaseCallsBefore = sync.notifyPlaybackPhaseCalls

    player.pushProgress(
      PlaybackProgressEvent(sequence: 1, itemId: "item-1", phase: .playing, currentTime: 1, listenedDelta: 1))
    player.pushProgress(
      PlaybackProgressEvent(sequence: 2, itemId: "item-1", phase: .paused, currentTime: 2, listenedDelta: 1))
    player.pushProgress(
      PlaybackProgressEvent(sequence: 3, itemId: "item-1", phase: .playing, currentTime: 3, listenedDelta: 1))

    await sync.waitForCalls {
      Self.cadencePhaseCalls($0).count >= phaseCallsBefore.count + 3
    }
    #expect(
      Array(sync.notifyPlaybackPhaseCalls.dropFirst(phaseCallsBefore.count))
        == [.playing, .paused, .playing])
  }
}
