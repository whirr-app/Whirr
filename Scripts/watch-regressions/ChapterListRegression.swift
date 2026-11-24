import Foundation
import PlayerCore

@main
struct ChapterListRegression {
  static func main() {
    rowsUseTitlesAndNumberUntitledChapters()
    currentRowFollowsThePlayhead()
    chaptersPastTheLoadedDurationAreNotOffered()
    publishedDatesUseThePinnedGMTCalendar()
    print("Watch chapter list: titles, current chapter and seekable range passed")
  }

  /// 2024-06-15T23:30:00Z is June 16 in any zone east of GMT (London in summer included), so a
  /// device-calendar formatter would read the next day. Pinned by the app's own boundary-date test.
  private static func publishedDatesUseThePinnedGMTCalendar() {
    let date = Date(timeIntervalSince1970: 1_718_494_200)
    precondition(WatchDisplayFormatting.date(date) == "Jun 15, 2024")
  }

  private static let map = PlaybackChapterMap(chapters: [
    PlaybackChapter(title: " Opening ", start: 0, end: 600),
    PlaybackChapter(title: "   ", start: 600, end: 1200),
    PlaybackChapter(title: nil, start: 1200, end: 1800),
  ])

  private static func rowsUseTitlesAndNumberUntitledChapters() {
    let rows = WatchDisplayFormatting.chapterRows(map, duration: 1800, position: 0)
    precondition(rows.map(\.title) == ["Opening", "Chapter 2", "Chapter 3"])
    precondition(rows.map(\.start) == [0, 600, 1200])
    precondition(Set(rows.map(\.id)).count == rows.count)
  }

  private static func currentRowFollowsThePlayhead() {
    precondition(WatchDisplayFormatting.chapterRows(map, duration: 1800, position: 30).map(\.isCurrent) == [
      true, false, false,
    ])
    // A shared boundary belongs to the later chapter, as PlaybackChapterMap resolves it.
    precondition(WatchDisplayFormatting.chapterRows(map, duration: 1800, position: 600).map(\.isCurrent) == [
      false, true, false,
    ])
    let gap = PlaybackChapterMap(chapters: [
      PlaybackChapter(title: "A", start: 0, end: 100), PlaybackChapter(title: "B", start: 200, end: 300),
    ])
    precondition(!WatchDisplayFormatting.chapterRows(gap, duration: 300, position: 150).contains(where: \.isCurrent))
  }

  private static func chaptersPastTheLoadedDurationAreNotOffered() {
    precondition(WatchDisplayFormatting.chapterRows(map, duration: 1000, position: 0).map(\.start) == [0, 600])
    precondition(WatchDisplayFormatting.chapterRows(map, duration: 0, position: 0).isEmpty)
    precondition(WatchDisplayFormatting.chapterRows(map, duration: .nan, position: 0).isEmpty)
    precondition(WatchDisplayFormatting.chapterRows(.init(chapters: []), duration: 1800, position: 0).isEmpty)
  }
}
