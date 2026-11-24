import Testing

@testable import PlayerCore

/// Chapters live on the same global timeline `PlaybackTimeline` maps tracks onto (ARCHITECTURE.md
/// §4). Pure lookup logic with no dependency on a concrete `PlaybackTimeline`, since a chapter's
/// start/end are already global positions.
@Suite struct ChapterMapTests {

  // MARK: - Position relative to track boundaries

  @Test func chapterWhollyInsideOneTrackIsFoundByPosition() throws {
    // Two tracks: [0, 100) and [100, 250). A chapter entirely inside the first track.
    let timeline = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 100),
      PlaybackTrack(index: 1, duration: 150),
    ])
    let chapter = PlaybackChapter(id: "c1", title: "Chapter 1", start: 10, end: 50)
    let map = PlaybackChapterMap(chapters: [chapter])

    #expect(map.currentChapter(at: 30) == chapter)
    // Sanity: 30 really is inside track 0 on the timeline this chapter was authored against.
    #expect(timeline.trackAndLocalOffset(atGlobalOffset: 30).track.index == 0)
  }

  @Test func chapterSpanningATrackBoundaryIsFoundOnEitherSide() throws {
    let timeline = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 100),
      PlaybackTrack(index: 1, duration: 150),
    ])
    let chapter = PlaybackChapter(id: "c2", title: "Chapter 2", start: 80, end: 150)
    let map = PlaybackChapterMap(chapters: [chapter])

    #expect(map.currentChapter(at: 90) == chapter)
    #expect(map.currentChapter(at: 120) == chapter)
    // The two positions above really do straddle the track-0/track-1 boundary.
    #expect(timeline.trackAndLocalOffset(atGlobalOffset: 90).track.index == 0)
    #expect(timeline.trackAndLocalOffset(atGlobalOffset: 120).track.index == 1)
  }

  // MARK: - Gaps and overlaps

  @Test func aGapBetweenChaptersHasNoCurrentChapter() {
    let first = PlaybackChapter(id: "a", start: 0, end: 10)
    let second = PlaybackChapter(id: "b", start: 20, end: 30)
    let map = PlaybackChapterMap(chapters: [first, second])

    #expect(map.currentChapter(at: 15) == nil)
    #expect(map.previousChapter(before: 15) == first)
    #expect(map.nextChapter(after: 15) == second)
  }

  @Test func overlappingChaptersResolveToTheLaterStartingOne() {
    let first = PlaybackChapter(id: "a", start: 0, end: 10)
    let second = PlaybackChapter(id: "b", start: 5, end: 15)
    let map = PlaybackChapterMap(chapters: [first, second])

    #expect(map.currentChapter(at: 7) == second)
  }

  @Test func positionAtASharedBoundaryResolvesToTheLaterChapter() {
    let first = PlaybackChapter(id: "a", start: 0, end: 10)
    let second = PlaybackChapter(id: "b", start: 10, end: 20)
    let map = PlaybackChapterMap(chapters: [first, second])

    #expect(map.currentChapter(at: 10) == second)
  }

  // MARK: - Malformed ranges

  @Test func aChapterWhereEndDoesNotExceedStartIsDropped() {
    let malformed = PlaybackChapter(id: "bad", start: 10, end: 10)
    let valid = PlaybackChapter(id: "good", start: 20, end: 30)
    let map = PlaybackChapterMap(chapters: [malformed, valid])

    #expect(map.chapters == [valid])
  }

  @Test func aChapterWithANegativeStartIsDropped() {
    let malformed = PlaybackChapter(id: "bad", start: -5, end: 10)
    let map = PlaybackChapterMap(chapters: [malformed])

    #expect(map.chapters.isEmpty)
  }

  @Test func aChapterWithANonFiniteBoundIsDropped() {
    let nanStart = PlaybackChapter(id: "nan", start: .nan, end: 10)
    let infiniteEnd = PlaybackChapter(id: "inf", start: 0, end: .infinity)
    let map = PlaybackChapterMap(chapters: [nanStart, infiniteEnd])

    #expect(map.chapters.isEmpty)
  }

  // MARK: - Current / previous / next selection

  @Test func currentPreviousAndNextNavigateTheSortedChapterList() {
    let first = PlaybackChapter(id: "1", start: 0, end: 10)
    let second = PlaybackChapter(id: "2", start: 10, end: 20)
    let third = PlaybackChapter(id: "3", start: 20, end: 30)
    // Out of order: construction sorts by start.
    let map = PlaybackChapterMap(chapters: [third, first, second])

    #expect(map.currentChapter(at: 15) == second)
    #expect(map.previousChapter(before: 15) == first)
    #expect(map.nextChapter(after: 15) == third)
  }

  @Test func thereIsNoPreviousChapterBeforeTheFirstOne() {
    let first = PlaybackChapter(id: "1", start: 0, end: 10)
    let second = PlaybackChapter(id: "2", start: 10, end: 20)
    let map = PlaybackChapterMap(chapters: [first, second])

    #expect(map.previousChapter(before: 5) == nil)
  }

  @Test func thereIsNoNextChapterAfterTheLastOne() {
    let first = PlaybackChapter(id: "1", start: 0, end: 10)
    let second = PlaybackChapter(id: "2", start: 10, end: 20)
    let map = PlaybackChapterMap(chapters: [first, second])

    #expect(map.nextChapter(after: 15) == nil)
  }

  // MARK: - Chapter ending exactly at book end

  @Test func aChapterEndingExactlyAtBookEndOwnsThatFinalPosition() throws {
    let timeline = try PlaybackTimeline(tracks: [
      PlaybackTrack(index: 0, duration: 60),
      PlaybackTrack(index: 1, duration: 40),
    ])
    let last = PlaybackChapter(id: "last", start: 80, end: 100)
    let map = PlaybackChapterMap(chapters: [
      PlaybackChapter(id: "first", start: 0, end: 80),
      last,
    ])

    #expect(map.currentChapter(at: timeline.totalDuration) == last)
    #expect(map.nextChapter(after: timeline.totalDuration) == nil)
  }

  // MARK: - Display title at a position

  @Test func theDisplayTitleAtAPositionIsTheOwningChaptersTitle() {
    let map = PlaybackChapterMap(chapters: [
      PlaybackChapter(id: "1", title: "Arrakis", start: 0, end: 50),
      PlaybackChapter(id: "2", title: "The Gom Jabbar", start: 50, end: 100),
    ])

    #expect(map.currentChapterTitle(at: 10) == "Arrakis")
    #expect(map.currentChapterTitle(at: 60) == "The Gom Jabbar")
  }

  @Test func aBookWithNoChaptersHasNoDisplayTitle() {
    #expect(PlaybackChapterMap(chapters: []).currentChapterTitle(at: 10) == nil)
  }

  @Test func aChapterWithABlankOrMissingTitleHasNoDisplayTitle() {
    let map = PlaybackChapterMap(chapters: [
      PlaybackChapter(id: "1", title: nil, start: 0, end: 50),
      PlaybackChapter(id: "2", title: "   ", start: 50, end: 100),
    ])

    #expect(map.currentChapterTitle(at: 10) == nil)
    #expect(map.currentChapterTitle(at: 60) == nil)
  }

  @Test func aPositionInAGapBetweenChaptersHasNoDisplayTitle() {
    let map = PlaybackChapterMap(chapters: [
      PlaybackChapter(id: "1", title: "Arrakis", start: 0, end: 50),
      PlaybackChapter(id: "2", title: "The Gom Jabbar", start: 80, end: 100),
    ])

    #expect(map.currentChapterTitle(at: 60) == nil)
  }
}
