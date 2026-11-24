import TestSupport
import Testing

@testable import PlayerCore

/// The stall deadline is tested through the real `PlayerController` funnel: engine events and
/// intents drive the reducer, while the fake scheduler supplies only the independent deadline.
/// Ordered progress events provide the synchronization point for the controller's listener task;
/// no real sleeps or fixed yield counts are involved.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct PlayerStallTests {

  @Test func enteringBufferingOnAStreamingItemArmsOneTwentySecondDeadline() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()

    #expect(
      harness.scheduler.scheduleCalls.map(\.seconds)
        == [PlayerController.preparationTimeout, PlayerController.stallTimeout])
    #expect(harness.scheduler.scheduleCalls.last?.token == 2)
  }

  @Test func aStreamingItemInPreparingStallsAtThePreparationDeadline() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.load()

    #expect(harness.controller.state.phase == .preparing)
    #expect(harness.controller.isPlaybackIntended)
    #expect(harness.scheduler.scheduleCalls.map(\.seconds) == [PlayerController.preparationTimeout])

    harness.scheduler.fire(token: harness.scheduler.scheduleCalls.last!.token)
    let event = await harness.nextProgressEvent()

    #expect(harness.controller.state.phase == .stalled)
    #expect(event?.phase == .stalled)
  }

  @Test func aStreamingItemInSeekingStallsAtThePreparationDeadline() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.load()
    harness.engine.emit(.ready(generation: 1))
    _ = await harness.nextProgressEvent()

    harness.controller.send(.seek(toGlobalOffset: 50))
    let seekingEvent = await harness.nextProgressEvent()

    #expect(seekingEvent?.phase == .seeking)
    #expect(harness.controller.state.phase == .seeking)
    #expect(harness.controller.isPlaybackIntended)
    #expect(harness.scheduler.scheduleCalls.last?.seconds == PlayerController.preparationTimeout)

    harness.scheduler.fire(token: harness.scheduler.scheduleCalls.last!.token)
    let stalledEvent = await harness.nextProgressEvent()

    #expect(harness.controller.state.phase == .stalled)
    #expect(stalledEvent?.phase == .stalled)
  }

  @Test func aPausedStreamingItemInPreparingDoesNotArmOrStall() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.load(play: false)

    #expect(harness.controller.state.phase == .preparing)
    #expect(harness.controller.isPlaybackIntended == false)
    #expect(harness.scheduler.scheduleCalls.isEmpty)

    harness.scheduler.fire(token: 0)
    harness.controller.send(.setRate(1.25))
    let event = await harness.nextProgressEvent()

    #expect(event?.phase == .preparing)
    #expect(harness.controller.state.phase == .preparing)
  }

  @Test func aLocalItemInPreparingDoesNotArmOrStall() async {
    let harness = StallHarness(item: Self.item(isStreaming: false))
    await harness.load()

    #expect(harness.controller.state.phase == .preparing)
    #expect(harness.controller.isPlaybackIntended)
    #expect(harness.scheduler.scheduleCalls.isEmpty)

    harness.scheduler.fire(token: 0)
    harness.controller.send(.setRate(1.25))
    let event = await harness.nextProgressEvent()

    #expect(event?.phase == .preparing)
    #expect(harness.controller.state.phase == .preparing)
  }

  @Test func readyCancelsThePreparationDeadline() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.load()
    let preparationToken = harness.scheduler.scheduleCalls.last!.token

    harness.engine.emit(.ready(generation: 1))
    _ = await harness.nextProgressEvent()

    #expect(harness.controller.state.phase == .playing)
    #expect(harness.scheduler.cancelCallCount == 1)

    harness.scheduler.fire(token: preparationToken)
    harness.engine.emit(.positionUpdated(generation: 1, localOffset: 1))
    let event = await harness.nextProgressEvent()
    #expect(event?.phase == .playing)
    #expect(harness.controller.state.phase == .playing)
  }

  @Test func enteringBufferingOnALocalItemDoesNotArmADeadline() async {
    let item = Self.item(isStreaming: false)
    #expect(item.isStreaming == false, "the conservative PlayerItem default must remain local")
    let harness = StallHarness(item: item)
    await harness.loadAndBuffer()

    #expect(harness.scheduler.scheduleCalls.isEmpty)
    #expect(harness.scheduler.cancelCallCount == 0)

    // Even an injected late delivery cannot turn a local buffering item into `.stalled`.
    harness.scheduler.fire(token: 0)
    harness.controller.send(.setRate(1.25))
    let event = await harness.nextProgressEvent()
    #expect(event?.phase == .buffering)
    #expect(harness.controller.state.phase == .buffering)
  }

  @Test func aPositionTickDuringBufferingDoesNotResetTheDeadline() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()

    harness.engine.emit(.positionUpdated(generation: 1, localOffset: 1))
    _ = await harness.nextProgressEvent()

    #expect(harness.scheduler.scheduleCalls.count == 2)
  }

  @Test func readyCancelsTheBufferingDeadline() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()

    harness.engine.emit(.ready(generation: 1))
    _ = await harness.nextProgressEvent()

    #expect(harness.controller.state.phase == .playing)
    #expect(harness.scheduler.cancelCallCount == 1)
  }

  /// Pause leaves the reducer's phase at `.buffering` because the engine may still have audio in
  /// flight, so the deadline has to follow the dropped intent, not the phase alone.
  @Test func pauseCancelsTheBufferingDeadline() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()

    harness.controller.send(.pause)

    #expect(harness.controller.state.phase == .buffering)
    #expect(harness.controller.isPlaybackIntended == false)
    #expect(harness.scheduler.cancelCallCount == 1)
  }

  @Test func bufferingThatNoOneIsWaitingOnDoesNotArmADeadline() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.load(play: false)
    harness.controller.send(.pause)

    harness.engine.emit(.buffering(generation: 1))
    _ = await harness.nextProgressEvent()

    #expect(harness.controller.state.phase == .buffering)
    #expect(harness.scheduler.scheduleCalls.isEmpty)
  }

  @Test func askingForPlaybackAgainDuringBufferingArmsAFreshDeadline() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()
    harness.controller.send(.pause)

    harness.controller.send(.play)

    #expect(harness.controller.state.phase == .buffering)
    #expect(harness.scheduler.scheduleCalls.map(\.token) == [1, 2, 3])
    #expect(harness.scheduler.cancelCallCount == 1)
  }

  @Test func stopCancelsTheBufferingDeadline() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()

    harness.controller.send(.stop)
    _ = await harness.nextProgressEvent()

    #expect(harness.controller.state.phase == .idle)
    #expect(harness.scheduler.cancelCallCount == 1)
    #expect(harness.engine.stopCallCount == 1)
  }

  @Test func loadCancelsTheBufferingDeadline() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()

    harness.controller.send(
      .load(item: Self.item(id: "item-2", isStreaming: true), initialGlobalPosition: 0, rate: 1.0))

    #expect(harness.controller.state.phase == .preparing)
    #expect(harness.scheduler.cancelCallCount == 1)
  }

  @Test func aCrossTrackSeekReplacesTheBufferingDeadline() async {
    let harness = StallHarness(item: Self.twoTrackItem(isStreaming: true))
    await harness.loadAndBuffer()

    harness.controller.send(.seek(toGlobalOffset: 75))

    #expect(harness.controller.state.phase == .seeking)
    #expect(harness.scheduler.scheduleCalls.last?.seconds == PlayerController.preparationTimeout)
    #expect(harness.scheduler.scheduleCalls.last?.token == 3)
  }

  @Test func failureCancelsTheBufferingDeadline() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()
    let failure = AudioEngineFailure(isRecoverable: true, message: "stream ended")

    harness.engine.emit(.failed(generation: 1, failure))
    _ = await harness.nextProgressEvent()

    #expect(harness.controller.state.phase == .failed(failure))
    #expect(harness.scheduler.cancelCallCount == 1)
  }

  @Test func theCurrentTimeoutEntersStalledAndPublishesThatPhase() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()

    harness.scheduler.fire(token: harness.scheduler.scheduleCalls.last!.token)
    let event = await harness.nextProgressEvent()

    #expect(harness.controller.state.phase == .stalled)
    #expect(event?.phase == .stalled)
    #expect(harness.controller.isPlaybackIntended == false)
    #expect(harness.engine.pauseCallCount == 1)
    #expect(harness.scheduler.cancelCallCount == 1)
  }

  @Test func aSupersededTimeoutCannotStallASecondBufferingWindow() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()
    harness.engine.emit(.ready(generation: 1))
    _ = await harness.nextProgressEvent()
    harness.engine.emit(.buffering(generation: 1))
    _ = await harness.nextProgressEvent()

    #expect(harness.scheduler.scheduleCalls.map(\.token) == [1, 2, 3])
    for token in harness.scheduler.scheduleCalls.map(\.token) {
      harness.scheduler.fire(token: token)
    }
    let event = await harness.nextProgressEvent()

    #expect(event?.phase == .stalled)
    #expect(harness.controller.state.phase == .stalled)
  }

  @Test func aTimeoutFiredOutsideBufferingIsInert() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()
    harness.engine.emit(.ready(generation: 1))
    _ = await harness.nextProgressEvent()

    // The cancelled deadline still carries the token it was armed with, so only the reducer's own
    // phase guard can make the late delivery inert once the engine has recovered.
    harness.scheduler.fire(token: harness.scheduler.scheduleCalls.last!.token)
    harness.engine.emit(.positionUpdated(generation: 1, localOffset: 1))
    let positionEvent = await harness.nextProgressEvent()

    #expect(positionEvent?.phase == .playing)
    #expect(harness.controller.state.phase == .playing)
  }

  @Test func aStrayBufferingAndPositionTickDoNotClearStalledButReadyLeavesItPaused() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()
    harness.scheduler.fire(token: harness.scheduler.scheduleCalls.last!.token)
    _ = await harness.nextProgressEvent()

    harness.engine.emit(.buffering(generation: 1))
    harness.engine.emit(.positionUpdated(generation: 1, localOffset: 1))
    let positionEvent = await harness.nextProgressEvent()
    #expect(positionEvent?.phase == .stalled)
    #expect(harness.controller.state.phase == .stalled)

    harness.engine.emit(.ready(generation: 1))
    let readyEvent = await harness.nextProgressEvent()
    #expect(readyEvent?.phase == .paused)
    #expect(harness.controller.state.phase == .paused)
    #expect(harness.engine.pauseCallCount == 2)
    #expect(harness.engine.playCallCount == 0)
  }

  @Test func aStalledStreamDoesNotPlayWhenReadyArrivesWithoutUserAction() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()

    harness.scheduler.fire(token: harness.scheduler.scheduleCalls.last!.token)
    _ = await harness.nextProgressEvent()
    let playCallsAtStall = harness.engine.playCallCount

    #expect(harness.engine.pauseCallCount == 1)

    harness.engine.emit(.ready(generation: 1))
    let readyEvent = await harness.nextProgressEvent()

    #expect(readyEvent?.phase == .paused)
    #expect(harness.controller.state.phase == .paused)
    #expect(harness.controller.isPlaybackIntended == false)
    #expect(harness.engine.playCallCount == playCallsAtStall)
    #expect(harness.engine.pauseCallCount == 2)
  }

  @Test func stalledRejectsPlaybackIntentsButStopStillWorks() async {
    let harness = StallHarness(item: Self.item(isStreaming: true))
    await harness.loadAndBuffer()
    harness.scheduler.fire(token: harness.scheduler.scheduleCalls.last!.token)
    _ = await harness.nextProgressEvent()
    let engineCallsBefore = (
      harness.engine.playCallCount,
      harness.engine.pauseCallCount,
      harness.engine.seekCalls.count
    )

    harness.controller.send(.play)
    harness.controller.send(.pause)
    harness.controller.send(.seek(toGlobalOffset: 30))
    harness.controller.send(.retry)

    #expect(harness.controller.state.phase == .stalled)
    #expect(harness.controller.isPlaybackIntended == false)
    #expect(
      (harness.engine.playCallCount, harness.engine.pauseCallCount, harness.engine.seekCalls.count)
        == engineCallsBefore)

    harness.controller.send(.stop)
    _ = await harness.nextProgressEvent()
    #expect(harness.controller.state.phase == .idle)
    #expect(harness.controller.isPlaybackIntended == false)
    #expect(harness.engine.stopCallCount == 1)
  }

  private static func item(id: String = "item-1", isStreaming: Bool) -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)])
    return PlayerItem(id: id, timeline: timeline, isStreaming: isStreaming)
  }

  private static func twoTrackItem(isStreaming: Bool) -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 60), PlaybackTrack(index: 1, duration: 40),
    ])
    return PlayerItem(id: "item-1", timeline: timeline, isStreaming: isStreaming)
  }
}

@MainActor
private final class StallHarness {
  let engine: FakeAudioEngine
  let clock: ManualClock
  let scheduler: FakePlayerStallScheduler
  let controller: PlayerController
  private let item: PlayerItem
  private let progressReader: ProgressStreamReader

  init(item: PlayerItem) {
    self.item = item
    engine = FakeAudioEngine()
    clock = ManualClock(now: 0)
    scheduler = FakePlayerStallScheduler()
    controller = PlayerController(
      engine: engine, clock: clock, stallScheduler: scheduler)
    progressReader = ProgressStreamReader(stream: controller.progressEvents)
  }

  /// Mirrors `PlaybackModel.performStart`, which issues `.load` and `.play` together. Neither
  /// emits a progress event of its own beyond the load's.
  func load(play: Bool = true) async {
    controller.send(.load(item: item, initialGlobalPosition: 0, rate: 1.0))
    _ = await nextProgressEvent()
    if play { controller.send(.play) }
  }

  /// A real buffering window is always one the listener is waiting on, so the default path asks
  /// for playback before the engine reports buffering.
  func loadAndBuffer() async {
    await load()
    engine.emit(.buffering(generation: 1))
    _ = await nextProgressEvent()
  }

  func nextProgressEvent() async -> PlaybackProgressEvent? {
    await progressReader.next()
  }
}

/// A single-consumer wrapper for an `AsyncStream` iterator. The harness never calls `next()`
/// concurrently; `@unchecked Sendable` keeps that test-only ownership invariant explicit while
/// allowing the iterator's mutating async method to cross its suspension point under Swift 6.
private final class ProgressStreamReader: @unchecked Sendable {
  private var iterator: AsyncStream<PlaybackProgressEvent>.Iterator

  init(stream: AsyncStream<PlaybackProgressEvent>) {
    iterator = stream.makeAsyncIterator()
  }

  func next() async -> PlaybackProgressEvent? {
    await iterator.next()
  }
}
