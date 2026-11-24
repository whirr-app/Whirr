import Testing

@testable import PlayerCore

/// Chapter navigation is purely seeks over the global timeline `PlaybackTimeline` builds
/// (ARCHITECTURE.md §4). `PlaybackChapterMap`'s lookup helpers do the chapter maths; the reducer
/// only decides which position to seek to.
@Suite struct ChapterIntentTests {

  /// One 100s track split into three chapters: [0, 30], [30, 70], [70, 100].
  private static func threeChapterItem() -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)])
    let chapters = PlaybackChapterMap(chapters: [
      PlaybackChapter(id: "0", title: "One", start: 0, end: 30),
      PlaybackChapter(id: "1", title: "Two", start: 30, end: 70),
      PlaybackChapter(id: "2", title: "Three", start: 70, end: 100),
    ])
    return PlayerItem(id: "item-1", timeline: timeline, chapters: chapters)
  }

  private static func noChapterItem() -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 100)])
    return PlayerItem(id: "item-1", timeline: timeline)
  }

  /// Chapter starts as a real server reports them: arbitrary doubles, not neat multiples of the
  /// engine's 1/600s timescale. That distinction is the whole point of the boundary tests below.
  private static func fractionalChapterItem() -> PlayerItem {
    let timeline = try! PlaybackTimeline(tracks: [PlaybackTrack(index: 0, duration: 3600)])
    let chapters = PlaybackChapterMap(chapters: [
      PlaybackChapter(id: "0", title: "One", start: 0, end: 612.339),
      PlaybackChapter(id: "1", title: "Two", start: 612.339, end: 1234.567),
      PlaybackChapter(id: "2", title: "Three", start: 1234.567, end: 3600),
    ])
    return PlayerItem(id: "item-1", timeline: timeline, chapters: chapters)
  }

  private func reducer(at position: Double, item: PlayerItem) -> PlayerReducer {
    var reducer = PlayerReducer(now: 0)
    _ = reducer.handle(.load(item: item, initialGlobalPosition: position, rate: 1.0), now: 0)
    return reducer
  }

  // MARK: - selectChapter

  @Test func selectChapterSeeksToItsStart() {
    var reducer = reducer(at: 5, item: Self.threeChapterItem())

    let result = reducer.handle(
      .selectChapter(PlaybackChapter(id: "1", title: "Two", start: 30, end: 70)), now: 1)

    #expect(result.effects == [.seekEngine(localOffset: 30)])
    #expect(reducer.state.phase == .seeking)
  }

  // MARK: - nextChapter

  @Test func nextChapterAdvancesToTheFollowingChaptersStart() {
    var reducer = reducer(at: 10, item: Self.threeChapterItem())

    let result = reducer.handle(.nextChapter, now: 1)

    #expect(result.effects == [.seekEngine(localOffset: 30)])
  }

  @Test func nextChapterAtTheLastChapterIsANoOp() {
    var reducer = reducer(at: 80, item: Self.threeChapterItem())

    let result = reducer.handle(.nextChapter, now: 1)

    #expect(result.effects.isEmpty)
  }

  // MARK: - previousChapter

  @Test func previousChapterWithinThreeSecondsMovesToThePreviousChaptersStart() {
    // Position 32 is 2s into chapter "Two" (starts at 30), within the 3s threshold.
    var reducer = reducer(at: 32, item: Self.threeChapterItem())

    let result = reducer.handle(.previousChapter, now: 1)

    #expect(result.effects == [.seekEngine(localOffset: 0)])
  }

  @Test func previousChapterAtExactlyThreeSecondsInStillMovesToThePreviousChapter() {
    // The spec's threshold is "more than 3s" restarts; exactly 3s still counts as "not yet".
    var reducer = reducer(at: 33, item: Self.threeChapterItem())

    let result = reducer.handle(.previousChapter, now: 1)

    #expect(result.effects == [.seekEngine(localOffset: 0)])
  }

  @Test func previousChapterMoreThanThreeSecondsInRestartsTheCurrentChapter() {
    // Position 35 is 5s into chapter "Two" (starts at 30), past the 3s threshold.
    var reducer = reducer(at: 35, item: Self.threeChapterItem())

    let result = reducer.handle(.previousChapter, now: 1)

    #expect(result.effects == [.seekEngine(localOffset: 30)])
  }

  @Test func previousChapterAtTheVeryFirstChapterRestartsIt() {
    var reducer = reducer(at: 1, item: Self.threeChapterItem())

    let result = reducer.handle(.previousChapter, now: 1)

    #expect(result.effects == [.seekEngine(localOffset: 0)])
  }

  // MARK: - No chapter data

  @Test func nextChapterWithNoChapterDataIsANoOp() {
    var reducer = reducer(at: 10, item: Self.noChapterItem())

    let result = reducer.handle(.nextChapter, now: 1)

    #expect(result.effects.isEmpty)
  }

  @Test func previousChapterWithNoChapterDataIsANoOp() {
    var reducer = reducer(at: 10, item: Self.noChapterItem())

    let result = reducer.handle(.previousChapter, now: 1)

    #expect(result.effects.isEmpty)
  }

  @Test func chapterIntentsWithNoLoadedItemAreNoOps() {
    var reducer = PlayerReducer(now: 0)

    let next = reducer.handle(.nextChapter, now: 1)
    let previous = reducer.handle(.previousChapter, now: 1)

    #expect(next.effects.isEmpty)
    #expect(previous.effects.isEmpty)
  }

  // MARK: - Landing on a chapter boundary

  /// At a chapter start a sub-millisecond error changes "which chapter is this":
  /// `PlaybackChapterMap` gives a shared boundary to the later chapter, so a landing a hair short
  /// belongs to the chapter just left, and the chapter-scoped scrubber draws a full bar. The
  /// engine reports such landings: `CMTime`'s 1/600s timescale rounds most chapter starts to a tick
  /// fractionally below, and AVFoundation fires its periodic observer immediately on the jump.
  /// Adopting that verbatim would flicker "Three, empty bar" → "Two, full bar" → "Three, empty
  /// bar".
  @Test func aSeekLandingAHairShortOfAChapterStartStillReadsAsTheChapterItAimedAt() {
    let item = Self.fractionalChapterItem()
    var reducer = reducer(at: 700, item: item)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.nextChapter, now: 1)
    #expect(reducer.state.globalPosition == 1234.567, "the target is adopted up front")

    // What the engine reports back: 1234.567 rounded down to its own 1/600s grid.
    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 1234.566_666_666_666_7), now: 1.2)

    #expect(
      item.chapters.currentChapter(at: reducer.state.globalPosition)?.title == "Three",
      "a third of a millisecond short must not put the playhead back in the chapter just left")
  }

  /// The same landing seen through the scrubber, which is chapter-scoped: an undershoot of the
  /// boundary does not merely mislabel the row, it fills the bar to the brim for the chapter the
  /// listener has already left.
  @Test func aSeekToAChapterStartLeavesTheChapterScopedScrubberAtItsStart() {
    let item = Self.fractionalChapterItem()
    var reducer = reducer(at: 700, item: item)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.nextChapter, now: 1)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 1234.566_666_666_666_7), now: 1.2)

    let chapter = item.chapters.currentChapter(at: reducer.state.globalPosition)!
    let fraction = (reducer.state.globalPosition - chapter.start) / (chapter.end - chapter.start)
    #expect(fraction < 0.01, "the destination chapter has barely started")
  }

  /// The other half of the contract: only the engine's own rounding is absorbed. A landing that
  /// genuinely differs from the target is still the truth about where playback is, and must reach
  /// the UI rather than be papered over with the position the listener asked for.
  @Test func aLandingThatGenuinelyDiffersFromTheTargetIsStillAdopted() {
    let item = Self.fractionalChapterItem()
    var reducer = reducer(at: 700, item: item)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.nextChapter, now: 1)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 1232.4), now: 1.2)

    #expect(reducer.state.globalPosition == 1232.4)
  }

  /// Overshoot needs no correction (a landing past the target already belongs to the destination
  /// chapter) and must not be rewritten either.
  @Test func aLandingPastTheTargetIsAdoptedUnchanged() {
    let item = Self.fractionalChapterItem()
    var reducer = reducer(at: 700, item: item)
    _ = reducer.handle(.ready(generation: 1), now: 0)
    _ = reducer.handle(.play, now: 0)
    _ = reducer.handle(.nextChapter, now: 1)

    _ = reducer.handle(.positionUpdated(generation: 1, localOffset: 1234.6), now: 1.2)

    #expect(reducer.state.globalPosition == 1234.6)
  }
}
