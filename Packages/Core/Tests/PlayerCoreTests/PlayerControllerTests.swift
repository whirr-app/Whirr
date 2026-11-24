import Foundation
import Observation
import TestSupport
import Testing

@testable import PlayerCore

/// `PlayerController` is the thin `@MainActor` shell wiring `PlayerReducer` to `AudioEngine`.
/// `PlayerStateMachineTests` and `ListeningDeltaTests` cover the reducer, so this file proves the
/// wiring: intents reach the reducer and produce engine calls, engine events flow back in through
/// the listener task, and progress events surface on `progressEvents`.
///
/// No sleeps or fixed yield counts: `AudioEngine.events` and `PlayerController.progressEvents` are
/// each one ordered `AsyncStream`, so `await iterator.next()` suspends until the listener task has
/// applied the engine event, however many scheduling hops that takes.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct PlayerControllerTests {

  private static func singleTrackItem(duration: Double = 100) -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: duration)])
    return PlayerItem(id: "item-1", timeline: timeline)
  }

  /// Records whether Observation invalidated whatever `read` touched. Single-shot because
  /// `withObservationTracking`'s `onChange` fires once per registration, which matches the
  /// question these tests ask: did a position tick invalidate this property at all.
  private final class ChangeFlag: @unchecked Sendable {
    private(set) var didChange = false
    func mark() { didChange = true }
  }

  private static func trackFirstChange<T>(_ read: @escaping () -> T) -> ChangeFlag {
    let flag = ChangeFlag()
    withObservationTracking {
      _ = read()
    } onChange: {
      flag.mark()
    }
    return flag
  }

  @Test func loadRestoreVolumeEffectReachesTheAudioEngine() {
    let engine = FakeAudioEngine()
    let controller = PlayerController(engine: engine, clock: ManualClock(now: 0))

    controller.send(.load(item: Self.singleTrackItem(), initialGlobalPosition: 0, rate: 1.0))

    #expect(engine.setVolumeCalls == [1.0])
  }

  @Test func sendPlayAfterReadyCallsEngineDotPlayAndUpdatesState() async {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let controller = PlayerController(engine: engine, clock: clock)
    var events = controller.progressEvents.makeAsyncIterator()

    controller.send(.load(item: Self.singleTrackItem(), initialGlobalPosition: 0, rate: 1.0))
    #expect(engine.loadCalls.count == 1)
    _ = await events.next()  // preparing tick

    engine.emit(.ready(generation: 1))
    _ = await events.next()  // ready tick, so the internal listener has applied it
    #expect(controller.state.phase == .ready)

    controller.send(.play)
    #expect(controller.state.phase == .playing)
    #expect(engine.playCallCount == 1)
  }

  @Test func engineTrackFinishedFlowsThroughToProgressEvents() async {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let controller = PlayerController(engine: engine, clock: clock)
    var events = controller.progressEvents.makeAsyncIterator()

    controller.send(.load(item: Self.singleTrackItem(duration: 10), initialGlobalPosition: 0, rate: 1.0))
    _ = await events.next()  // preparing

    engine.emit(.ready(generation: 1))
    _ = await events.next()  // ready

    controller.send(.play)
    _ = await events.next()  // playing

    clock.advance(by: 10)
    engine.emit(.trackFinished(generation: 1))
    let ended = await events.next()  // ended, with the full 10s credited

    #expect(controller.state.phase == .ended)
    #expect(ended?.listenedDelta == 10)
  }

  @Test func recoverableEngineFailureFlowsThroughAndRetryReloadsTheEngine() async {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let controller = PlayerController(engine: engine, clock: clock)
    let progressRecorder = ProgressRecorder()
    let progressTask = Task {
      for await event in controller.progressEvents {
        progressRecorder.record(event)
      }
    }
    let failure = AudioEngineFailure(isRecoverable: true, message: "stream interrupted")

    controller.send(.load(item: Self.singleTrackItem(), initialGlobalPosition: 0, rate: 1.0))
    #expect(await waitUntil { controller.state.phase == .preparing })
    engine.emit(.ready(generation: 1))
    #expect(await waitUntil { controller.state.phase == .ready })

    engine.emit(.failed(generation: 1, failure))
    #expect(await waitUntil { controller.state.phase == .failed(failure) })
    #expect(await waitUntil { progressRecorder.events.contains { $0.phase == .failed(failure) } })
    #expect(progressRecorder.events.last?.phase == .failed(failure))
    #expect(controller.state.phase == .failed(failure))

    controller.send(.retry)
    #expect(controller.state.phase == .preparing)
    #expect(engine.loadCalls.count == 2)
    #expect(engine.loadCalls.last?.generation == 2)
    #expect(engine.loadCalls.last?.localOffset == 0)
    #expect(engine.loadCalls.last?.rate == 1.0)
    progressTask.cancel()
  }

  @Test func staleEngineEventAfterAnItemSwitchIsIgnoredThroughTheFullStack() async {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let controller = PlayerController(engine: engine, clock: clock)
    var events = controller.progressEvents.makeAsyncIterator()

    controller.send(.load(item: Self.singleTrackItem(), initialGlobalPosition: 0, rate: 1.0))
    _ = await events.next()  // preparing for item A (generation 1)

    controller.send(
      .load(item: Self.singleTrackItem(duration: 50), initialGlobalPosition: 0, rate: 1.0))
    _ = await events.next()  // flush of item A's (zero) credit
    _ = await events.next()  // preparing for item B (generation 2)

    // Item A's late ready (generation 1) is emitted first and must be dropped without producing
    // a tick. Item B's own ready (generation 2), emitted right after on the same ordered engine
    // stream, still works normally, and receiving its tick proves the stale one was handled.
    engine.emit(.ready(generation: 1))
    engine.emit(.ready(generation: 2))
    let freshTick = await events.next()

    #expect(freshTick?.phase == .ready)
    #expect(controller.state.phase == .ready)
    #expect(controller.state.item?.timeline.totalDuration == 50)
  }

  // MARK: - Observation granularity

  /// Every play/pause affordance in the app renders `isPlaybackIntended` (the context menu's
  /// Play/Pause entry, the mini-player's button). The engine ticks twice a second while playing, so
  /// if a position tick invalidated intent, every one of those surfaces would rebuild at the tick
  /// cadence. A presented context menu rebuilding re-renders its live-blurred backdrop, so the
  /// whole page visibly pulses.
  @Test func positionTicksDoNotInvalidateIsPlaybackIntended() async {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let controller = PlayerController(engine: engine, clock: clock)
    var events = controller.progressEvents.makeAsyncIterator()

    controller.send(.load(item: Self.singleTrackItem(), initialGlobalPosition: 0, rate: 1.0))
    _ = await events.next()  // preparing
    engine.emit(.ready(generation: 1))
    _ = await events.next()  // ready
    controller.send(.play)
    _ = await events.next()  // playing, consumed so the two `next()`s below are the ticks
    #expect(controller.isPlaybackIntended)

    let flag = Self.trackFirstChange { controller.isPlaybackIntended }

    clock.advance(by: 0.5)
    engine.emit(.positionUpdated(generation: 1, localOffset: 0.5))
    _ = await events.next()
    clock.advance(by: 0.5)
    engine.emit(.positionUpdated(generation: 1, localOffset: 1))
    _ = await events.next()

    #expect(controller.state.globalPosition == 1, "the ticks really were applied")
    #expect(flag.didChange == false, "a position tick must not invalidate playback intent")
  }

  /// The other half of the contract: intent is still observable, so a control keyed to it updates
  /// the moment the user actually pauses.
  @Test func pausingInvalidatesIsPlaybackIntended() async {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let controller = PlayerController(engine: engine, clock: clock)
    var events = controller.progressEvents.makeAsyncIterator()

    controller.send(.load(item: Self.singleTrackItem(), initialGlobalPosition: 0, rate: 1.0))
    _ = await events.next()  // preparing
    engine.emit(.ready(generation: 1))
    _ = await events.next()  // ready
    controller.send(.play)

    let flag = Self.trackFirstChange { controller.isPlaybackIntended }
    controller.send(.pause)

    #expect(controller.isPlaybackIntended == false)
    #expect(flag.didChange, "a real intent change must still reach observers")
  }

  /// The scrubber's side: `state` carries the position, so it must stay invalidated per tick.
  /// Only intent's dependencies are narrowed; the player still publishes.
  @Test func positionTicksStillInvalidateState() async {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let controller = PlayerController(engine: engine, clock: clock)
    var events = controller.progressEvents.makeAsyncIterator()

    controller.send(.load(item: Self.singleTrackItem(), initialGlobalPosition: 0, rate: 1.0))
    _ = await events.next()  // preparing
    engine.emit(.ready(generation: 1))
    _ = await events.next()  // ready
    controller.send(.play)
    _ = await events.next()  // playing, consumed so the `next()` below is the position tick

    let flag = Self.trackFirstChange { controller.state.globalPosition }

    clock.advance(by: 0.5)
    engine.emit(.positionUpdated(generation: 1, localOffset: 0.5))
    _ = await events.next()

    #expect(controller.state.globalPosition == 0.5, "the tick really was applied")
    #expect(flag.didChange)
  }
}

private final class ProgressRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [PlaybackProgressEvent] = []

  var events: [PlaybackProgressEvent] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func record(_ event: PlaybackProgressEvent) {
    lock.lock()
    recorded.append(event)
    lock.unlock()
  }
}
