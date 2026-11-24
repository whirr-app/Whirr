import Testing

@testable import PlayerCore

/// `PlayerReducer` is pure: every `now` is supplied by the test, so every transition and emitted
/// progress event is deterministic. No AVFoundation, no async, no sleeps.
@Suite struct PlayerStateMachineTests {

  // MARK: - Fixtures

  private static func singleTrackItem(
    id: String = "item-1", episodeID: String? = nil, duration: Double = 100
  ) -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: duration)])
    return PlayerItem(id: id, episodeID: episodeID, timeline: timeline)
  }

  private static func twoTrackItem(id: String = "item-1") -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 60),
      PlaybackTrack(index: 1, duration: 40),
    ])
    return PlayerItem(id: id, timeline: timeline)
  }

  // MARK: - idle -> preparing -> buffering/ready

  @Test func podcastEpisodeIdentitySurvivesLifecycleProgressEvents() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(id: "show-1", episodeID: "episode-1")

    let loaded = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1), now: 0)
    let ready = reducer.handle(.ready(generation: 1), now: 1)
    _ = reducer.handle(.play, now: 1)
    let progressed = reducer.handle(.positionUpdated(generation: 1, localOffset: 20), now: 2)
    let stopped = reducer.handle(.stop, now: 3)

    let events =
      loaded.progressEvents + ready.progressEvents + progressed.progressEvents
      + stopped.progressEvents
    #expect(events.isEmpty == false)
    #expect(events.allSatisfy { $0.itemId == "show-1" && $0.episodeID == "episode-1" })
  }

  @Test func loadingSiblingEpisodeEmitsDistinctFullIdentities() {
    var reducer = PlayerReducer(now: 0)
    let episodeA = Self.singleTrackItem(id: "show-1", episodeID: "episode-a")
    let episodeB = Self.singleTrackItem(id: "show-1", episodeID: "episode-b")

    _ = reducer.handle(.load(item: episodeA, initialGlobalPosition: 0, rate: 1), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)

    let switched = reducer.handle(
      .load(item: episodeB, initialGlobalPosition: 0, rate: 1), now: 4)

    #expect(switched.progressEvents.map(\.itemId) == ["show-1", "show-1"])
    #expect(switched.progressEvents.map(\.episodeID) == ["episode-a", "episode-b"])
  }

  @Test func loadFromIdleTransitionsToPreparingAndEmitsLoadEngineEffect() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()

    let result = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)

    #expect(reducer.state.phase == .preparing)
    #expect(reducer.state.item == item)
    #expect(reducer.state.currentTrackIndex == 0)
    #expect(
      result.effects == [
        .loadEngine(track: item.timeline.tracks[0], localOffset: 0, rate: 1.0, generation: 1),
        .setVolume(1.0),
      ])
    #expect(result.progressEvents.map(\.listenedDelta) == [0])
    #expect(result.progressEvents.map(\.phase) == [.preparing])
  }

  @Test func engineBufferingBeforeFirstReadyEntersBufferingPhase() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)

    let result = reducer.handle(.buffering(generation: 1), now: 1)

    #expect(reducer.state.phase == .buffering)
    #expect(result.progressEvents.map(\.listenedDelta) == [0])
  }

  @Test func readyBeforeAnyPlayIntentEntersReadyNotPaused() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)

    let result = reducer.handle(.ready(generation: 1), now: 1)

    #expect(reducer.state.phase == .ready)
    #expect(result.effects == [])
  }

  // MARK: - play/pause/toggle/stop

  @Test func playFromReadyTransitionsToPlayingAndEmitsPlayEffect() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)

    let result = reducer.handle(.play, now: 0)

    #expect(reducer.state.phase == .playing)
    #expect(result.effects == [.play])
  }

  @Test func pauseFromPlayingTransitionsToPausedAndEmitsPauseEffect() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)

    let result = reducer.handle(.pause, now: 3)

    #expect(reducer.state.phase == .paused)
    #expect(result.effects == [.pause])
    #expect(result.progressEvents.map(\.listenedDelta) == [3])
  }

  @Test func readyAfterHavingPlayedBeforeReturnsToPausedNotReady() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.pause, now: 1)
    // A rebuffer round-trip after having played once before.
    _ = reducer.handle(.buffering(generation: 1), now: 2)

    let result = reducer.handle(.ready(generation: 1), now: 3)

    #expect(reducer.state.phase == .paused)
    // The resolution re-asserts the standing pause. A real player can end a rebuffer with its
    // own ideas about whether it should be running.
    #expect(result.effects == [.pause])
  }

  @Test func toggleFlipsBetweenPlayingAndPaused() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)

    let toPlaying = reducer.handle(.toggle, now: 0)
    #expect(reducer.state.phase == .playing)
    #expect(toPlaying.effects == [.play])

    let toPaused = reducer.handle(.toggle, now: 1)
    #expect(reducer.state.phase == .paused)
    #expect(toPaused.effects == [.pause])
  }

  @Test func stopFromPlayingResetsToIdleAndEmitsStopEffectWithFinalCredit() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)

    let result = reducer.handle(.stop, now: 4)

    #expect(reducer.state == .idle)
    #expect(result.effects == [.stop, .setVolume(1.0)])
    #expect(result.progressEvents.map(\.itemId) == [item.id])
    #expect(result.progressEvents.map(\.listenedDelta) == [4])
    #expect(result.progressEvents.map(\.phase) == [.idle])
  }

  // MARK: - Same-track and cross-track seeks

  @Test func seekWithinTheSameTrackDoesNotChangeGeneration() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.twoTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)

    let result = reducer.handle(.seek(toGlobalOffset: 30), now: 1)

    #expect(reducer.state.phase == .seeking)
    #expect(reducer.state.currentTrackIndex == 0)
    #expect(result.effects == [.seekEngine(localOffset: 30)])

    // The seek resolves via a positionUpdated tagged with the SAME generation (1), so no reload.
    let resumed = reducer.handle(.positionUpdated(generation: 1, localOffset: 30), now: 1)
    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 30)
    #expect(resumed.effects == [.play])
  }

  @Test func seekAcrossATrackBoundaryLoadsTheNewTrackWithABumpedGeneration() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.twoTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)

    let result = reducer.handle(.seek(toGlobalOffset: 90), now: 1)

    #expect(reducer.state.phase == .seeking)
    #expect(reducer.state.currentTrackIndex == 1)
    #expect(
      result.effects == [
        .loadEngine(track: item.timeline.tracks[1], localOffset: 30, rate: 1.0, generation: 2)
      ])

    // A ready tagged with the OLD generation (1) must be ignored as stale.
    let stale = reducer.handle(.ready(generation: 1), now: 1)
    #expect(stale == .none)
    #expect(reducer.state.phase == .seeking)

    let resumed = reducer.handle(.ready(generation: 2), now: 1)
    #expect(reducer.state.phase == .playing)
    #expect(resumed.effects == [.play])
  }

  // MARK: - Automatic track advance

  @Test func trackFinishedOnANonFinalTrackAutomaticallyLoadsTheNextTrack() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.twoTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)

    let result = reducer.handle(.trackFinished(generation: 1), now: 60)

    #expect(reducer.state.phase == .preparing)
    #expect(reducer.state.currentTrackIndex == 1)
    #expect(
      result.effects == [
        .loadEngine(track: item.timeline.tracks[1], localOffset: 0, rate: 1.0, generation: 2)
      ])
    // Two progress events: the flushed credit for the finished track, then the fresh preparing
    // tick.
    #expect(result.progressEvents.map(\.listenedDelta) == [60, 0])

    let ready = reducer.handle(.ready(generation: 2), now: 60)
    #expect(reducer.state.phase == .playing)
    #expect(ready.effects == [.play])
  }

  @Test func trackFinishedOnTheFinalTrackEndsTheItem() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 100)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)

    let result = reducer.handle(.trackFinished(generation: 1), now: 100)

    #expect(reducer.state.phase == .ended)
    #expect(result.progressEvents.map(\.listenedDelta) == [100])
  }

  @Test func naturalEndIsEmittedOnlyOnce() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 100)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.trackFinished(generation: 1), now: 100)

    // A duplicate completion signal from a misbehaving engine, same generation, must be dropped.
    let duplicate = reducer.handle(.trackFinished(generation: 1), now: 101)
    let alsoDuplicate = reducer.handle(.positionUpdated(generation: 1, localOffset: 0), now: 102)

    #expect(duplicate == .none)
    #expect(alsoDuplicate == .none)
    #expect(reducer.state.phase == .ended)
  }

  // MARK: - Stale engine events from a displaced item

  @Test func staleEventsFromADisplacedItemAreIgnoredByGenerationId() {
    var reducer = PlayerReducer(now: 0)
    let itemA = Self.singleTrackItem(id: "item-a")
    let itemB = Self.singleTrackItem(id: "item-b")
    _ = reducer.handle(.load(item: itemA, initialGlobalPosition: 0, rate: 1.0), now: 0)
    // itemA's ready never arrives before the user switches to itemB.
    _ = reducer.handle(.load(item: itemB, initialGlobalPosition: 0, rate: 1.0), now: 1)

    #expect(reducer.state.item == itemB)
    #expect(reducer.state.phase == .preparing)

    // itemA's late ready (generation 1) must not resurrect itemA's state.
    let stale = reducer.handle(.ready(generation: 1), now: 2)

    #expect(stale == .none)
    #expect(reducer.state.item == itemB)
    #expect(reducer.state.phase == .preparing)

    // itemB's own ready (generation 2) still works normally.
    let fresh = reducer.handle(.ready(generation: 2), now: 3)
    #expect(reducer.state.phase == .ready)
    #expect(fresh.effects == [])
  }

  // MARK: - Retry after recoverable failure

  @Test func retryAfterARecoverableFailureReloadsTheCurrentTrack() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 10), now: 10)
    let failure = AudioEngineFailure(isRecoverable: true, message: "transient")
    _ = reducer.handle(.failed(generation: 1, failure), now: 10)

    #expect(reducer.state.phase == .failed(failure))

    let result = reducer.handle(.retry, now: 11)

    #expect(reducer.state.phase == .preparing)
    #expect(
      result.effects == [
        .loadEngine(track: item.timeline.tracks[0], localOffset: 10, rate: 1.0, generation: 2)
      ])

    // Retry preserves the pre-failure intent to keep playing.
    let ready = reducer.handle(.ready(generation: 2), now: 11)
    #expect(reducer.state.phase == .playing)
    #expect(ready.effects == [.play])
  }

  @Test func retryIsIllegalAfterAnUnrecoverableFailure() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    let failure = AudioEngineFailure(isRecoverable: false, message: "unusable stream")
    _ = reducer.handle(.failed(generation: 1, failure), now: 5)

    let result = reducer.handle(.retry, now: 6)

    #expect(result == .none)
    #expect(reducer.state.phase == .failed(failure))
  }

  // MARK: - Illegal intents are safe no-ops

  @Test func playPauseToggleSeekAreNoOpsWhileIdle() {
    var reducer = PlayerReducer(now: 0)

    #expect(reducer.handle(.play, now: 0) == .none)
    #expect(reducer.handle(.pause, now: 0) == .none)
    #expect(reducer.handle(.toggle, now: 0) == .none)
    #expect(reducer.handle(.seek(toGlobalOffset: 5), now: 0) == .none)
    #expect(reducer.handle(.stop, now: 0).effects == [.setVolume(1.0)])
    #expect(reducer.handle(.retry, now: 0) == .none)
    #expect(reducer.state == .idle)
  }

  @Test func playPauseToggleAreNoOpsWhileFailed() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    let failure = AudioEngineFailure(isRecoverable: true, message: "transient")
    _ = reducer.handle(.failed(generation: 1, failure), now: 1)

    #expect(reducer.handle(.play, now: 2) == .none)
    #expect(reducer.handle(.pause, now: 2) == .none)
    #expect(reducer.handle(.toggle, now: 2) == .none)
    #expect(reducer.handle(.seek(toGlobalOffset: 5), now: 2) == .none)
    #expect(reducer.state.phase == .failed(failure))
  }

  @Test func playPauseToggleAreNoOpsAfterNaturalEnd() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 10)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.trackFinished(generation: 1), now: 10)

    #expect(reducer.handle(.play, now: 11) == .none)
    #expect(reducer.handle(.pause, now: 11) == .none)
    #expect(reducer.handle(.toggle, now: 11) == .none)
    #expect(reducer.state.phase == .ended)
  }

  // MARK: - Transport responsiveness on a real stream

  /// A real engine reports a seek's position only via later periodic ticks, and while paused it
  /// never ticks at all. The reducer must therefore adopt the target position the moment the seek
  /// intent is handled, not when the engine eventually confirms it.
  @Test func seekImmediatelyMovesStateAndTheEmittedEventToTheTarget() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)

    let result = reducer.handle(.seek(toGlobalOffset: 30), now: 3)

    #expect(reducer.state.globalPosition == 30)
    #expect(result.progressEvents.map(\.currentTime) == [30])
    // The three seconds spent playing before the seek still accrue as listening time.
    #expect(result.progressEvents.map(\.listenedDelta) == [3])
  }

  /// The AVQueuePlayer adapter's seek completion emits `.ready` carrying no position; a paused
  /// player produces no periodic ticks afterward. The resolved event must still carry the target.
  @Test func aPausedSeekResolvedByAPositionlessReadyKeepsTheTargetPosition() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.pause, now: 1)

    _ = reducer.handle(.seek(toGlobalOffset: 42), now: 2)
    let resolved = reducer.handle(.ready(generation: 1), now: 3)

    #expect(reducer.state.phase == .paused)
    #expect(reducer.state.globalPosition == 42)
    #expect(resolved.progressEvents.map(\.currentTime) == [42])
  }

  /// A streaming player spends real time in `.buffering` (`timeControlStatus` flaps around every
  /// play/seek). A pause tapped in that window must still stop the audible engine immediately,
  /// not be silently dropped until the next `.playing` phase.
  @Test func pauseDuringBufferingStillReachesTheEngine() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.buffering(generation: 1), now: 1)

    let result = reducer.handle(.pause, now: 2)

    #expect(result.effects == [.pause])

    // When the stall clears, the resolution honors the pause and re-asserts it to the engine,
    // since the engine was mid-play when the pause intent arrived.
    let resolved = reducer.handle(.ready(generation: 1), now: 3)
    #expect(reducer.state.phase == .paused)
    #expect(resolved.effects == [.pause])
  }

  @Test func pauseWhileARequestedPlayIsStillPreparingCancelsTheEngineRequest() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.play, now: 0)

    let result = reducer.handle(.pause, now: 1)

    #expect(reducer.state.phase == .preparing)
    #expect(reducer.state.isPlaybackIntended == false)
    #expect(result.effects == [.pause])

    let resolved = reducer.handle(.ready(generation: 1), now: 2)
    #expect(reducer.state.phase == .paused)
    #expect(resolved.effects == [.pause])
  }

  @Test func playDuringBufferingStillReachesTheEngine() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.buffering(generation: 1), now: 1)
    _ = reducer.handle(.pause, now: 2)

    let result = reducer.handle(.play, now: 3)

    #expect(result.effects == [.play])
  }

  @Test func toggleDuringSeekingPausesTheAudibleStream() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.seek(toGlobalOffset: 30), now: 1)

    let result = reducer.handle(.toggle, now: 2)

    #expect(result.effects == [.pause])

    _ = reducer.handle(.ready(generation: 1), now: 3)
    #expect(reducer.state.phase == .paused)
    #expect(reducer.state.globalPosition == 30)
  }

  /// The UI's play/pause icon must reflect the user's intent, not the engine's transient phase.
  /// Buffering/seeking flaps must never flip it.
  @Test func playbackIntentIsExposedInStateAcrossTransientPhases() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    #expect(reducer.state.isPlaybackIntended == false)

    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    #expect(reducer.state.isPlaybackIntended)

    _ = reducer.handle(.buffering(generation: 1), now: 1)
    #expect(reducer.state.isPlaybackIntended, "a buffering flap never flips intent")

    _ = reducer.handle(.seek(toGlobalOffset: 30), now: 2)
    #expect(reducer.state.isPlaybackIntended, "a seek never flips intent")

    _ = reducer.handle(.pause, now: 3)
    #expect(reducer.state.isPlaybackIntended == false)

    _ = reducer.handle(.stop, now: 4)
    #expect(reducer.state.isPlaybackIntended == false)
  }

  // MARK: - Stale position ticks arriving mid-seek

  /// A streaming seek takes real time to land, and `AVQueuePlayer`'s periodic observer keeps
  /// reporting the pre-seek clock the whole time it is in flight. The first tick after a seek is
  /// normally the position the listener just dragged away from, so it must not resolve the seek
  /// or it overwrites the target with the stale position.
  @Test func aPreSeekTickArrivingMidSeekNeverDisplacesTheTarget() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 36_960)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 130, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)

    _ = reducer.handle(.seek(toGlobalOffset: 2400), now: 130)
    let stale = reducer.handle(.positionUpdated(generation: 1, localOffset: 130.5), now: 130.5)

    #expect(stale == .none, "a pre-seek tick must not be reported as progress")
    #expect(reducer.state.phase == .seeking, "the seek is still in flight until the engine confirms")
    #expect(reducer.state.globalPosition == 2400)
  }

  /// A phase check is not enough: a streaming engine flaps into `.buffering` between the seek
  /// request and its completion, so by the time the stale ticks arrive the phase says
  /// "buffering", not "seeking". Captured sequence: `seeking t=1420.29`, `buffering t=1420.29`,
  /// `buffering t=63.0`, which undoes the listener's drag one tick after it landed.
  @Test func aStaleTickIsRejectedEvenWhenTheEngineHasFlappedIntoBuffering() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 36_960)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 63, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)

    _ = reducer.handle(.seek(toGlobalOffset: 1420.29), now: 63)
    _ = reducer.handle(.buffering(generation: 1), now: 63)
    #expect(reducer.state.phase == .buffering, "the flap this test exists to model")

    let stale = reducer.handle(.positionUpdated(generation: 1, localOffset: 63), now: 63.5)

    #expect(stale == .none)
    #expect(reducer.state.globalPosition == 1420.29)
  }

  /// Every tick that arrives before the engine's clock reaches the target is stale, not just the
  /// first. A slow stream produces several.
  @Test func aRunOfPreSeekTicksLeavesTheTargetUntouched() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 36_960)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 130, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.seek(toGlobalOffset: 2400), now: 130)

    for tick in [130.5, 131.0, 131.5, 132.0] {
      _ = reducer.handle(.positionUpdated(generation: 1, localOffset: tick), now: tick)
    }

    #expect(reducer.state.phase == .seeking)
    #expect(reducer.state.globalPosition == 2400)
  }

  /// A tick that does reflect the seek still resolves it. The engine's landing is not exact
  /// (`AVPlayer` settles on a nearby sync sample), so "reflects the seek" means near the target,
  /// not equal to it.
  @Test func aTickNearTheTargetResolvesTheSeekAndIsAdopted() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 36_960)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 130, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.seek(toGlobalOffset: 2400), now: 130)

    let landed = reducer.handle(.positionUpdated(generation: 1, localOffset: 2398.4), now: 131)

    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 2398.4)
    #expect(landed.effects == [.play])
  }

  /// A seek whose ticks never confirm it must still resolve. The adapter emits `.ready` from its
  /// seek completion handler, which cannot be mistaken for a stale clock. Otherwise the reducer
  /// would sit in `.seeking` forever behind a slow stream.
  @Test func readyResolvesASeekThatStalePositionTicksCouldNotConfirm() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 36_960)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 130, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.seek(toGlobalOffset: 2400), now: 130)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 130.5), now: 130.5)

    let resolved = reducer.handle(.ready(generation: 1), now: 131)

    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 2400)
    #expect(resolved.progressEvents.map(\.currentTime) == [2400])
  }

  // MARK: - A load's own initial positioning

  /// Stale ticks apply to a load's initial positioning too. A cold Resume tap loads the title at
  /// its saved position, and the adapter resolves that position by seeking the freshly enqueued
  /// item. The periodic observer reports the item's own clock from the moment playback is
  /// requested, and that reads zero until the seek lands. Adopting that tick would put the
  /// playhead at the start of the book and send the zero to sync as a progress tick.
  @Test func aPreSeekTickArrivingBeforeALoadsPositioningIsRejected() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 36_960)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 14_784, rate: 1.0), now: 0)
    _ = reducer.handle(.play, now: 0)

    let stale = reducer.handle(.positionUpdated(generation: 1, localOffset: 0), now: 0.5)

    #expect(stale == .none, "the engine's pre-seek clock must not be reported as progress")
    #expect(reducer.state.globalPosition == 14_784)
  }

  /// A slow stream produces several such ticks before its seek lands, not one.
  @Test func aRunOfPreSeekTicksLeavesALoadsPositionUntouched() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 36_960)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 14_784, rate: 1.0), now: 0)
    _ = reducer.handle(.play, now: 0)

    for tick in [0.0, 0.5, 1.0, 1.5] {
      _ = reducer.handle(.positionUpdated(generation: 1, localOffset: tick), now: tick + 0.5)
    }

    #expect(reducer.state.globalPosition == 14_784)
  }

  /// As for a seek: the tick that does reflect the landing is adopted, and ordinary ticks own
  /// the position from then on.
  @Test func aTickNearTheLoadPositionResolvesItAndTicksResumeOwningThePosition() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 36_960)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 14_784, rate: 1.0), now: 0)
    _ = reducer.handle(.play, now: 0)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 14_783.98), now: 0.5)
    #expect(reducer.state.globalPosition == 14_784, "an undershoot within the epsilon keeps the target")

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 14_785), now: 1)
    #expect(reducer.state.globalPosition == 14_785)
  }

  /// A load whose ticks never confirm its position still resolves on `.ready`, the same escape the
  /// seek path relies on. A paused load never ticks at all, so nothing else could.
  @Test func readyResolvesALoadsPositioningThatTicksCouldNotConfirm() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 36_960)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 14_784, rate: 1.0), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 0), now: 0.5)

    _ = reducer.handle(.ready(generation: 1), now: 1)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 900), now: 1.5)

    #expect(reducer.state.globalPosition == 900, "a resolved load leaves the engine owning the position")
  }

  /// A title started from the beginning has no positioning to wait for, so its first tick is
  /// ordinary progress rather than a stale clock. Guarding it would freeze the playhead at zero
  /// for the whole of the first 15 seconds, the width of the landing tolerance.
  @Test func aLoadAtTheStartArmsNoGuardAndAdoptsItsFirstTick() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 36_960)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.play, now: 0)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 0.5), now: 0.5)

    #expect(reducer.state.globalPosition == 0.5)
  }

  /// Once the seek has resolved, ordinary ticks own the position again, including a landing that
  /// genuinely differs from the target. Ignoring stale ticks must not harden into ignoring the
  /// engine, or a clamped or drifted seek would leave the UI wrong about where playback is.
  @Test func ticksResumeOwningThePositionOnceTheSeekHasResolved() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem(duration: 36_960)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 130, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.seek(toGlobalOffset: 2400), now: 130)
    _ = reducer.handle(.ready(generation: 1), now: 131)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 1800), now: 132)

    #expect(reducer.state.globalPosition == 1800)
  }
}
