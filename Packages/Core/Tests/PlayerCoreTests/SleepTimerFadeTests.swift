import Testing

@testable import PlayerCore

@Suite struct SleepTimerFadeTests {

  @Test func curveIsFullVolumeAtOrAboveTheWindow() {
    #expect(SleepTimerFade.volume(remainingSeconds: SleepTimerFade.windowSeconds) == 1.0)
    #expect(SleepTimerFade.volume(remainingSeconds: SleepTimerFade.windowSeconds + 1) == 1.0)
  }

  @Test func curveSquaresTheMidWindowFraction() {
    #expect(SleepTimerFade.volume(remainingSeconds: SleepTimerFade.windowSeconds / 2) == 0.25)
  }

  @Test func curveIsSilentAtOrBelowExpiry() {
    #expect(SleepTimerFade.volume(remainingSeconds: 0) == 0.0)
    #expect(SleepTimerFade.volume(remainingSeconds: -1) == 0.0)
  }

  @Test func curveTreatsNonFiniteInputAsFullVolume() {
    #expect(SleepTimerFade.volume(remainingSeconds: .nan) == 1.0)
    #expect(SleepTimerFade.volume(remainingSeconds: .infinity) == 1.0)
    #expect(SleepTimerFade.volume(remainingSeconds: -.infinity) == 1.0)
  }

  @Test func countdownFadeDecreasesThroughTheWindowAndReachesZeroAtExpiry() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 60)), now: 0)

    let first = reducer.handle(.positionUpdated(generation: 1, localOffset: 49), now: 49)
    let second = reducer.handle(.positionUpdated(generation: 1, localOffset: 53), now: 53)
    let third = reducer.handle(.positionUpdated(generation: 1, localOffset: 57), now: 57)
    let expiry = reducer.handle(.positionUpdated(generation: 1, localOffset: 60), now: 60)

    let fadeValues = [first, second, third, expiry].flatMap(Self.volumeEffects)
    let fadeValuesBeforeRestore = Array(fadeValues.dropLast())
    #expect(
      fadeValuesBeforeRestore == [
        SleepTimerFade.volume(remainingSeconds: 11),
        SleepTimerFade.volume(remainingSeconds: 7),
        SleepTimerFade.volume(remainingSeconds: 3),
        0,
      ])
    #expect(zip(fadeValuesBeforeRestore, fadeValuesBeforeRestore.dropFirst()).allSatisfy { $0 >= $1 })
    #expect(expiry.effects.suffix(2) == [.pause, .setVolume(1.0)])
    #expect(reducer.state.volume == 1.0)
  }

  @Test func countdownOutsideTheWindowDoesNotEmitVolumeEffects() {
    var reducer = Self.playingReducer()
    let set = reducer.handle(.setSleepTimer(.custom(seconds: 60)), now: 0)
    // 16 s left: one second outside the window, so this pins the boundary rather than a wide gap.
    let tick = reducer.handle(.positionUpdated(generation: 1, localOffset: 44), now: 44)

    #expect(Self.volumeEffects(set).isEmpty)
    #expect(Self.volumeEffects(tick).isEmpty)
  }

  @Test func extendingMidFadeRestoresFullVolumeAfterTheTick() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 60)), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 53), now: 53)

    let result = reducer.handle(.extendSleepTimer(by: 60), now: 55)

    #expect(Self.volumeEffects(result) == [SleepTimerFade.volume(remainingSeconds: 5), 1.0])
    #expect(reducer.state.volume == 1.0)
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 65))
  }

  @Test func settingSleepTimerOffMidFadeRestoresFullVolume() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 60)), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 53), now: 53)

    let result = reducer.handle(.setSleepTimer(.off), now: 53)

    #expect(result.effects == [.setVolume(1.0)])
    #expect(reducer.state.sleepTimer.mode == .off)
    #expect(reducer.state.volume == 1.0)
  }

  @Test func expiryPausesBeforeRestoringFullVolume() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 60)), now: 0)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 60), now: 60)

    #expect(result.effects.suffix(2) == [.pause, .setVolume(1.0)])
    #expect(reducer.state.volume == 1.0)
    #expect(reducer.state.sleepTimer.mode == .off)
  }

  @Test func loadMidFadeRestoresFullVolume() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 60)), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 53), now: 53)
    let replacement = Self.item(id: "item-2")

    let result = reducer.handle(.load(item: replacement, initialGlobalPosition: 0, rate: 1), now: 53)

    #expect(result.effects.last == .setVolume(1.0))
    #expect(reducer.state.sleepTimer.mode == .off)
    #expect(reducer.state.volume == 1.0)
  }

  @Test func stopMidFadeRestoresFullVolume() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 60)), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 53), now: 53)

    let result = reducer.handle(.stop, now: 53)

    #expect(result.effects == [.stop, .setVolume(1.0)])
    #expect(reducer.state == .idle)
    #expect(reducer.state.volume == 1.0)
  }

  @Test func endOfChapterTimerDoesNotFadeInsideTheWindow() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 0)
    let tick = reducer.handle(.positionUpdated(generation: 1, localOffset: 95), now: 0)

    #expect(Self.volumeEffects(tick).isEmpty)
    #expect(reducer.state.volume == 1.0)
  }

  @Test func endOfItemTimerDoesNotFadeInsideTheWindow() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.setSleepTimer(.endOfItem), now: 0)
    let tick = reducer.handle(.positionUpdated(generation: 1, localOffset: 9_995), now: 0)

    #expect(Self.volumeEffects(tick).isEmpty)
    #expect(reducer.state.volume == 1.0)
  }

  @Test func plainListenWithTimerOffEmitsNoVolumeEffects() {
    var reducer = Self.playingReducer()
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 1), now: 1)

    #expect(Self.volumeEffects(result).isEmpty)
  }

  private static func item(id: String = "item-1", duration: Double = 10_000) -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: duration)])
    let chapters = PlaybackChapterMap(chapters: [PlaybackChapter(start: 0, end: 100)])
    return PlayerItem(id: id, timeline: timeline, chapters: chapters)
  }

  private static func playingReducer(rate: Double = 1) -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: Self.item(), initialGlobalPosition: 0, rate: rate), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    return reducer
  }

  private static func volumeEffects(_ result: PlayerStepResult) -> [Double] {
    result.effects.compactMap { effect in
      guard case .setVolume(let volume) = effect else { return nil }
      return volume
    }
  }
}
