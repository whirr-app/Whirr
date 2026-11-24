import Foundation
import Persistence
import Testing

@testable import AppModel

@Suite struct HomePodcastEpisodeDaySectionTests {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
  }()

  /// Saturday 7 November 2026, 07:59 London.
  private static let now = date(2026, 11, 7, 7, 59)

  // MARK: - Headings

  @Test("the last week reads as today, yesterday, then weekday names")
  func recentDaysReadRelatively() {
    #expect(heading(2026, 11, 7, 0, 1) == "Today")
    #expect(heading(2026, 11, 6, 23, 59) == "Yesterday")
    #expect(heading(2026, 11, 5, 12, 0) == "Thursday")
    #expect(heading(2026, 11, 1, 12, 0) == "Sunday")
  }

  @Test("a week ago or older names the date, with the year only when it differs")
  func olderDaysNameTheDate() {
    #expect(heading(2026, 10, 31, 12, 0) == "Oct 31")
    #expect(heading(2025, 12, 30, 12, 0) == "Dec 30, 2025")
  }

  @Test("a feed dated slightly in the future still files under today")
  func futureDatesFileUnderToday() {
    #expect(heading(2026, 11, 7, 23, 0) == "Today")
    #expect(heading(2026, 11, 9, 12, 0) == "Today")
  }

  @Test("days are the listener's local days, not UTC's")
  func daysFollowTheLocalCalendar() {
    var tokyo = Calendar(identifier: .gregorian)
    tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    // 6 Nov 20:00 London is 7 Nov 05:00 in Tokyo.
    let published = Self.date(2026, 11, 6, 20, 0)

    #expect(PodcastCopy.dayHeading(for: published, now: Self.now, calendar: Self.calendar) == "Yesterday")
    #expect(PodcastCopy.dayHeading(for: published, now: Self.now, calendar: tokyo) == "Today")
  }

  // MARK: - Grouping

  @Test("episodes group under their day in the order they arrive")
  func episodesGroupByDay() {
    let episodes = [
      episode("a", Self.date(2026, 11, 7, 6, 0)),
      episode("b", Self.date(2026, 11, 6, 18, 0)),
      episode("c", Self.date(2026, 11, 5, 21, 0)),
      episode("d", Self.date(2026, 11, 5, 9, 0)),
      episode("e", Self.date(2026, 11, 5, 8, 0)),
    ]

    let sections = HomePodcastEpisodeDaySection.sections(
      episodes, now: Self.now, calendar: Self.calendar)

    #expect(sections.map(\.title) == ["Today", "Yesterday", "Thursday"])
    #expect(sections.map { $0.episodes.map(\.episodeID) } == [["a"], ["b"], ["c", "d", "e"]])
  }

  @Test("an out-of-order episode joins its day's section rather than opening a second one")
  func outOfOrderEpisodeJoinsItsDay() {
    let episodes = [
      episode("a", Self.date(2026, 11, 7, 6, 0)),
      episode("b", Self.date(2026, 11, 6, 18, 0)),
      episode("c", Self.date(2026, 11, 7, 5, 0)),
    ]

    let sections = HomePodcastEpisodeDaySection.sections(
      episodes, now: Self.now, calendar: Self.calendar)

    #expect(sections.map(\.title) == ["Today", "Yesterday"])
    #expect(sections.map { $0.episodes.map(\.episodeID) } == [["a", "c"], ["b"]])
  }

  @Test("future-dated and today's episodes share one today section")
  func futureAndTodayShareASection() {
    let episodes = [
      episode("future", Self.date(2026, 11, 8, 6, 0)),
      episode("today", Self.date(2026, 11, 7, 6, 0)),
    ]

    let sections = HomePodcastEpisodeDaySection.sections(
      episodes, now: Self.now, calendar: Self.calendar)

    #expect(sections.map(\.title) == ["Today"])
    #expect(sections.first?.episodes.map(\.episodeID) == ["future", "today"])
  }

  @Test("section identities are stable and distinct")
  func sectionIdentitiesAreDistinct() {
    let episodes = [
      episode("a", Self.date(2026, 11, 7, 6, 0)),
      episode("b", Self.date(2026, 11, 6, 18, 0)),
    ]

    let sections = HomePodcastEpisodeDaySection.sections(
      episodes, now: Self.now, calendar: Self.calendar)
    let again = HomePodcastEpisodeDaySection.sections(
      episodes, now: Self.now, calendar: Self.calendar)

    #expect(Set(sections.map(\.id)).count == sections.count)
    #expect(sections.map(\.id) == again.map(\.id))
  }

  @Test("no episodes, no sections")
  func emptyInputHasNoSections() {
    #expect(HomePodcastEpisodeDaySection.sections([], now: Self.now, calendar: Self.calendar).isEmpty)
  }

  // MARK: - Fixtures

  private func heading(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> String {
    PodcastCopy.dayHeading(for: Self.date(y, m, d, h, min), now: Self.now, calendar: Self.calendar)
  }

  private static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
  }

  private func episode(_ id: String, _ publishedAt: Date) -> HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: "show", showTitle: "Show", showAuthor: nil, episodeID: id, title: id,
      subtitle: nil, publishedAt: publishedAt, durationSeconds: 3_600)
  }
}
