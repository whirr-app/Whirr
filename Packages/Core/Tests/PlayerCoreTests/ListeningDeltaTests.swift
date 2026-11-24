import Testing

@testable import PlayerCore

/// Listening time is elapsed wall-clock time actually spent `.playing`, never media-position
/// movement. Every `now` below is an explicit value the test supplies to `PlayerReducer`, with no
/// injected system clock and no real sleep, so accrual is exact and deterministic.
@Suite struct ListeningDeltaTests {

  private static func singleTrackItem(duration: Double = 1000) -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: duration)])
    return PlayerItem(id: "item-1", timeline: timeline)
  }

  /// Loads, reaches `.ready`, and issues `.play`, all at `now == 0`, returning the reducer
  /// primed at `.playing` with zero accrued credit so far.
  private static func playingReducer(rate: Double = 1.0) -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: rate), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    return reducer
  }

  @Test func playingAccruesWallTime() {
    var reducer = Self.playingReducer()

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 5), now: 5)

    #expect(result.progressEvents.map(\.listenedDelta) == [5])
    #expect(result.progressEvents.map(\.currentTime) == [5])
  }

  @Test func doubleRateChangesPositionButNotListenedDelta() {
    var reducer = Self.playingReducer(rate: 2.0)

    // 5 wall-clock seconds at 2x moves the reported position by 10, consistent with the rate.
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 10), now: 5)

    #expect(result.progressEvents.map(\.currentTime) == [10])
    #expect(result.progressEvents.map(\.listenedDelta) == [5])
  }

  @Test func bufferingIntervalAccruesZero() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 3), now: 3)  // legit playing credit
    _ = reducer.handle(.buffering(generation: 1), now: 5)  // more legit credit up to the stall

    // Three seconds pass while buffering before the engine recovers.
    let recovered = reducer.handle(.ready(generation: 1), now: 8)

    #expect(recovered.progressEvents.map(\.listenedDelta) == [0])
  }

  @Test func pausedIntervalAccruesZero() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.pause, now: 2)  // legit credit for the two seconds spent playing

    // Four seconds pass while paused.
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 2), now: 6)

    #expect(result.progressEvents.map(\.listenedDelta) == [0])
  }

  @Test func aStrayTickWhilePausedReassertsPauseAtTheEngine() {
    // The engine can keep firing `positionUpdated` after playback stops (a frozen position with
    // zero delta, pegging a CPU core), and ignoring them would never stop it. A tick arriving
    // while the reducer considers itself paused must re-assert `.pause` to shut the ticking off at
    // the source (the first corrective tick clears `isPlaybackRequested`). The zero-delta display
    // event still flows.
    var reducer = Self.playingReducer()
    _ = reducer.handle(.pause, now: 2)
    #expect(reducer.state.phase == .paused)

    let strayTick = reducer.handle(.positionUpdated(generation: 1, localOffset: 2), now: 6)

    #expect(strayTick.effects.contains(.pause))
    #expect(strayTick.progressEvents.map(\.listenedDelta) == [0])
  }

  @Test func seekingIntervalAccruesZero() {
    var reducer = Self.playingReducer()
    _ = reducer.handle(.seek(toGlobalOffset: 50), now: 3)  // legit credit for the three seconds before the seek

    // Four seconds pass while the seek is in flight before the engine confirms it.
    let resumed = reducer.handle(.positionUpdated(generation: 1, localOffset: 50), now: 7)

    #expect(resumed.progressEvents.map(\.listenedDelta) == [0])
  }

  @Test func forwardEngineJumpAccruesZeroButStillMovesPosition() {
    var reducer = Self.playingReducer()

    // 5 wall-clock seconds at 1x should land at position 5; the engine instead reports 999.
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 999), now: 5)

    #expect(result.progressEvents.map(\.listenedDelta) == [0])
    #expect(result.progressEvents.map(\.currentTime) == [999])
  }

  @Test func backwardEngineJumpAccruesZeroButStillMovesPosition() {
    var reducer = Self.playingReducer()
    // Legit: lands exactly at expected 20.
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 20), now: 20)

    // One second passes; the engine unexpectedly reports a position far behind where it was.
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 2), now: 21)

    #expect(result.progressEvents.map(\.listenedDelta) == [0])
    #expect(result.progressEvents.map(\.currentTime) == [2])
  }

  @Test func eachEmittedEventCarriesItsCapturedProgressSequenceInOrder() {
    var reducer = PlayerReducer(now: 0)
    let item = Self.singleTrackItem()

    let loaded = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1.0), now: 0)
    let ready = reducer.handle(.ready(generation: 1), now: 0)
    let played = reducer.handle(.play, now: 0)
    let paused = reducer.handle(.pause, now: 1)

    #expect(loaded.progressEvents.map(\.sequence) == [1])
    #expect(ready.progressEvents.map(\.sequence) == [2])
    #expect(played.progressEvents.map(\.sequence) == [3])
    #expect(paused.progressEvents.map(\.sequence) == [4])
  }
}
