import Observation
import Testing

@testable import PlayerCore

/// The quick-actions projection is narrower than `PlayerState`: its menu structure
/// must stay quiet while the player publishes position ticks, while the countdown label may still
/// follow a running timer through its separate projection.
@MainActor
@Suite struct PlayerQuickActionsTests {

  private static func item() -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)])
    let chapters = PlaybackChapterMap(
      chapters: [PlaybackChapter(id: "chapter-1", title: "One", start: 0, end: 50)])
    return PlayerItem(id: "item-1", timeline: timeline, chapters: chapters)
  }

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

  @Test func positionTicksDoNotInvalidateQuickActionsState() async {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let controller = PlayerController(engine: engine, clock: clock)
    var events = controller.progressEvents.makeAsyncIterator()

    controller.send(.load(item: Self.item(), initialGlobalPosition: 0, rate: 1.0))
    _ = await events.next()
    engine.emit(.ready(generation: 1))
    _ = await events.next()
    controller.send(.play)
    _ = await events.next()

    let flag = Self.trackFirstChange { controller.quickActions }

    clock.advance(by: 0.5)
    engine.emit(.positionUpdated(generation: 1, localOffset: 0.5))
    _ = await events.next()

    #expect(controller.state.globalPosition == 0.5)
    #expect(flag.didChange == false, "position ticks must not invalidate menu structure")
  }

  @Test func changingRateInvalidatesQuickActionsState() {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let controller = PlayerController(engine: engine, clock: clock)

    controller.send(.load(item: Self.item(), initialGlobalPosition: 0, rate: 1.0))
    let flag = Self.trackFirstChange { controller.quickActions.rate }

    controller.send(.setRate(1.5))

    #expect(controller.quickActions.rate == 1.5)
    #expect(flag.didChange, "a changed rate must invalidate the menu projection")
  }

  @Test func changingSleepTimerModeInvalidatesQuickActionsState() {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let controller = PlayerController(engine: engine, clock: clock)

    controller.send(.load(item: Self.item(), initialGlobalPosition: 0, rate: 1.0))
    let onFlag = Self.trackFirstChange { controller.quickActions.sleepTimerMode }

    controller.send(.setSleepTimer(.fifteenMinutes))

    #expect(controller.quickActions.sleepTimerMode == .countdown(configuredSeconds: 900))
    #expect(controller.quickActions.isSleepTimerActive)
    #expect(onFlag.didChange, "starting a timer must invalidate the menu projection")

    let offFlag = Self.trackFirstChange { controller.quickActions.isSleepTimerActive }
    controller.send(.setSleepTimer(.off))

    #expect(controller.quickActions.sleepTimerMode == .off)
    #expect(controller.quickActions.isSleepTimerActive == false)
    #expect(offFlag.didChange, "stopping a timer must invalidate the menu projection")
  }

  @Test func equalSleepTimerStateReassignmentDoesNotInvalidateTheTimerProjection() async {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let controller = PlayerController(engine: engine, clock: clock)
    var events = controller.progressEvents.makeAsyncIterator()

    controller.send(.load(item: Self.item(), initialGlobalPosition: 0, rate: 1.0))
    _ = await events.next()
    controller.send(.setSleepTimer(.endOfChapter))
    let flag = Self.trackFirstChange { controller.quickActionsSleepTimer }

    clock.advance(by: 0.5)
    engine.emit(.positionUpdated(generation: 1, localOffset: 0.5))
    _ = await events.next()

    #expect(controller.quickActionsSleepTimer.mode == .endOfChapter(atPosition: 50))
    #expect(flag.didChange == false, "equal timer values must not notify their observers")
  }

  @Test func countdownTicksUpdateTheTimerProjectionWithoutInvalidatingMenuStructure() async {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let controller = PlayerController(engine: engine, clock: clock)
    var events = controller.progressEvents.makeAsyncIterator()

    controller.send(.load(item: Self.item(), initialGlobalPosition: 0, rate: 1.0))
    _ = await events.next()
    engine.emit(.ready(generation: 1))
    _ = await events.next()
    // The countdown only spends listening time, so the projection can only move under playback.
    controller.send(.play)
    _ = await events.next()
    controller.send(.setSleepTimer(.custom(seconds: 60)))
    let menuFlag = Self.trackFirstChange { controller.quickActions }
    let timerFlag = Self.trackFirstChange { controller.quickActionsSleepTimer }

    clock.advance(by: 1)
    engine.emit(.positionUpdated(generation: 1, localOffset: 1))
    _ = await events.next()

    #expect(controller.quickActionsSleepTimer.mode == .countdown(remainingSeconds: 59))
    #expect(timerFlag.didChange)
    #expect(menuFlag.didChange == false, "countdown text must not rebuild menu sources")
  }
}
