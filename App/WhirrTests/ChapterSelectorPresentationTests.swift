import AppModel
import PlayerCore
import Testing

@testable import Whirr

struct ChapterSelectorPresentationTests {
  private let chapters = [
    PlaybackChapter(id: "intro", title: "A Beginning", start: 0, end: 65),
    PlaybackChapter(id: "middle", title: nil, start: 65, end: 3_725),
    PlaybackChapter(id: "end", title: "The Last Word", start: 3_725, end: 3_845),
  ]

  @Test("rows number chapters and provide useful timeline labels")
  func rowsDescribeTimeline() {
    let rows = ChapterSelectorPresentation.rows(chapters: chapters)

    #expect(rows.map(\.number) == [1, 2, 3])
    #expect(rows.map(\.title) == ["A Beginning", "Chapter 2", "The Last Word"])
    #expect(rows.map(\.startLabel) == ["00:00", "01:05", "1:02:05"])
    #expect(rows.map(\.durationLabel) == ["1 min", "1 hr 1 min", "2 min"])
  }

  /// The chapter selector used to round 90 seconds up to "2 min" while an episode length truncated
  /// to "1 min". Both now share `DurationText.long`.
  @Test("a ninety-second chapter reads the same minute a length does")
  func durationTruncatesLikeALength() {
    #expect(
      ChapterSelectorPresentation.duration(90) == PodcastCopy.duration(seconds: 90))
    #expect(ChapterSelectorPresentation.duration(90) == "1 min")
  }

  /// Audiobookshelf servers very often name a chapter exactly "Chapter 1", as does this type's own
  /// fallback for an untitled one. Prefixing the number unconditionally made VoiceOver read every
  /// such row twice: "Chapter 1, Chapter 1".
  @Test("a chapter that names its own number is not announced twice")
  func spokenLabelDoesNotStutter() {
    let rows = ChapterSelectorPresentation.rows(chapters: [
      PlaybackChapter(title: "Chapter 1", start: 0, end: 60),
      PlaybackChapter(title: nil, start: 60, end: 120),
      PlaybackChapter(title: "Chapter 3: The Reckoning", start: 120, end: 180),
      PlaybackChapter(title: "A Beginning", start: 180, end: 240),
      // A title that starts with the word but not with this row's number still gets it: the
      // number is what tells the reader where they are in the list.
      PlaybackChapter(title: "Chapter 12", start: 240, end: 300),
    ])

    #expect(
      rows.map(\.accessibilityLabel) == [
        "Chapter 1",
        "Chapter 2",
        "Chapter 3: The Reckoning",
        "Chapter 4, A Beginning",
        "Chapter 5, Chapter 12",
      ])
  }

  @Test("empty title falls back to a numbered chapter label")
  func emptyTitleFallsBackToNumberedLabel() {
    let rows = ChapterSelectorPresentation.rows(chapters: [
      PlaybackChapter(title: "   ", start: 0, end: 10)
    ])

    #expect(rows[0].title == "Chapter 1")
  }

  @Test("no current time means nothing is marked current or completed")
  func noCurrentTimeMarksNothingCompleted() {
    let rows = ChapterSelectorPresentation.rows(chapters: chapters)

    #expect(rows.map(\.isCurrent) == [false, false, false])
    #expect(rows.map(\.isCompleted) == [false, false, false])
  }

  @Test("first chapter current means no earlier chapters exist to complete")
  func firstChapterCurrentHasNoCompletedChapters() {
    let rows = ChapterSelectorPresentation.rows(chapters: chapters, currentTime: 30)

    #expect(rows[0].isCurrent == true)
    #expect(rows.map(\.isCompleted) == [false, false, false])
  }

  @Test("mid-book chapter marks only earlier chapters completed")
  func midBookChapterMarksEarlierChaptersCompleted() {
    let rows = ChapterSelectorPresentation.rows(chapters: chapters, currentTime: 1_895)

    #expect(rows[1].isCurrent == true)
    #expect(rows.map(\.isCompleted) == [true, false, false])
  }

  @Test("last chapter current marks every earlier chapter completed")
  func lastChapterCurrentMarksAllEarlierChaptersCompleted() {
    let rows = ChapterSelectorPresentation.rows(chapters: chapters, currentTime: 3_800)

    #expect(rows[2].isCurrent == true)
    #expect(rows.map(\.isCompleted) == [true, true, false])
  }

  @Test("time exactly on a chapter boundary belongs to the chapter that starts there")
  func boundaryTimeBelongsToTheStartingChapter() {
    let rows = ChapterSelectorPresentation.rows(chapters: chapters, currentTime: 65)

    #expect(rows[1].isCurrent == true)
    #expect(rows[0].isCompleted == true)
    #expect(rows[1].isCompleted == false)
  }

  @Test("a finished item marks every chapter completed, with no playback position needed")
  func finishedItemMarksEveryChapterCompleted() {
    let rows = ChapterSelectorPresentation.rows(chapters: chapters, isFinished: true)

    #expect(rows.map(\.isCompleted) == [true, true, true])
    #expect(rows.map(\.isCurrent) == [false, false, false])
  }

  @Test("re-listening to a finished item still marks the playing chapter current")
  func finishedItemStillMarksThePlayingChapterCurrent() {
    let rows = ChapterSelectorPresentation.rows(
      chapters: chapters, currentTime: 30, isFinished: true)

    #expect(rows[0].isCurrent == true)
    // Finished is the item's own state, not a position: the chapters ahead of the playhead stay
    // completed rather than reverting as soon as playback restarts.
    #expect(rows.map(\.isCompleted) == [true, true, true])
  }
}
