import Testing

@testable import PlayerCore

@Suite struct PlayerReducerCompletionTests {

  @Test func finalTrackFinishedEventUsesTheTimelinesTotalDuration() throws {
    let item = try PlayerItem(
      id: "item-final-track",
      timeline: PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)]))
    var reducer = Self.playingReducer(item: item)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 95), now: 95)

    let result = reducer.handle(.trackFinished(generation: 1), now: 100)

    #expect(result.progressEvents.count == 1)
    #expect(result.progressEvents.first?.phase == .ended)
    #expect(result.progressEvents.first?.currentTime == item.timeline.totalDuration)
  }

  @Test func snappingTheFinalTrackToTheEndDoesNotLoseTheFinalListenedDelta() throws {
    let item = try PlayerItem(
      id: "item-final-track",
      timeline: PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)]))
    var reducer = Self.playingReducer(item: item)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 95), now: 95)

    let result = reducer.handle(.trackFinished(generation: 1), now: 100)

    #expect(result.progressEvents.first?.listenedDelta == 5)
  }

  @Test func nonFinalTrackFinishedStillAdvancesWithoutEmittingAnEndedEvent() throws {
    let item = try PlayerItem(
      id: "item-multi-track",
      timeline: PlaybackTimeline(tracks: [
        PlaybackTrack(index: 0, duration: 100), PlaybackTrack(index: 1, duration: 50),
      ]))
    var reducer = Self.playingReducer(item: item)

    let result = reducer.handle(.trackFinished(generation: 1), now: 100)

    #expect(reducer.state.phase == .preparing)
    #expect(reducer.state.currentTrackIndex == 1)
    #expect(result.progressEvents.map(\.phase) == [.playing, .preparing])
    #expect(result.progressEvents.map(\.currentTime) == [0, 0])
  }

  /// Restarting a finished book loads it at its end, so the engine reaches the end of the track the
  /// moment it is told to play. A chapter picked straight away seeks within that same track (no
  /// generation change), and the end-of-track callback already on its way must not complete the
  /// item underneath the seek. Otherwise the reducer would sit `.ended` (refusing every later
  /// event) while the engine played on from the chapter.
  @Test func endOfTrackReportedWhileASeekIntoTheTrackIsOutstandingIsStale() throws {
    let item = try PlayerItem(
      id: "item-restarted-at-end",
      timeline: PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 3_931)]))
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 3_931, rate: 1), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(
      .selectChapter(PlaybackChapter(id: "4", title: "Four", start: 1_200, end: 1_800)), now: 1)

    let stale = reducer.handle(.trackFinished(generation: 1), now: 1)

    #expect(stale.progressEvents.contains(where: { $0.phase == .ended }) == false)
    #expect(reducer.state.phase == .seeking)

    let landed = reducer.handle(.positionUpdated(generation: 1, localOffset: 1_200), now: 2)

    #expect(reducer.state.phase == .playing)
    #expect(reducer.state.globalPosition == 1_200)
    #expect(landed.progressEvents.map(\.phase) == [.playing])
  }

  /// The guard is for seeks aimed inside the track only: a seek that lands on the end of the final
  /// track still completes when the engine reports it.
  @Test func endOfTrackReportedWhileASeekToTheEndIsOutstandingStillCompletes() throws {
    let item = try PlayerItem(
      id: "item-seek-to-end",
      timeline: PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)]))
    var reducer = Self.playingReducer(item: item)
    _ = reducer.handle(.seek(toGlobalOffset: 100), now: 10)

    let result = reducer.handle(.trackFinished(generation: 1), now: 10)

    #expect(result.progressEvents.map(\.phase) == [.ended])
    #expect(reducer.state.phase == .ended)
  }

  private static func playingReducer(item: PlayerItem) -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    return reducer
  }
}

@Suite struct PlayerReducerTests {

  @Test func extendingSleepTimerAccountsForElapsedTimeBeforeAddingSeconds() {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 1_000)])
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(
      .load(item: PlayerItem(id: "item-1", timeline: timeline), initialGlobalPosition: 0, rate: 1),
      now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 100)), now: 0)

    _ = reducer.handle(.extendSleepTimer(by: 25), now: 10)

    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 115))
  }

  /// The mirror of the above: ten minutes stopped adds nothing to the bill, so an extension lands
  /// on the full remainder rather than on a silently drained one.
  @Test func extendingSleepTimerWhilePausedAddsToTheUntouchedRemainder() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 100)), now: 0)

    _ = reducer.handle(.extendSleepTimer(by: 25), now: 600)

    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 125))
  }

  @Test func changingRateEmitsListeningCreditAtTheOldRateBeforeAssigningTheNewRate() {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 1_000)])
    let item = PlayerItem(id: "item-1", timeline: timeline)
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)

    let result = reducer.handle(.setRate(2.0), now: 5)

    #expect(result.progressEvents.map(\.listenedDelta) == [5])
    #expect(reducer.state.rate == 2.0)
  }
}
