import Testing

@testable import PlayerCore

/// The time saved against playing the original at 1×: speed gained over
/// credited listening, and the source seconds Trim Silences cut. Both ride on every event that
/// carries credit, including the ones the reducer rebuilds field by field.
@Suite struct TimeSavedReducerTests {
  /// Cuts at 10-12 and 20-21.
  private static let map = PlayerTrimMap(cuts: [
    PlayerTrimMap.Cut(start: 10, end: 12), PlayerTrimMap.Cut(start: 20, end: 21),
  ])
  private static let item = PlayerItem(
    id: "item-1", episodeID: "episode-1",
    timeline: try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 1000)]))

  /// Loaded at 0, ready and playing at `now == 0`.
  private static func playingReducer(
    item: PlayerItem = item, trim: PlayerTrimMap? = nil, rate: Double = 1
  ) -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: rate, trim: trim), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    return reducer
  }

  private static func speedSaved(_ result: PlayerStepResult) -> Double {
    result.progressEvents.map(\.speedSavedDelta).reduce(0, +)
  }

  // MARK: - Speed

  @Test func atNormalSpeedNothingIsSaved() {
    var reducer = Self.playingReducer()
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 2), now: 2)

    #expect(result.progressEvents.map(\.listenedDelta) == [2])
    #expect(Self.speedSaved(result) == 0)
  }

  @Test func fasterThanNormalSavesTheDifference() {
    var reducer = Self.playingReducer(rate: 1.5)
    // Two wall seconds at 1.5× cover three seconds of audio: one saved.
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 3), now: 2)

    #expect(result.progressEvents.map(\.listenedDelta) == [2])
    #expect(Self.speedSaved(result) == 1)
  }

  @Test func slowerThanNormalSavesNothing() {
    var reducer = Self.playingReducer(rate: 0.8)
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 1.6), now: 2)

    #expect(result.progressEvents.map(\.listenedDelta) == [2])
    #expect(Self.speedSaved(result) == 0)
  }

  @Test func aRateChangeCreditsTheIntervalAtTheOldRate() {
    var reducer = Self.playingReducer(rate: 2)
    let result = reducer.handle(.setRate(1), now: 2)

    #expect(result.progressEvents.map(\.listenedDelta) == [2])
    #expect(Self.speedSaved(result) == 2)
  }

  @Test func aLoadRateBeyondTheSupportedRangeIsClamped() {
    var reducer = Self.playingReducer(rate: 4)
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 4), now: 1)

    #expect(result.progressEvents.map(\.listenedDelta) == [1])
    #expect(Self.speedSaved(result) == PlayerReducer.supportedRateRange.upperBound - 1)
  }

  @Test func aTickThatJumpedSavesNothing() {
    var reducer = Self.playingReducer(rate: 2)
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 40), now: 1)

    #expect(result.progressEvents.map(\.listenedDelta) == [0])
    #expect(Self.speedSaved(result) == 0)
  }

  @Test func aSeekSavesOnlyForTheTimePlayedBeforeIt() {
    var reducer = Self.playingReducer(rate: 2)
    let result = reducer.handle(.seek(toGlobalOffset: 500), now: 3)

    #expect(result.progressEvents.map(\.listenedDelta).reduce(0, +) == 3)
    #expect(Self.speedSaved(result) == 3)
  }

  @Test func stopSavesForTheTimePlayedBeforeIt() {
    var reducer = Self.playingReducer(rate: 2)
    let result = reducer.handle(.stop, now: 3)

    #expect(result.progressEvents.map(\.listenedDelta) == [3])
    #expect(Self.speedSaved(result) == 3)
  }

  // MARK: - Silence

  @Test func aCutIsCountedInSourceSecondsWhateverTheRate() {
    var reducer = Self.playingReducer(trim: Self.map, rate: 2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 9), now: 4.5)

    // One wall second at 2× from 9 crosses the 2 s cut at 10-12 and reaches 13.
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 13), now: 5.5)

    #expect(result.progressEvents.map(\.trimmedDelta) == [1])
    #expect(result.progressEvents.map(\.trimmedSourceDelta) == [2])
    #expect(Self.speedSaved(result) == 1)
  }

  @Test func withoutAMapNothingIsTrimmed() {
    var reducer = Self.playingReducer(rate: 2)
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 4), now: 2)

    #expect(result.progressEvents.map(\.trimmedSourceDelta) == [0])
  }

  // MARK: - Rebuilt events keep the figures

  @Test func reportingARangeKeepsTheTimeSaved() {
    let event = PlaybackProgressEvent(
      sequence: 1, itemId: "item-1", phase: .playing, currentTime: 13, listenedDelta: 2,
      trimmedDelta: 1, speedSavedDelta: 2, trimmedSourceDelta: 2)

    let receipt = event.reporting(PlayerSkipRange(start: 30, end: 50, endsItem: false))

    #expect(receipt.speedSavedDelta == 2)
    #expect(receipt.trimmedSourceDelta == 2)
  }

  @Test func theTimeSavedSurvivesASleepTimerExpiry() {
    var reducer = Self.playingReducer(trim: Self.map, rate: 2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 9), now: 4.5)
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 1)), now: 4.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 13), now: 5.5)

    #expect(result.progressEvents.contains { $0.sleepTimerExpiry == .expired })
    #expect(result.progressEvents.map(\.trimmedSourceDelta).reduce(0, +) == 2)
    #expect(Self.speedSaved(result) == 1)
  }

  @Test func theTimeSavedSurvivesAnEndOfItemSleepBoundary() {
    let item = PlayerItem(
      id: "item-1", episodeID: "episode-1",
      timeline: try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 14)]))
    var reducer = Self.playingReducer(item: item, trim: Self.map, rate: 2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 9), now: 4.5)
    _ = reducer.handle(.setSleepTimer(.endOfItem), now: 4.5)

    // 1.5 wall seconds at 2× from 9 cross the 2 s cut and reach the end at 14.
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 14), now: 6)

    #expect(result.progressEvents.contains { $0.phase == .ended })
    #expect(result.progressEvents.map(\.trimmedSourceDelta).reduce(0, +) == 2)
    #expect(Self.speedSaved(result) == 1.5)
  }

  @Test func theTimeSavedSurvivesReachingASegmentEnd() {
    var reducer = Self.playingReducer(rate: 2)
    _ = reducer.handle(.setSegment(start: 0, end: 10), now: 0)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 10), now: 5)

    #expect(result.progressEvents.contains { $0.segmentEnd == .reached })
    #expect(Self.speedSaved(result) == 5)
  }

  @Test func theTimeSavedSurvivesASkipThatEndsTheItem() {
    var reducer = Self.playingReducer(rate: 2)
    // Two wall seconds at 2× reach 4; skipping past the end completes the item.
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 4), now: 2)
    let result = reducer.handle(.skip(by: 2_000), now: 3)

    #expect(result.progressEvents.contains { $0.phase == .ended })
    #expect(Self.speedSaved(result) == 1)
  }
}
