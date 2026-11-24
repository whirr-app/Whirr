import Testing

@testable import PlayerCore

/// Trim Silences in the reducer: the reducer stays in source time,
/// predicts ticks through the map so a splice is not read as a jump, reloads the engine when the
/// map changes, and reports the time cutting saved.
@Suite struct TrimSilencesReducerTests {
  /// Cuts at 10-12 and 20-21.
  private static let map = PlayerTrimMap(cuts: [
    PlayerTrimMap.Cut(start: 10, end: 12), PlayerTrimMap.Cut(start: 20, end: 21),
  ])
  private static let item = PlayerItem(
    id: "item-1", episodeID: "episode-1",
    timeline: try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 1000)]))
  private static let track = PlaybackTrack(index: 0, duration: 1000)

  private static func setMap(_ map: PlayerTrimMap?) -> PlayerIntent {
    .setTrimMap(itemID: item.id, episodeID: item.episodeID, map: map)
  }

  /// Loaded at 0, ready and playing at `now == 0`.
  private static func playingReducer(trim: PlayerTrimMap? = nil, rate: Double = 1) -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: rate, trim: trim), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    return reducer
  }

  private static func loads(_ result: PlayerStepResult) -> [PlayerEffect] {
    result.effects.filter {
      if case .loadEngine = $0 { true } else { false }
    }
  }

  // MARK: - Accounting

  @Test func aTickAcrossACutIsCreditedAndReportsTheTimeSaved() {
    var reducer = Self.playingReducer(trim: Self.map)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 9), now: 9)

    // Two played seconds from 9 cross the 2 s cut at 10-12 and reach source 13.
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 13), now: 11)

    #expect(result.progressEvents.map(\.currentTime) == [13])
    #expect(result.progressEvents.map(\.listenedDelta) == [2])
    #expect(result.progressEvents.map(\.trimmedDelta) == [2])
  }

  @Test func theTimeSavedIsWallTimeAtTheCurrentRate() {
    var reducer = Self.playingReducer(trim: Self.map, rate: 2)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 9), now: 4.5)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 13), now: 5.5)

    #expect(result.progressEvents.map(\.listenedDelta) == [1])
    #expect(result.progressEvents.map(\.trimmedDelta) == [1])
  }

  @Test func withoutAMapTheSameTickIsAJump() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 9), now: 9)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 13), now: 11)

    #expect(result.progressEvents.map(\.listenedDelta) == [0])
    #expect(result.progressEvents.map(\.trimmedDelta) == [0])
  }

  @Test func aRealJumpWithAMapIsNotCredited() {
    var reducer = Self.playingReducer(trim: Self.map)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 9), now: 9)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 40), now: 10)

    #expect(reducer.state.globalPosition == 40)
    #expect(result.progressEvents.map(\.listenedDelta) == [0])
    #expect(result.progressEvents.map(\.trimmedDelta) == [0])
  }

  @Test func aTickInKeptAudioSavesNothing() {
    var reducer = Self.playingReducer(trim: Self.map)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 5), now: 5)

    #expect(result.progressEvents.map(\.listenedDelta) == [5])
    #expect(result.progressEvents.map(\.trimmedDelta) == [0])
  }

  // MARK: - Load and seek

  @Test func aLoadCarriesTheMapAndSnapsAResumePointOutOfACut() {
    var reducer = PlayerReducer(now: 0)

    let result = reducer.handle(
      .load(item: Self.item, initialGlobalPosition: 11, rate: 1, trim: Self.map), now: 0)

    #expect(reducer.state.globalPosition == 12)
    #expect(
      Self.loads(result) == [.loadEngine(track: Self.track, localOffset: 12, rate: 1, generation: 1, trim: Self.map)])
  }

  @Test func aLoadWithoutAMapSendsNone() {
    var reducer = PlayerReducer(now: 0)

    let result = reducer.handle(.load(item: Self.item, initialGlobalPosition: 11, rate: 1), now: 0)

    #expect(reducer.state.globalPosition == 11)
    #expect(Self.loads(result) == [.loadEngine(track: Self.track, localOffset: 11, rate: 1, generation: 1)])
  }

  @Test func anEmptyMapIsNoMap() {
    var reducer = PlayerReducer(now: 0)

    let result = reducer.handle(
      .load(item: Self.item, initialGlobalPosition: 0, rate: 1, trim: PlayerTrimMap(cuts: [])), now: 0)

    #expect(Self.loads(result) == [.loadEngine(track: Self.track, localOffset: 0, rate: 1, generation: 1)])
  }

  @Test func aSeekIntoACutLandsAtItsEnd() {
    var reducer = Self.playingReducer(trim: Self.map)

    let seek = reducer.handle(.seek(toGlobalOffset: 11), now: 1)
    let landed = reducer.handle(.positionUpdated(generation: 1, localOffset: 12), now: 1.2)

    #expect(seek.effects.contains(.seekEngine(localOffset: 12)))
    #expect(landed.progressEvents.map(\.currentTime) == [12])
    #expect(reducer.state.phase == .playing)
  }

  /// The engine reports a cut's end for any target inside it. A cut longer than the 15 s landing
  /// tolerance would leave an unsnapped seek waiting for a landing it never recognises.
  @Test func aSeekIntoACutLongerThanTheLandingToleranceLands() {
    let long = PlayerTrimMap(cuts: [PlayerTrimMap.Cut(start: 100, end: 130)])
    var reducer = Self.playingReducer(trim: long)

    _ = reducer.handle(.seek(toGlobalOffset: 101), now: 1)
    let landed = reducer.handle(.positionUpdated(generation: 1, localOffset: 130), now: 1.2)

    #expect(landed.progressEvents.map(\.currentTime) == [130])
    #expect(reducer.state.phase == .playing)
  }

  // MARK: - Opening cut

  /// A cut at 0-0.82, as the planner makes from a file that opens with silence.
  private static let openingCut = PlayerTrimMap(cuts: [PlayerTrimMap.Cut(start: 0, end: 0.82)])

  private static func pausedReducer(trim: PlayerTrimMap) -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1, trim: trim), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    return reducer
  }

  /// Resetting the loaded episode seeks it to 0, which lands at the opening cut's end. Reporting
  /// that landing as progress would put the episode straight back on Continue Listening.
  @Test func aSeekToTheStartReportsZeroWhenTheFileOpensWithACut() {
    var reducer = Self.pausedReducer(trim: Self.openingCut)
    _ = reducer.handle(.seek(toGlobalOffset: 30), now: 1)

    let seek = reducer.handle(.seek(toGlobalOffset: 0), now: 2)

    #expect(seek.effects.contains(.seekEngine(localOffset: 0.82)))
    #expect(reducer.state.globalPosition == 0.82)
    #expect(seek.progressEvents.map(\.currentTime) == [0])
  }

  @Test func pausingAtTheOpeningCutsEndReportsZero() {
    var reducer = Self.playingReducer(trim: Self.openingCut)

    let pause = reducer.handle(.pause, now: 0.1)

    #expect(reducer.state.globalPosition == 0.82)
    #expect(pause.progressEvents.map(\.currentTime) == [0])
  }

  @Test func aTickPastTheOpeningCutReportsItsPosition() {
    var reducer = Self.playingReducer(trim: Self.openingCut)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 1.82), now: 1)

    #expect(result.progressEvents.map(\.currentTime) == [1.82])
  }

  @Test func aCutLaterInTheFileIsReportedAsItsEnd() {
    var reducer = Self.pausedReducer(trim: Self.map)

    let seek = reducer.handle(.seek(toGlobalOffset: 11), now: 1)

    #expect(seek.progressEvents.map(\.currentTime) == [12])
  }

  // MARK: - Reload on a change

  @Test func aMapArrivingWhilePlayingReloadsAndKeepsPlaying() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 15), now: 15)

    let reload = reducer.handle(Self.setMap(Self.map), now: 15.5)

    #expect(
      Self.loads(reload) == [.loadEngine(track: Self.track, localOffset: 15, rate: 1, generation: 2, trim: Self.map)])
    #expect(reducer.state.phase == .seeking)
    #expect(reducer.state.isPlaybackIntended)
    #expect(reload.progressEvents.map(\.listenedDelta) == [0.5])

    let ready = reducer.handle(.ready(generation: 2), now: 15.6)

    #expect(ready.effects.contains(.play))
    #expect(reducer.state.phase == .playing)
  }

  @Test func aMapArrivingWhilePausedReloadsAndStaysPaused() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 15), now: 15)
    _ = reducer.handle(.pause, now: 15)

    let reload = reducer.handle(Self.setMap(Self.map), now: 16)
    let ready = reducer.handle(.ready(generation: 2), now: 16.1)

    #expect(Self.loads(reload).count == 1)
    #expect(reducer.state.isPlaybackIntended == false)
    #expect(ready.effects.contains(.pause))
    #expect(ready.effects.contains(.play) == false)
    #expect(reducer.state.phase == .paused)
  }

  @Test func aReloadFromInsideACutStartsAtItsEnd() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 11), now: 11)

    let reload = reducer.handle(Self.setMap(Self.map), now: 11)

    #expect(reducer.state.globalPosition == 12)
    #expect(
      Self.loads(reload) == [.loadEngine(track: Self.track, localOffset: 12, rate: 1, generation: 2, trim: Self.map)])
  }

  @Test func turningTrimOffReloadsWithoutAMap() {
    var reducer = Self.playingReducer(trim: Self.map)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 15), now: 13)

    let reload = reducer.handle(Self.setMap(nil), now: 13)

    #expect(Self.loads(reload) == [.loadEngine(track: Self.track, localOffset: 15, rate: 1, generation: 2)])
  }

  @Test func theSameMapAgainDoesNotReload() {
    var reducer = Self.playingReducer(trim: Self.map)

    let result = reducer.handle(Self.setMap(Self.map), now: 1)

    #expect(result.effects.isEmpty)
  }

  @Test func aMapForAnotherEpisodeIsIgnored() {
    var reducer = Self.playingReducer()

    let result = reducer.handle(.setTrimMap(itemID: Self.item.id, episodeID: "episode-2", map: Self.map), now: 1)

    #expect(result.effects.isEmpty)
    #expect(reducer.trim.map == nil)
  }

  @Test func aMultiTrackItemIsNeverTrimmed() {
    let item = PlayerItem(
      id: "book",
      timeline: try! PlaybackTimeline(tracks: [
        PlaybackTrack(index: 0, duration: 100), PlaybackTrack(index: 1, duration: 100),
      ]))
    var reducer = PlayerReducer(now: 0)
    let load = reducer.handle(.load(item: item, initialGlobalPosition: 11, rate: 1, trim: Self.map), now: 0)

    let result = reducer.handle(.setTrimMap(itemID: "book", episodeID: nil, map: nil), now: 1)

    #expect(reducer.state.globalPosition == 11)
    #expect(
      Self.loads(load) == [
        .loadEngine(track: PlaybackTrack(index: 0, duration: 100), localOffset: 11, rate: 1, generation: 1)
      ])
    #expect(result.effects.isEmpty)
  }

  @Test func rangesAndTheSleepTimerSurviveAReload() {
    let ad = PlayerSkipRange(start: 30, end: 50, endsItem: false)
    var reducer = Self.playingReducer()
    _ = reducer.handle(
      .setSkipRanges(itemID: Self.item.id, episodeID: Self.item.episodeID, ranges: [ad]), now: 0)
    _ = reducer.handle(.setSleepTimer(.thirtyMinutes), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 15), now: 15)

    _ = reducer.handle(Self.setMap(Self.map), now: 15)
    _ = reducer.handle(.ready(generation: 2), now: 15.1)

    #expect(reducer.skipRanges == [ad])
    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 1800 - 15))
    #expect(reducer.state.sleepTimer.configuredSeconds == 1800)
  }

  @Test func aReloadKeepsTheLandingFloorOfASkipInFlight() {
    let ad = PlayerSkipRange(start: 30, end: 50, endsItem: false)
    var reducer = Self.playingReducer()
    _ = reducer.handle(
      .setSkipRanges(itemID: Self.item.id, episodeID: Self.item.episodeID, ranges: [ad]), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 29.5), now: 29.5)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 30.2), now: 30.2)

    _ = reducer.handle(Self.setMap(Self.map), now: 30.3)

    #expect(reducer.skip.landingFloor == 50 - PlayerReducer.skipLandingMargin)
  }

  @Test func anEndedItemStoresTheMapWithoutReloading() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.skip(by: 2000), now: 1)
    #expect(reducer.state.phase == .ended)

    let result = reducer.handle(Self.setMap(Self.map), now: 2)

    #expect(result.effects.isEmpty)
    #expect(result.progressEvents.isEmpty)
    #expect(reducer.trim.map == Self.map)
  }

  @Test func ticksFromBeforeAReloadAreDropped() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 15), now: 15)
    _ = reducer.handle(Self.setMap(Self.map), now: 15)

    let stale = reducer.handle(.positionUpdated(generation: 1, localOffset: 15.4), now: 15.4)

    #expect(stale.progressEvents.isEmpty)
    #expect(reducer.state.globalPosition == 15)
    #expect(reducer.state.phase == .seeking)
  }

  // MARK: - Declined

  @Test func aDeclinedMapIsDroppedWithoutAReload() {
    var reducer = Self.playingReducer(trim: Self.map)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 9), now: 9)

    let declined = reducer.handle(.trimDeclined(generation: 1), now: 9)
    // The engine plays the plain file, so plain playback is what is credited.
    let tick = reducer.handle(.positionUpdated(generation: 1, localOffset: 11), now: 11)

    #expect(Self.loads(declined).isEmpty)
    #expect(reducer.trim.map == nil)
    #expect(tick.progressEvents.map(\.listenedDelta) == [2])
    #expect(tick.progressEvents.map(\.trimmedDelta) == [0])
  }

  @Test func aDeclineFromAnEarlierGenerationIsIgnored() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(Self.setMap(Self.map), now: 1)

    _ = reducer.handle(.trimDeclined(generation: 1), now: 1.1)

    #expect(reducer.trim.map == Self.map)
  }

  // MARK: - Time saved survives rebuilt events

  @Test func theTimeSavedSurvivesASkipReceipt() {
    let ad = PlayerSkipRange(start: 26.5, end: 50, endsItem: false)
    let map = PlayerTrimMap(cuts: [PlayerTrimMap.Cut(start: 25, end: 26)])
    var reducer = Self.playingReducer(trim: map)
    _ = reducer.handle(
      .setSkipRanges(itemID: Self.item.id, episodeID: Self.item.episodeID, ranges: [ad]), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 24), now: 24)

    // Two played seconds from 24 cross the cut and enter the ad at 27.
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 27), now: 26)

    #expect(result.progressEvents.compactMap(\.skippedRange) == [ad])
    #expect(result.progressEvents.map(\.trimmedDelta).reduce(0, +) == 1)
  }

  @Test func reportingARangeKeepsTheTimeSaved() {
    let event = PlaybackProgressEvent(
      sequence: 1, itemId: "item-1", phase: .playing, currentTime: 13, listenedDelta: 2, trimmedDelta: 2)

    let receipt = event.reporting(PlayerSkipRange(start: 30, end: 50, endsItem: false))

    #expect(receipt.trimmedDelta == 2)
  }

  @Test func theTimeSavedSurvivesASleepTimerExpiry() {
    var reducer = Self.playingReducer(trim: Self.map)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 9), now: 9)
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 2)), now: 9)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 13), now: 11)

    #expect(result.progressEvents.contains { $0.sleepTimerExpiry == .expired })
    #expect(result.progressEvents.map(\.trimmedDelta).reduce(0, +) == 2)
  }

  @Test func theTimeSavedSurvivesAnEndOfItemSleepBoundary() {
    let item = PlayerItem(
      id: "item-1", episodeID: "episode-1",
      timeline: try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 14)]))
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1, trim: Self.map), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 9), now: 9)
    _ = reducer.handle(.setSleepTimer(.endOfItem), now: 9)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 14), now: 12)

    #expect(result.progressEvents.contains { $0.phase == .ended })
    #expect(result.progressEvents.map(\.trimmedDelta).reduce(0, +) == 2)
  }
}
