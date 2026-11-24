import Foundation
import Persistence
import Testing

@testable import AppModel

/// The figures Home and the Stats screen show, derived on the device from the server's per-day
/// map.
@Suite struct ListeningStatsSummaryTests {

  @Test("today, the last seven days and the all-time total")
  func headlineFigures() {
    let summary = Self.summary(
      days: ["2026-10-29": 999, "2026-10-30": 100, "2026-11-04": 600, "2026-11-05": 420],
      total: 5000,
      now: Self.date(2026, 11, 5, hour: 18))

    #expect(summary.todaySeconds == 420)
    // 30 Oct to 5 Nov inclusive is seven days; 29 Oct is outside.
    #expect(summary.lastSevenDaysSeconds == 1120)
    #expect(summary.totalSeconds == 5000)
  }

  @Test("no listening today reads as zero, not as yesterday's figure")
  func todayAbsent() {
    let summary = Self.summary(days: ["2026-11-04": 600], now: Self.date(2026, 11, 5, hour: 9))

    #expect(summary.todaySeconds == 0)
  }

  @Test(
    "the streak counts back from today, or from yesterday when today has none yet",
    arguments: [
      // today + three days before
      (["2026-11-02": 60, "2026-11-03": 60, "2026-11-04": 60, "2026-11-05": 60], 4),
      // nothing yet today: the run ending yesterday still counts
      (["2026-11-03": 60, "2026-11-04": 60], 2),
      // a gap yesterday and nothing today: broken
      (["2026-11-02": 600, "2026-11-03": 600], 0),
      // under a minute does not count, and breaks the run
      (["2026-11-03": 600, "2026-11-04": 59, "2026-11-05": 600], 1),
      ([:], 0),
    ] as [([String: Double], Int)])
  func streak(days: [String: Double], expected: Int) {
    let summary = Self.summary(days: days, now: Self.date(2026, 11, 5, hour: 12))

    #expect(summary.streakDays == expected)
  }

  @Test("the 30-day series is zero-filled, oldest first, and ends today")
  func dailySeries() {
    let summary = Self.summary(
      days: ["2026-10-07": 5, "2026-10-08": 30, "2026-11-05": 420], now: Self.date(2026, 11, 5, hour: 12))

    #expect(summary.lastThirtyDays.count == 30)
    #expect(summary.lastThirtyDays.first?.date == Self.date(2026, 10, 7))
    #expect(summary.lastThirtyDays.first?.seconds == 5)
    #expect(summary.lastThirtyDays.last?.date == Self.date(2026, 11, 5))
    #expect(summary.lastThirtyDays.last?.seconds == 420)
    #expect(summary.lastThirtyDays.reduce(0) { $0 + $1.seconds } == 455)
  }

  @Test("days step correctly across a daylight-saving change")
  func daylightSaving() {
    var london = Calendar(identifier: .gregorian)
    london.timeZone = TimeZone(identifier: "Europe/London")!
    // UK clocks went back on 25 October 2026.
    let now = DateComponents(calendar: london, year: 2026, month: 10, day: 26, hour: 0, minute: 30).date!
    let summary = ListeningStatsSummary.make(
      snapshot: Self.snapshot(days: ["2026-10-24": 60, "2026-10-25": 60, "2026-10-26": 60]), now: now,
      calendar: london)

    #expect(summary.todaySeconds == 60)
    #expect(summary.streakDays == 3)
    #expect(Set(summary.lastThirtyDays.suffix(3).map(\.seconds)) == [60])
  }

  @Test("a device ahead of the server's day reads the server's keys as its own calendar days")
  func timeZoneOffsetIsNotCorrected() {
    var auckland = Calendar(identifier: .gregorian)
    auckland.timeZone = TimeZone(identifier: "Pacific/Auckland")!
    // 08:00 on 6 Nov in Auckland is still 5 Nov on a UTC server, so today's listening is on the
    // server's 5 Nov key, which the device reads as yesterday. This is an accepted limitation.
    let now = DateComponents(calendar: auckland, year: 2026, month: 11, day: 6, hour: 8).date!
    let summary = ListeningStatsSummary.make(
      snapshot: Self.snapshot(days: ["2026-11-05": 300]), now: now, calendar: auckland)

    #expect(summary.todaySeconds == 0)
    #expect(summary.streakDays == 1)
  }

  @Test("weekday totals follow the calendar's first weekday and include empty days")
  func weekdayOrder() {
    var monday = Self.calendar
    monday.firstWeekday = 2
    let summary = ListeningStatsSummary.make(
      snapshot: Self.snapshot(weekdays: [1: 10, 2: 20, 7: 70]), now: Self.date(2026, 11, 5), calendar: monday)

    #expect(summary.weekdays.map(\.weekday) == [2, 3, 4, 5, 6, 7, 1])
    #expect(summary.weekdays.map(\.seconds) == [20, 0, 0, 0, 0, 70, 10])
  }

  @Test("top titles are the ten largest")
  func topTitles() {
    let titles = (0..<12).map {
      ListeningStatsSnapshot.Title(serverItemId: "i\($0)", title: "T\($0)", author: nil, seconds: Double(100 - $0))
    }
    let summary = ListeningStatsSummary.make(
      snapshot: Self.snapshot(titles: titles), now: Self.date(2026, 11, 5), calendar: Self.calendar)

    #expect(summary.topTitles.map(\.serverItemId) == (0..<10).map { "i\($0)" })
  }

  @Test("the history covers a year of days, zero-filled, oldest first, ending today")
  func historyWindow() {
    let summary = Self.summary(
      days: ["2025-10-30": 999, "2025-10-31": 60, "2026-11-05": 600],
      now: Self.date(2026, 11, 5, hour: 12))

    // 371 days ending 5 Nov 2026 begin on 31 Oct 2025; 30 Oct falls a day before the window.
    #expect(summary.history.count == ListeningStatsSummary.historyLength)
    #expect(summary.history.first?.date == Self.date(2025, 10, 31))
    #expect(summary.history.first?.seconds == 60)
    #expect(summary.history.last?.date == Self.date(2026, 11, 5))
    #expect(summary.history.last?.seconds == 600)
    #expect(summary.history.first?.seconds == 60)
    #expect(summary.history.filter { $0.seconds > 0 }.count == 2)
  }

  @Test("the last thirty days are the tail of the history")
  func lastThirtyDaysAreTheHistoryTail() {
    let summary = Self.summary(days: ["2026-11-04": 60], now: Self.date(2026, 11, 5, hour: 12))

    #expect(summary.lastThirtyDays == Array(summary.history.suffix(30)))
    #expect(summary.lastThirtyDays.first?.date == Self.date(2026, 10, 7))
  }

  @Test("the record starts at the earliest day the snapshot holds")
  func historyStart() {
    let summary = Self.summary(
      days: ["2026-09-01": 60, "2026-10-30": 60, "2026-11-05": 60], now: Self.date(2026, 11, 5))

    #expect(summary.historyStart == Self.date(2026, 9, 1))
  }

  @Test("there is no record start without any days")
  func historyStartWithoutDays() {
    let summary = Self.summary(days: [:], now: Self.date(2026, 11, 5))

    #expect(summary.historyStart == nil)
  }

  @Test("an unparseable day key does not set the record start")
  func historyStartIgnoresUnparseableKey() {
    let summary = Self.summary(
      days: ["not-a-date": 60, "2026-10-30": 60], now: Self.date(2026, 11, 5))

    #expect(summary.historyStart == Self.date(2026, 10, 30))
  }

  @Test("every title is kept largest first, and the top titles are its first ten")
  func allTitles() {
    // Scrambled so the sort, not the fixture's order, decides the result.
    let titles = (0..<50).map {
      ListeningStatsSnapshot.Title(
        serverItemId: "i\($0)", title: "T\($0)", author: nil, seconds: Double(($0 * 7) % 50))
    }
    let summary = ListeningStatsSummary.make(
      snapshot: Self.snapshot(titles: titles), now: Self.date(2026, 11, 5), calendar: Self.calendar)

    #expect(summary.titles.count == 50)
    #expect(summary.titles.map(\.seconds) == (0..<50).map { Double($0) }.sorted(by: >))
    #expect(summary.topTitles == Array(summary.titles.prefix(10)))
  }

  @Test("the year counts its qualifying days and ignores shorter ones")
  func historyDaysListened() {
    let summary = Self.summary(
      days: [
        // Outside the 371-day window, so it never enters the history.
        "2025-10-30": 600,
        "2026-11-03": 59,
        "2026-11-04": 60,
        "2026-11-05": 900,
      ],
      now: Self.date(2026, 11, 5, hour: 12))

    #expect(summary.historyDaysListened == 2)
  }

  @Test("the seven days before the last seven are summed for comparison")
  func previousSevenDays() {
    let summary = Self.summary(
      days: [
        // 22 Oct is the 15th day back, outside both weeks; 23 to 29 Oct is the week before.
        "2026-10-22": 5_000, "2026-10-23": 300, "2026-10-29": 200, "2026-10-30": 100,
      ],
      now: Self.date(2026, 11, 5, hour: 18))

    #expect(summary.previousSevenDaysSeconds == 500)
    #expect(summary.lastSevenDaysSeconds == 100)
  }

  @Test("the daily average spreads the 30-day series over all thirty days, empty ones included")
  func dailyAverage() {
    let summary = Self.summary(
      days: ["2026-10-06": 9_999, "2026-10-08": 1_800, "2026-11-05": 1_800],
      now: Self.date(2026, 11, 5, hour: 18))

    // 6 Oct falls outside the thirty days ending 5 Nov, which begin on 7 Oct.
    #expect(summary.lastThirtyDaysAverageSeconds == 120)
  }

  @Test("the last seven days of the series run oldest first and end today")
  func recentDays() {
    let summary = Self.summary(days: ["2026-11-05": 60], now: Self.date(2026, 11, 5, hour: 18))

    #expect(summary.lastSevenDays.count == 7)
    #expect(summary.lastSevenDays.first?.date == Self.date(2026, 10, 30))
    #expect(summary.lastSevenDays.last?.seconds == 60)
  }

  @Test(
    "durations read as whole minutes, zero included",
    arguments: [(0.0, "0 min"), (59, "0 min"), (60, "1 min"), (3_600, "1 hr"), (3_900, "1 hr 5 min")])
  func durationText(seconds: Double, expected: String) {
    #expect(ListeningStatsSummary.durationText(seconds: seconds) == expected)
  }

  // MARK: - Fixtures

  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()

  static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
    DateComponents(calendar: calendar, year: year, month: month, day: day, hour: hour).date!
  }

  static func summary(days: [String: Double], total: Double = 0, now: Date) -> ListeningStatsSummary {
    ListeningStatsSummary.make(snapshot: snapshot(days: days, total: total), now: now, calendar: calendar)
  }

  static func snapshot(
    days: [String: Double] = [:],
    total: Double = 0,
    weekdays: [Int: Double] = [:],
    titles: [ListeningStatsSnapshot.Title] = []
  ) -> ListeningStatsSnapshot {
    ListeningStatsSnapshot(
      fetchedAt: Date(timeIntervalSince1970: 0),
      totalSeconds: total,
      days: days.sorted { $0.key < $1.key }.map { .init(date: $0.key, seconds: $0.value) },
      weekdaySeconds: weekdays,
      titles: titles)
  }
}
