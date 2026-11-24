import Testing

@testable import PlayerCore

/// Skipping past the end of an item finishes it instead of clamping the playhead to the last
/// frame. An absolute seek does not: several callers seek to a position recovered from
/// persistence, which can legitimately sit past a declared duration that under-ran the audio.
@Suite struct SkipCompletionTests {

  // MARK: - Skipping past the end completes

  @Test func skippingPastTheEndEndsTheItemAndAdvancesTheQueue() throws {
    var reducer = Self.playingReducer(duration: 100)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 80), now: 80)

    let result = reducer.handle(.skip(by: 30), now: 80)

    #expect(reducer.state.phase == .ended)
    #expect(reducer.state.globalPosition == 100)
    #expect(reducer.state.isPlaybackIntended == false)
    #expect(result.effects.contains(.pause))
    #expect(result.progressEvents.map(\.phase) == [.ended])
    #expect(result.progressEvents.first?.endBehavior == .advanceQueue)
  }

  /// `trackFinished` needs audio to actually reach the end, and the sleep-timer boundary only
  /// runs on a tick that was `.playing`, so neither covers a paused listener skipping off the end.
  @Test func skippingPastTheEndWhilePausedCompletesIdentically() throws {
    var reducer = Self.playingReducer(duration: 100)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 80), now: 80)
    _ = reducer.handle(.pause, now: 80)

    let result = reducer.handle(.skip(by: 30), now: 81)

    #expect(reducer.state.phase == .ended)
    #expect(reducer.state.globalPosition == 100)
    #expect(result.effects.contains(.pause))
    #expect(result.progressEvents.map(\.phase) == [.ended])
    #expect(result.progressEvents.first?.endBehavior == .advanceQueue)
  }

  @Test func skippingWithinTheItemIsAnOrdinarySeek() throws {
    var reducer = Self.playingReducer(duration: 100)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 40), now: 40)

    let result = reducer.handle(.skip(by: 30), now: 40)

    #expect(reducer.state.phase == .seeking)
    #expect(reducer.state.globalPosition == 70)
    #expect(result.effects == [.seekEngine(localOffset: 70)])
  }

  /// Landing inside the tolerance of the end is a seek, not a completion. The listener is still
  /// asking to hear the last moment rather than to be done with it.
  @Test func skippingExactlyOntoTheEndSeeksRatherThanCompleting() throws {
    var reducer = Self.playingReducer(duration: 100)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 70), now: 70)

    let result = reducer.handle(.skip(by: 30), now: 70)

    #expect(reducer.state.phase == .seeking)
    #expect(reducer.state.globalPosition == 100)
    #expect(result.progressEvents.contains { $0.phase == .ended } == false)
  }

  @Test func skippingBackwardsIsNeverACompletion() throws {
    var reducer = Self.playingReducer(duration: 100)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 95), now: 95)

    let result = reducer.handle(.skip(by: -30), now: 95)

    #expect(reducer.state.phase == .seeking)
    #expect(reducer.state.globalPosition == 65)
    #expect(result.progressEvents.contains { $0.phase == .ended } == false)
  }

  @Test func aNonFiniteOrZeroSkipDoesNothing() throws {
    var reducer = Self.playingReducer(duration: 100)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 95), now: 95)

    #expect(reducer.handle(.skip(by: .nan), now: 95).effects.isEmpty)
    #expect(reducer.handle(.skip(by: 0), now: 95).effects.isEmpty)
    #expect(reducer.state.globalPosition == 95)
  }

  // MARK: - An absolute seek must never complete

  /// A position recorded past a declared duration that under-ran the real audio is a resume
  /// point, not a request to finish: `PlaybackModel.play` seeks to exactly such a saved position
  /// immediately after `start`, while the reducer is still preparing. Completing there would
  /// answer "resume this" with "finished, next episode".
  @Test func anAbsoluteSeekPastTheEndClampsAndNeverCompletes() throws {
    var reducer = Self.playingReducer(duration: 100)

    let result = reducer.handle(.seek(toGlobalOffset: 3_650), now: 1)

    #expect(reducer.state.phase == .seeking)
    #expect(reducer.state.globalPosition == 100)
    #expect(result.progressEvents.contains { $0.phase == .ended } == false)
  }

  @Test func anAbsoluteSeekPastTheEndWhilePreparingAlsoNeverCompletes() throws {
    let item = try PlayerItem(
      id: "episode-1", episodeID: "ep-1",
      timeline: PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)]))
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1), now: 0)
    #expect(reducer.state.phase == .preparing)

    let result = reducer.handle(.seek(toGlobalOffset: 3_650), now: 1)

    #expect(reducer.state.phase == .seeking)
    #expect(result.progressEvents.contains { $0.phase == .ended } == false)
  }

  // MARK: - A sleep timer at the end still wins

  @Test func aPausedSkipCompletionUnderAnEndOfItemTimerForbidsQueueAdvance() throws {
    var reducer = Self.playingReducer(duration: 100)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 80), now: 80)
    _ = reducer.handle(.setSleepTimer(.endOfItem), now: 80)
    _ = reducer.handle(.pause, now: 80)

    let result = reducer.handle(.skip(by: 30), now: 81)

    #expect(result.progressEvents.map(\.phase) == [.ended])
    #expect(result.progressEvents.first?.endBehavior == .stop)
    #expect(reducer.state.sleepTimer.mode == .off)
  }

  @Test func aMidItemChapterTimerDoesNotSuppressTheQueueAdvance() throws {
    let item = try PlayerItem(
      id: "episode-1", episodeID: "ep-1",
      timeline: PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)]),
      chapters: PlaybackChapterMap(chapters: [
        PlaybackChapter(id: "c1", title: "One", start: 0, end: 40),
        PlaybackChapter(id: "c2", title: "Two", start: 40, end: 100),
      ]))
    var reducer = Self.playingReducer(item: item)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 20), now: 20)
    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 20)

    let result = reducer.handle(.skip(by: 200), now: 20)

    #expect(result.progressEvents.first?.endBehavior == .advanceQueue)
  }

  // MARK: - Terminal phases refuse the playhead

  @Test func neitherSkipNorSeekMovesAnEndedItem() throws {
    var reducer = Self.playingReducer(duration: 100)
    _ = reducer.handle(.trackFinished(generation: 1), now: 100)
    #expect(reducer.state.phase == .ended)

    #expect(reducer.handle(.skip(by: -30), now: 101).effects.isEmpty)
    #expect(reducer.handle(.seek(toGlobalOffset: 20), now: 102).effects.isEmpty)
    #expect(reducer.state.phase == .ended)
    #expect(reducer.state.globalPosition == 100)
  }

  @Test func aSkipCompletionCannotBeFollowedBySecondCompletion() throws {
    var reducer = Self.playingReducer(duration: 100)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 80), now: 80)
    _ = reducer.handle(.skip(by: 30), now: 80)

    let second = reducer.handle(.skip(by: 30), now: 81)

    #expect(second.progressEvents.isEmpty)
  }

  @Test func anIdleReducerIgnoresBothIntents() {
    var reducer = PlayerReducer(now: 0)

    #expect(reducer.handle(.skip(by: 30), now: 1).effects.isEmpty)
    #expect(reducer.handle(.seek(toGlobalOffset: 30), now: 1).effects.isEmpty)
  }

  // MARK: - Interaction with the duration correction

  /// While a timeline under-runs, the app already believes it is at the end during the surplus
  /// audio. Once the correction has extended it, a skip inside that audio is an ordinary seek
  /// again rather than an instant completion.
  @Test func skippingInsideCorrectedAudioSeeksInsteadOfCompleting() throws {
    var reducer = Self.playingReducer(duration: 100)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 105), now: 105)
    #expect(reducer.state.item?.timeline.totalDuration == 105)
    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 130), now: 105)

    let result = reducer.handle(.skip(by: 10), now: 105)

    #expect(reducer.state.phase == .seeking)
    #expect(reducer.state.globalPosition == 115)
    #expect(result.progressEvents.contains { $0.phase == .ended } == false)
  }

  // MARK: - Helpers

  private static func playingReducer(duration: Double) -> PlayerReducer {
    let item = try! PlayerItem(
      id: "episode-1", episodeID: "ep-1",
      timeline: PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: duration)]))
    return playingReducer(item: item)
  }

  private static func playingReducer(item: PlayerItem) -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 0, rate: 1), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    return reducer
  }
}
