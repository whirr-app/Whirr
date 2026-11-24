import TestSupport
import Testing

@testable import PlayerCore

/// The memory itself: what the listener last chose, when it ran out, and whether a resume at a
/// given moment may bring it back.
@Suite struct SleepTimerResumeGraceTests {
  @Test func restoresTheChoiceWhenResumedInsideTheWindow() {
    var grace = SleepTimerResumeGrace()
    grace.timerChosen(.thirtyMinutes)
    grace.timerExpired(at: 1_000)

    #expect(grace.takeRestorableChoice(at: 1_299, window: 300) == .thirtyMinutes)
  }

  @Test func theWindowIncludesItsOwnEdge() {
    var grace = SleepTimerResumeGrace()
    grace.timerChosen(.fifteenMinutes)
    grace.timerExpired(at: 1_000)

    #expect(grace.takeRestorableChoice(at: 1_300, window: 300) == .fifteenMinutes)
  }

  @Test func restoresNothingOnceTheWindowHasPassed() {
    var grace = SleepTimerResumeGrace()
    grace.timerChosen(.fifteenMinutes)
    grace.timerExpired(at: 1_000)

    #expect(grace.takeRestorableChoice(at: 1_301, window: 300) == nil)
  }

  @Test func aZeroWindowIsOff() {
    var grace = SleepTimerResumeGrace()
    grace.timerChosen(.fifteenMinutes)
    grace.timerExpired(at: 1_000)

    #expect(grace.takeRestorableChoice(at: 1_000, window: 0) == nil)
  }

  @Test func choosingOffForgetsAnExpiredTimer() {
    var grace = SleepTimerResumeGrace()
    grace.timerChosen(.fifteenMinutes)
    grace.timerExpired(at: 1_000)
    grace.timerChosen(.off)

    #expect(grace.takeRestorableChoice(at: 1_010, window: 300) == nil)
  }

  @Test func choosingAnotherTimerReplacesTheExpiredOne() {
    var grace = SleepTimerResumeGrace()
    grace.timerChosen(.fifteenMinutes)
    grace.timerExpired(at: 1_000)
    grace.timerChosen(.endOfChapter)

    // The new timer is running, not expired, so there is nothing to restore yet.
    #expect(grace.takeRestorableChoice(at: 1_010, window: 300) == nil)
    grace.timerExpired(at: 2_000)
    #expect(grace.takeRestorableChoice(at: 2_010, window: 300) == .endOfChapter)
  }

  @Test func aRestoredChoiceIsUsedUp() {
    var grace = SleepTimerResumeGrace()
    grace.timerChosen(.fifteenMinutes)
    grace.timerExpired(at: 1_000)

    #expect(grace.takeRestorableChoice(at: 1_010, window: 300) == .fifteenMinutes)
    #expect(grace.takeRestorableChoice(at: 1_020, window: 300) == nil)
  }

  @Test func anExpiryWithNoRecordedChoiceRestoresNothing() {
    var grace = SleepTimerResumeGrace()
    grace.timerExpired(at: 1_000)

    #expect(grace.takeRestorableChoice(at: 1_010, window: 300) == nil)
  }

  @Test func aChoiceThatNeverExpiredRestoresNothing() {
    var grace = SleepTimerResumeGrace()
    grace.timerChosen(.fifteenMinutes)

    #expect(grace.takeRestorableChoice(at: 1_010, window: 300) == nil)
  }

  // MARK: - The restarted timer's marker

  @Test func aRestartedCountdownKeepsItsMarkerAcrossTicksAndLosesItWhenExtended() {
    var reducer = PlayerReducer(now: 0)
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 10_000)])
    _ = reducer.handle(
      .load(item: PlayerItem(id: "item-1", timeline: timeline), initialGlobalPosition: 0, rate: 1.0),
      now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)

    _ = reducer.restartSleepTimerOnResume(.fifteenMinutes, now: 0)
    #expect(reducer.state.sleepTimer.restartedOnResume)
    #expect(reducer.state.sleepTimer.configuredSeconds == 900)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 10), now: 10)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 890))
    #expect(reducer.state.sleepTimer.restartedOnResume)

    _ = reducer.handle(.extendSleepTimer(by: 300), now: 10)
    #expect(reducer.state.sleepTimer.restartedOnResume == false)
  }

  @Test func aTimerTheListenerChoseIsNotMarkedAsRestarted() {
    var reducer = PlayerReducer(now: 0)
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 10_000)])
    _ = reducer.handle(
      .load(item: PlayerItem(id: "item-1", timeline: timeline), initialGlobalPosition: 0, rate: 1.0),
      now: 0)
    _ = reducer.restartSleepTimerOnResume(.fifteenMinutes, now: 0)

    _ = reducer.handle(.setSleepTimer(.thirtyMinutes), now: 0)

    #expect(reducer.state.sleepTimer.restartedOnResume == false)
  }
}

/// The wiring: `PlayerController` remembers the choice, notices the expiry, and restarts the timer
/// on the resume that falls inside the window the preference allows.
@MainActor
@Suite struct PlayerControllerSleepTimerResumeTests {
  private static func item(id: String = "item-1", chapters: [PlaybackChapter] = []) -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 10_000)])
    return PlayerItem(id: id, timeline: timeline, chapters: PlaybackChapterMap(chapters: chapters))
  }

  private struct Harness {
    let controller: PlayerController
    let engine: FakeAudioEngine
    let clock: ManualClock
    let preferences: FakePlaybackPreferences
  }

  /// Loaded, ready and playing at uptime 0, with the resume window set to `graceSeconds`.
  private static func playing(
    _ item: PlayerItem = item(), graceSeconds: Double = 300
  ) async -> Harness {
    let engine = FakeAudioEngine()
    let clock = ManualClock(now: 0)
    let preferences = FakePlaybackPreferences()
    preferences.sleepTimerResumeGraceSeconds = graceSeconds
    let controller = PlayerController(engine: engine, clock: clock, preferences: preferences)
    var events = controller.progressEvents.makeAsyncIterator()
    controller.send(.load(item: item, initialGlobalPosition: 0, rate: 1.0))
    _ = await events.next()  // preparing
    engine.emit(.ready(generation: 1))
    _ = await events.next()  // ready — the listener task has applied it
    controller.send(.play)
    return Harness(controller: controller, engine: engine, clock: clock, preferences: preferences)
  }

  /// Runs a countdown out: lets `seconds` of playback pass, then sends an intent that advances
  /// the sleep timer and changes nothing else (the rate it already has).
  private static func runOut(_ harness: Harness, after seconds: Double) {
    harness.clock.advance(by: seconds)
    harness.controller.send(.setRate(1.0))
  }

  @Test func resumingInsideTheWindowRestartsTheOriginalCountdown() async {
    let harness = await Self.playing()
    harness.controller.send(.setSleepTimer(.fifteenMinutes))
    Self.runOut(harness, after: 900)
    #expect(harness.controller.state.isPlaybackIntended == false)
    #expect(harness.controller.quickActionsSleepTimer.mode == .off)

    harness.clock.advance(by: 120)
    harness.controller.send(.play)

    let timer = harness.controller.quickActionsSleepTimer
    #expect(harness.controller.state.isPlaybackIntended)
    #expect(timer.mode == .countdown(remainingSeconds: 900))
    #expect(timer.configuredSeconds == 900)
    #expect(timer.restartedOnResume)
    #expect(harness.engine.setVolumeCalls.last == 1.0)
  }

  @Test func toggleCountsAsAResume() async {
    let harness = await Self.playing()
    harness.controller.send(.setSleepTimer(.fifteenMinutes))
    Self.runOut(harness, after: 900)

    harness.controller.send(.toggle)

    #expect(harness.controller.quickActionsSleepTimer.mode == .countdown(remainingSeconds: 900))
  }

  @Test func resumingAfterTheWindowLeavesTheTimerOff() async {
    let harness = await Self.playing()
    harness.controller.send(.setSleepTimer(.fifteenMinutes))
    Self.runOut(harness, after: 900)

    harness.clock.advance(by: 301)
    harness.controller.send(.play)

    #expect(harness.controller.state.isPlaybackIntended)
    #expect(harness.controller.quickActionsSleepTimer.mode == .off)
  }

  /// Uptime stops while the phone sleeps, so a night spent paused can read as seconds of it. The
  /// window has to be judged on time that kept running, or a morning resume would restart a timer.
  @Test func timeTheDeviceSpentAsleepCountsAgainstTheWindow() async {
    let harness = await Self.playing()
    harness.controller.send(.setSleepTimer(.fifteenMinutes))
    Self.runOut(harness, after: 900)

    harness.clock.sleepDevice(for: 8 * 60 * 60)
    harness.clock.advance(by: 5)
    harness.controller.send(.play)

    #expect(harness.controller.quickActionsSleepTimer.mode == .off)
  }

  @Test func theSettingOffNeverRestarts() async {
    let harness = await Self.playing(graceSeconds: 0)
    harness.controller.send(.setSleepTimer(.fifteenMinutes))
    Self.runOut(harness, after: 900)

    harness.controller.send(.play)

    #expect(harness.controller.quickActionsSleepTimer.mode == .off)
  }

  @Test func aSettingChangeAppliesOnTheNextResume() async {
    let harness = await Self.playing(graceSeconds: 0)
    harness.controller.send(.setSleepTimer(.fifteenMinutes))
    Self.runOut(harness, after: 900)

    harness.preferences.sleepTimerResumeGraceSeconds = 300
    harness.controller.send(.play)

    #expect(harness.controller.quickActionsSleepTimer.mode == .countdown(remainingSeconds: 900))
  }

  @Test func anExtendedTimerRestartsAtTheLengthOriginallyChosen() async {
    let harness = await Self.playing()
    harness.controller.send(.setSleepTimer(.fifteenMinutes))
    harness.controller.send(.extendSleepTimer(by: 600))
    Self.runOut(harness, after: 1_500)
    #expect(harness.controller.quickActionsSleepTimer.mode == .off)

    harness.controller.send(.play)

    #expect(harness.controller.quickActionsSleepTimer.mode == .countdown(remainingSeconds: 900))
    #expect(harness.controller.quickActionsSleepTimer.configuredSeconds == 900)
  }

  @Test func aCustomLengthRestartsAsItself() async {
    let harness = await Self.playing()
    harness.controller.send(.setSleepTimer(.custom(seconds: 1_200)))
    Self.runOut(harness, after: 1_200)

    harness.controller.send(.play)

    #expect(harness.controller.quickActionsSleepTimer.mode == .countdown(remainingSeconds: 1_200))
  }

  @Test func resumingADifferentItemInsideTheWindowStillRestarts() async {
    let harness = await Self.playing()
    harness.controller.send(.setSleepTimer(.fifteenMinutes))
    Self.runOut(harness, after: 900)

    var events = harness.controller.progressEvents.makeAsyncIterator()
    harness.controller.send(.load(item: Self.item(id: "item-2"), initialGlobalPosition: 0, rate: 1.0))
    harness.engine.emit(.ready(generation: 2))
    while let event = await events.next(), event.phase != .ready {}
    harness.controller.send(.play)

    #expect(harness.controller.state.item?.id == "item-2")
    #expect(harness.controller.quickActionsSleepTimer.mode == .countdown(remainingSeconds: 900))
  }

  @Test func choosingOffAfterTheExpiryForgetsIt() async {
    let harness = await Self.playing()
    harness.controller.send(.setSleepTimer(.fifteenMinutes))
    Self.runOut(harness, after: 900)

    harness.controller.send(.setSleepTimer(.off))
    harness.controller.send(.play)

    #expect(harness.controller.quickActionsSleepTimer.mode == .off)
  }

  @Test func aSecondResumeAfterAManualPauseDoesNotRestartAgain() async {
    let harness = await Self.playing()
    harness.controller.send(.setSleepTimer(.fifteenMinutes))
    Self.runOut(harness, after: 900)
    harness.controller.send(.play)
    harness.controller.send(.setSleepTimer(.off))

    harness.controller.send(.pause)
    harness.controller.send(.play)

    #expect(harness.controller.quickActionsSleepTimer.mode == .off)
  }

  @Test func restartsChainWhenTheRestartedTimerAlsoRunsOut() async {
    let harness = await Self.playing()
    harness.controller.send(.setSleepTimer(.fifteenMinutes))
    Self.runOut(harness, after: 900)
    harness.controller.send(.play)

    Self.runOut(harness, after: 900)
    #expect(harness.controller.state.isPlaybackIntended == false)
    harness.controller.send(.play)

    #expect(harness.controller.quickActionsSleepTimer.mode == .countdown(remainingSeconds: 900))
  }

  @Test func endOfChapterRestartsAtTheEndOfTheChapterNowPlaying() async {
    let chapters = [
      PlaybackChapter(start: 0, end: 1_000),
      PlaybackChapter(start: 1_000, end: 3_000),
      PlaybackChapter(start: 3_000, end: 10_000),
    ]
    let harness = await Self.playing(Self.item(chapters: chapters))
    harness.controller.send(.setSleepTimer(.endOfChapter))
    harness.clock.advance(by: 1_000)
    harness.engine.emit(.positionUpdated(generation: 1, localOffset: 1_000))
    var events = harness.controller.progressEvents.makeAsyncIterator()
    while let event = await events.next(), event.sleepTimerExpiry != .expired {}
    #expect(harness.controller.state.isPlaybackIntended == false)

    harness.controller.send(.play)

    #expect(harness.controller.quickActionsSleepTimer.mode == .endOfChapter(atPosition: 3_000))
    #expect(harness.controller.quickActionsSleepTimer.restartedOnResume)
  }

  @Test func aResumeWhileATimerIsRunningLeavesItAlone() async {
    let harness = await Self.playing()
    harness.controller.send(.setSleepTimer(.fifteenMinutes))
    Self.runOut(harness, after: 900)
    harness.controller.send(.setSleepTimer(.sixtyMinutes))

    harness.controller.send(.play)

    #expect(harness.controller.quickActionsSleepTimer.mode == .countdown(remainingSeconds: 3_600))
    #expect(harness.controller.quickActionsSleepTimer.restartedOnResume == false)
  }
}
