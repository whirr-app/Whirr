import Testing

@testable import PlayerCore

/// A segment is one stretch of the loaded item to stop at the end of: a chapter queued in Up Next. Reaching its end pauses and says so on the event; it never
/// ends the item.
@Suite struct PlayerSegmentTests {

  /// A 10,000s single-file book with chapters at 0, 1,000 and 2,000, loaded at `position`, ready
  /// and playing as of `now: 0`.
  private static func playingBook(at position: Double = 1_000) -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    let chapters = PlaybackChapterMap(chapters: [
      PlaybackChapter(start: 0, end: 1_000),
      PlaybackChapter(start: 1_000, end: 2_000),
      PlaybackChapter(start: 2_000, end: 10_000),
    ])
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 10_000)])
    let item = PlayerItem(id: "book", timeline: timeline, chapters: chapters)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: position, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    return reducer
  }

  /// Three 300s files, one chapter each, loaded at the start of the second and playing.
  private static func playingMultiFileBook() -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    let chapters = PlaybackChapterMap(chapters: [
      PlaybackChapter(start: 0, end: 300),
      PlaybackChapter(start: 300, end: 600),
      PlaybackChapter(start: 600, end: 900),
    ])
    let timeline = try! PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 300), PlaybackTrack(index: 1, duration: 300),
      PlaybackTrack(index: 2, duration: 300),
    ])
    let item = PlayerItem(id: "book", timeline: timeline, chapters: chapters)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 300, rate: 1.0), now: 0)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    return reducer
  }

  private static func reached(_ result: PlayerStepResult) -> [PlaybackProgressEvent] {
    result.progressEvents.filter { $0.segmentEnd == .reached }
  }

  // MARK: - Reaching the end

  @Test func aTickAtTheSegmentEndPausesThereAndSaysSo() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)

    let before = reducer.handle(.positionUpdated(generation: 1, localOffset: 1_999), now: 999)
    #expect(Self.reached(before).isEmpty)
    #expect(reducer.state.phase == .playing)

    // A background tick can arrive up to a tick late; the saved position is the chapter end.
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 2_000.7), now: 1_000.7)

    #expect(reducer.state.phase == .paused)
    #expect(reducer.state.isPlaybackIntended == false)
    #expect(reducer.state.globalPosition == 2_000)
    #expect(result.effects.contains(.pause))
    let marked = Self.reached(result)
    #expect(marked.count == 1)
    #expect(marked.first?.phase == .paused)
    #expect(marked.first?.currentTime == 2_000)
    #expect(marked.first?.sleepTimerExpiry == PlaybackProgressEvent.SleepTimerExpiry.none)
    #expect(result.progressEvents.contains { $0.phase == .ended } == false)
    #expect(reducer.segment == nil)
  }

  @Test func aLandingARoundingShortOfTheEndStillReachesIt() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 1_999.998), now: 999.998)

    #expect(Self.reached(result).count == 1)
    #expect(reducer.state.globalPosition == 2_000)
  }

  @Test func theSegmentEndIsReachedOnlyOnce() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 2_000), now: 1_000)

    _ = reducer.handle(.play, now: 1_001)
    let later = reducer.handle(.positionUpdated(generation: 1, localOffset: 2_010), now: 1_011)

    #expect(reducer.state.phase == .playing)
    #expect(Self.reached(later).isEmpty)
  }

  @Test func eventsDefaultToNoSegmentEnd() {
    var reducer = Self.playingBook()
    let tick = reducer.handle(.positionUpdated(generation: 1, localOffset: 1_010), now: 10)
    #expect(tick.progressEvents.allSatisfy { $0.segmentEnd == .none })
  }

  @Test func withoutALoadedItemASegmentIsIgnored() {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.setSegment(start: 0, end: 10), now: 0)
    #expect(reducer.segment == nil)
  }

  @Test(arguments: [(10.0, 10.0), (20.0, 10.0), (Double.nan, 10.0), (0.0, Double.infinity)])
  func aMalformedSegmentIsNotArmed(start: Double, end: Double) {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: start, end: end), now: 0)
    #expect(reducer.segment == nil)
  }

  // MARK: - Resets

  @Test func clearSegmentDropsTheStop() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)
    let cleared = reducer.handle(.clearSegment, now: 1)

    #expect(reducer.segment == nil)
    #expect(cleared.effects == [.setBoundary(localOffset: nil)])
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 2_000), now: 1_000)
    #expect(reducer.state.phase == .playing)
    #expect(Self.reached(result).isEmpty)
  }

  @Test func aLoadAndAStopDropTheSegment() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)
    let item = reducer.state.item!
    let other = PlayerItem(id: "other", timeline: item.timeline, chapters: item.chapters)
    _ = reducer.handle(.load(item: other, initialGlobalPosition: 1_000, rate: 1.0), now: 1)
    #expect(reducer.segment == nil)

    _ = reducer.handle(.ready(generation: 2), now: 1)
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 1)
    _ = reducer.handle(.stop, now: 2)
    #expect(reducer.segment == nil)
  }

  /// A stream recovery or a promotion to the finished download reloads the playing title in place.
  @Test func reloadingTheSameItemInsideTheSegmentKeepsItAndStillStops() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)
    let item = reducer.state.item!
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 1_500, rate: 1.0), now: 1)
    #expect(reducer.segment == PlayerSegment(start: 1_000, end: 2_000))

    _ = reducer.handle(.ready(generation: 2), now: 1)
    _ = reducer.handle(.play, now: 1)
    let result = reducer.handle(.positionUpdated(generation: 2, localOffset: 2_000), now: 501)
    #expect(reducer.state.phase == .paused)
    #expect(result.progressEvents.last?.segmentEnd == .reached)
  }

  @Test func reloadingTheSameItemOutsideTheSegmentDropsIt() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)
    let item = reducer.state.item!
    _ = reducer.handle(.load(item: item, initialGlobalPosition: 2_500, rate: 1.0), now: 1)
    #expect(reducer.segment == nil)
  }

  @Test func completingTheItemDropsTheSegment() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)

    let result = reducer.handle(.skip(by: 20_000), now: 1)

    #expect(reducer.state.phase == .ended)
    #expect(reducer.segment == nil)
    #expect(Self.reached(result).isEmpty)
  }

  // MARK: - Track boundary

  @Test func aChapterThatIsItsOwnFileStopsAtTheTrackBoundaryWithoutLoadingTheNext() {
    var reducer = Self.playingMultiFileBook()
    _ = reducer.handle(.setSegment(start: 300, end: 600), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 298), now: 298)

    let result = reducer.handle(.trackFinished(generation: 1), now: 300)

    #expect(
      result.effects.contains {
        if case .loadEngine = $0 { true } else { false }
      } == false)
    #expect(result.effects.contains(.pause))
    #expect(reducer.state.phase == .paused)
    #expect(reducer.state.globalPosition == 600)
    #expect(reducer.state.currentTrackIndex == 1)
    let marked = Self.reached(result)
    #expect(marked.count == 1)
    #expect(marked.first?.phase == .paused)
    #expect(marked.first?.currentTime == 600)
    // The final stretch of the file was listened to.
    #expect(marked.first?.listenedDelta == 2)
  }

  @Test func aSegmentThatRunsOnIntoTheNextFileLoadsIt() {
    var reducer = Self.playingMultiFileBook()
    _ = reducer.handle(.setSegment(start: 300, end: 750), now: 0)

    let result = reducer.handle(.trackFinished(generation: 1), now: 300)

    #expect(reducer.state.currentTrackIndex == 2)
    #expect(Self.reached(result).isEmpty)
    #expect(reducer.segment != nil)
  }

  // MARK: - Engine boundary

  @Test func theSegmentEndIsArmedAsTheEngineBoundary() {
    var reducer = Self.playingBook()
    let result = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)
    #expect(result.effects == [.setBoundary(localOffset: 2_000)])
  }

  @Test func theEarlierOfASkipRangeAndTheSegmentEndIsArmed() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)

    let early = reducer.handle(
      .setSkipRanges(
        itemID: "book", episodeID: nil,
        ranges: [PlayerSkipRange(start: 1_500, end: 1_530, endsItem: false)]), now: 1)
    #expect(early.effects.last == .setBoundary(localOffset: 1_500))

    let late = reducer.handle(
      .setSkipRanges(
        itemID: "book", episodeID: nil,
        ranges: [PlayerSkipRange(start: 2_500, end: 2_530, endsItem: false)]), now: 2)
    #expect(late.effects.last == .setBoundary(localOffset: 2_000))
  }

  @Test func aSegmentEndingAtAFileBoundaryArmsNoEngineBoundary() {
    var reducer = Self.playingMultiFileBook()
    let result = reducer.handle(.setSegment(start: 300, end: 600), now: 0)
    #expect(result.effects.isEmpty)
    #expect(reducer.segment != nil)
  }

  // MARK: - The listener leaves the segment

  @Test func aSeekOutOfTheSegmentDropsTheStopAndTheBookPlaysOn() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)

    _ = reducer.handle(.seek(toGlobalOffset: 5_000), now: 1)
    #expect(reducer.segment == nil)

    _ = reducer.handle(.ready(generation: 1), now: 1)
    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 5_010), now: 11)
    #expect(reducer.state.phase == .playing)
    #expect(Self.reached(result).isEmpty)
  }

  @Test func aSeekWithinTheSegmentKeepsTheStop() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)

    _ = reducer.handle(.seek(toGlobalOffset: 1_500), now: 1)
    #expect(reducer.segment != nil)
    // A second of slack before the start: a restart of the chapter can land a rounding short.
    _ = reducer.handle(.seek(toGlobalOffset: 999.5), now: 2)
    #expect(reducer.segment != nil)
    _ = reducer.handle(.seek(toGlobalOffset: 998), now: 3)
    #expect(reducer.segment == nil)
  }

  @Test func chapterJumpsOutOfTheSegmentDropTheStop() {
    var next = Self.playingBook()
    _ = next.handle(.setSegment(start: 1_000, end: 2_000), now: 0)
    _ = next.handle(.nextChapter, now: 1)
    #expect(next.segment == nil)

    var previous = Self.playingBook()
    _ = previous.handle(.setSegment(start: 1_000, end: 2_000), now: 0)
    _ = previous.handle(.previousChapter, now: 1)
    #expect(previous.state.globalPosition == 0)
    #expect(previous.segment == nil)

    var selected = Self.playingBook()
    _ = selected.handle(.setSegment(start: 1_000, end: 2_000), now: 0)
    _ = selected.handle(.selectChapter(PlaybackChapter(start: 2_000, end: 10_000)), now: 1)
    #expect(selected.segment == nil)
  }

  @Test func restartingTheChapterKeepsTheStop() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 1_100), now: 100)

    _ = reducer.handle(.previousChapter, now: 101)

    #expect(reducer.state.globalPosition == 1_000)
    #expect(reducer.segment != nil)
  }

  @Test func aForwardSkipAcrossTheEndLandsAtTheEndAndCountsAsReachingIt() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 1_990), now: 990)

    let result = reducer.handle(.skip(by: 30), now: 991)

    #expect(reducer.state.globalPosition == 2_000)
    #expect(reducer.state.isPlaybackIntended == false)
    #expect(result.effects.contains(.seekEngine(localOffset: 2_000)))
    #expect(result.effects.contains(.pause))
    #expect(Self.reached(result).count == 1)
    #expect(Self.reached(result).first?.currentTime == 2_000)
    #expect(reducer.segment == nil)
    #expect(reducer.state.phase != .ended)
  }

  @Test func aForwardSkipInsideTheSegmentIsAnOrdinarySkip() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)

    let result = reducer.handle(.skip(by: 30), now: 1)

    #expect(reducer.state.globalPosition == 1_030)
    #expect(Self.reached(result).isEmpty)
    #expect(reducer.segment != nil)
  }

  @Test func aSkipPastTheItemEndStillCompletesTheItem() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)

    let result = reducer.handle(.skip(by: 9_500), now: 1)

    #expect(reducer.state.phase == .ended)
    #expect(result.progressEvents.last?.phase == .ended)
    #expect(Self.reached(result).isEmpty)
  }

  // MARK: - Sleep timer

  @Test func aSleepTimerExpiringOnTheSameStepWins() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)
    _ = reducer.handle(.setSleepTimer(.endOfChapter), now: 0)

    let result = reducer.handle(.positionUpdated(generation: 1, localOffset: 2_000), now: 1_000)

    #expect(reducer.state.phase == .paused)
    #expect(result.progressEvents.contains { $0.sleepTimerExpiry == .expired })
    #expect(Self.reached(result).isEmpty)
    #expect(reducer.segment == nil)
  }

  @Test func aSleepTimerExpiringAtAFileBoundaryThatEndsTheSegmentWins() {
    var reducer = Self.playingMultiFileBook()
    _ = reducer.handle(.setSegment(start: 300, end: 600), now: 0)
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 300)), now: 0)

    let result = reducer.handle(.trackFinished(generation: 1), now: 300)

    #expect(reducer.state.phase == .paused)
    #expect(result.progressEvents.contains { $0.sleepTimerExpiry == .expired })
    #expect(Self.reached(result).isEmpty)
    #expect(reducer.segment == nil)
  }

  @Test func aSleepTimerExpiringInsideTheSegmentLeavesTheStopForTheResume() {
    var reducer = Self.playingBook()
    _ = reducer.handle(.setSegment(start: 1_000, end: 2_000), now: 0)
    _ = reducer.handle(.setSleepTimer(.custom(seconds: 100)), now: 0)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 1_100), now: 100)

    #expect(reducer.state.phase == .paused)
    #expect(reducer.segment != nil)
  }

  // MARK: - Last chapter

  @Test func theLastChapterIsNotASegmentAndEndsAsAnOrdinaryItemEnd() {
    var reducer = Self.playingBook(at: 2_000)
    let armed = reducer.handle(.setSegment(start: 2_000, end: 9_999.6), now: 0)
    #expect(reducer.segment == nil)
    #expect(armed.effects.isEmpty)

    let result = reducer.handle(.trackFinished(generation: 1), now: 8_000)

    #expect(reducer.state.phase == .ended)
    #expect(result.progressEvents.last?.endBehavior == .advanceQueue)
    #expect(Self.reached(result).isEmpty)
  }

  @Test func theLastChapterStaysTheItemEndAfterADurationCorrection() {
    var reducer = Self.playingBook(at: 2_000)
    // The audio runs past its declared 10,000s before the chapter is set.
    _ = reducer.handle(.durationObserved(generation: 1, localDuration: 10_040), now: 0)
    #expect(reducer.state.item?.timeline.totalDuration == 10_040)

    _ = reducer.handle(.setSegment(start: 2_000, end: 10_000), now: 0)
    #expect(reducer.segment == nil)

    let tick = reducer.handle(.positionUpdated(generation: 1, localOffset: 10_001), now: 8_001)
    #expect(reducer.state.phase == .playing)
    #expect(Self.reached(tick).isEmpty)
    _ = reducer.handle(.trackFinished(generation: 1), now: 8_040)
    #expect(reducer.state.phase == .ended)
  }
}
