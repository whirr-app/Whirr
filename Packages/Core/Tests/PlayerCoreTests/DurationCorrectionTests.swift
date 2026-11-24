import Testing

@testable import PlayerCore

/// A declared duration that under-runs the real audio (routine for podcast feed metadata, and the
/// injected-advert bug): the manifest says 100 s, the file runs to 130 s. Uncorrected, the
/// playhead freezes at 100, remaining time reads zero over audible audio, and a skip forward lands
/// back on 100.
@Suite struct DurationCorrectionTests {

  // MARK: - Growth from the engine's declared extent

  @Test func observedDurationLongerThanDeclaredExtendsTheTimeline() throws {
    var reducer = Self.playingReducer(declaredDuration: 100)

    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 130), now: 1)

    #expect(reducer.state.item?.timeline.totalDuration == 130)
  }

  @Test func aShorterObservationNeverTruncatesTheTimeline() throws {
    var reducer = Self.playingReducer(declaredDuration: 100)

    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 40), now: 1)

    #expect(reducer.state.item?.timeline.totalDuration == 100)
  }

  @Test func anObservationWithinToleranceIsIgnored() throws {
    var reducer = Self.playingReducer(declaredDuration: 100)

    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 100.5), now: 1)

    #expect(reducer.state.item?.timeline.totalDuration == 100)
  }

  @Test func nonFiniteAndNonPositiveObservationsAreIgnored() throws {
    var reducer = Self.playingReducer(declaredDuration: 100)

    _ = reducer.handle(.durationObserved(generation: 1, localDuration: .infinity), now: 1)
    _ = reducer.handle(.durationObserved(generation: 1, localDuration: .nan), now: 2)
    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 0), now: 3)
    _ = reducer.handle(.durationObserved(generation: 1, localDuration: -5), now: 4)

    #expect(reducer.state.item?.timeline.totalDuration == 100)
  }

  @Test func aStaleGenerationsObservationIsIgnored() throws {
    var reducer = Self.playingReducer(declaredDuration: 100)

    _ = reducer.handle(.durationObserved(generation: 0, localDuration: 130), now: 1)

    #expect(reducer.state.item?.timeline.totalDuration == 100)
  }

  @Test func correctionsAreMonotonicAndIdempotent() throws {
    var reducer = Self.playingReducer(declaredDuration: 100)

    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 130), now: 1)
    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 160), now: 2)
    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 130), now: 3)

    #expect(reducer.state.item?.timeline.totalDuration == 160)
  }

  /// `AVPlayerItem.duration` may agree with the server's own header-derived probe, in which case
  /// the over-running tick is the only evidence the audio is longer. The correction cannot depend
  /// solely on the declared-extent event.
  @Test func anOverRunningPositionTickAloneExtendsTheTimeline() throws {
    var reducer = Self.playingReducer(declaredDuration: 100)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 118), now: 118)

    #expect(reducer.state.item?.timeline.totalDuration == 118)
    #expect(reducer.state.globalPosition == 118)
  }

  @Test func anOverRunningTickFromAStaleGenerationExtendsNothing() throws {
    var reducer = Self.playingReducer(declaredDuration: 100)

    _ = reducer.handle(.positionUpdated(generation: 0, localOffset: 118), now: 118)

    #expect(reducer.state.item?.timeline.totalDuration == 100)
  }

  /// The position must not freeze at the declared end. The listener must not be credited with the
  /// surplus in one lump either. That is the jump detector's job, and the correction must not
  /// defeat it.
  @Test func theJumpProducedByACorrectionCreditsNoListeningTime() throws {
    var reducer = Self.playingReducer(declaredDuration: 100)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 99), now: 99)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 125), now: 100)

    #expect(reducer.state.globalPosition == 125)
    #expect(result.progressEvents.first?.listenedDelta == 0)
  }

  @Test func aMultiTrackItemIsNeverCorrected() throws {
    let item = try PlayerItem(
      id: "book",
      timeline: PlaybackTimeline(tracks: [
        PlaybackTrack(index: 0, startOffset: 0, duration: 100),
        PlaybackTrack(index: 1, startOffset: 100, duration: 50),
      ]))
    var reducer = Self.playingReducer(item: item)

    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 130), now: 1)

    #expect(reducer.state.item?.timeline.totalDuration == 150)
  }

  @Test func anObservationAfterTheItemEndedIsIgnored() throws {
    var reducer = Self.playingReducer(declaredDuration: 100)
    _ = reducer.handle(.trackFinished(generation: 1), now: 100)

    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 130), now: 101)

    #expect(reducer.state.item?.timeline.totalDuration == 100)
  }

  @Test func aCorrectionPreservesEveryOtherPropertyOfTheItem() throws {
    let chapters = PlaybackChapterMap(chapters: [
      PlaybackChapter(id: "c1", title: "One", start: 0, end: 100)
    ])
    let item = try PlayerItem(
      id: "episode-1", episodeID: "ep-1",
      timeline: PlaybackTimeline(tracks: [PlaybackTrack(index: 3, startOffset: 0, duration: 100)]),
      chapters: chapters, isStreaming: true)
    var reducer = Self.playingReducer(item: item)

    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 130), now: 1)

    let corrected = reducer.state.item
    #expect(corrected?.id == "episode-1")
    #expect(corrected?.episodeID == "ep-1")
    #expect(corrected?.isStreaming == true)
    #expect(corrected?.chapters == chapters)
    #expect(corrected?.timeline.tracks.first?.index == 3)
    #expect(corrected?.timeline.tracks.first?.startOffset == 0)
    #expect(reducer.state.currentTrackIndex == 3)
  }

  /// A correction arriving mid-seek must not disturb the landing logic: the target and its
  /// tolerance are how a long seek survives the stale ticks still in flight behind it.
  @Test func aCorrectionDuringASeekLeavesTheSeekLandingIntact() throws {
    var reducer = Self.playingReducer(declaredDuration: 100)
    _ = reducer.handle(.seek(toGlobalOffset: 80), now: 10)

    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 130), now: 11)
    let landing = reducer.handle(.positionUpdated(generation: 1, localOffset: 80), now: 12)

    #expect(reducer.state.item?.timeline.totalDuration == 130)
    #expect(reducer.state.globalPosition == 80)
    #expect(landing.progressEvents.isEmpty == false)
  }

  // MARK: - Sleep-timer boundary follows the correction

  @Test func anEndOfItemTimerPinnedAtTheOldEndFollowsTheNewEnd() throws {
    var reducer = Self.playingReducer(declaredDuration: 100)
    _ = reducer.handle(.setSleepTimer(.endOfItem), now: 1)

    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 130), now: 2)

    #expect(reducer.state.sleepTimer.mode == .endOfChapter(atPosition: 130))
  }

  /// Exact equality would miss this: a final chapter routinely ends a fraction short of the
  /// declared duration, so an end-of-chapter timer there is pinned just below the old total. Left
  /// behind, it fires inside the surplus audio and no longer reads as a completion.
  @Test func aTimerPinnedJustShortOfTheOldEndAlsoFollowsIt() throws {
    let item = try PlayerItem(
      id: "episode-1",
      timeline: PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)]),
      chapters: PlaybackChapterMap(chapters: [
        PlaybackChapter(id: "c1", title: "One", start: 0, end: 99.5)
      ]))
    var reducer = Self.playingReducer(item: item)
    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 1)
    #expect(reducer.state.sleepTimer.mode == .endOfChapter(atPosition: 99.5))

    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 130), now: 2)

    #expect(reducer.state.sleepTimer.mode == .endOfChapter(atPosition: 130))
  }

  @Test func aMidItemChapterTimerIsLeftWhereTheListenerSetIt() throws {
    let item = try PlayerItem(
      id: "episode-1",
      timeline: PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)]),
      chapters: PlaybackChapterMap(chapters: [
        PlaybackChapter(id: "c1", title: "One", start: 0, end: 40),
        PlaybackChapter(id: "c2", title: "Two", start: 40, end: 100),
      ]))
    var reducer = Self.playingReducer(item: item)
    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 1)

    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 130), now: 2)

    #expect(reducer.state.sleepTimer.mode == .endOfChapter(atPosition: 40))
  }

  @Test func aCountdownTimerIsUntouchedByACorrection() throws {
    var reducer = Self.playingReducer(declaredDuration: 100)
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 300)), now: 0)

    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 130), now: 0)

    #expect(reducer.state.sleepTimer.mode == .countdown(remainingSeconds: 300))
  }

  // MARK: - Helpers

  private static func playingReducer(declaredDuration: Double) -> PlayerReducer {
    let item = try! PlayerItem(
      id: "episode-1", episodeID: "ep-1",
      timeline: PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: declaredDuration)]))
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
