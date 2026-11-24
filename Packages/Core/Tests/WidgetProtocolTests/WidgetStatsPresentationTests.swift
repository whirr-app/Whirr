import Foundation
import Testing

@testable import WidgetProtocol

@Suite struct WidgetStatsPresentationTests {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
  }()

  private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  /// 2026-03-10 at noon, a Tuesday.
  private var now: Date { date(2026, 3, 10) }

  /// A window ending `windowEnd` (default: today); `seconds` is newest first, so index 0 is the
  /// window's last day.
  private func stats(
    seconds: [Double], windowEnd: Date? = nil, before: Int = 0, fetchedAt: Date? = nil
  ) throws -> WidgetStats {
    let end = windowEnd ?? now
    var days: [WidgetStats.Day] = []
    for (offset, value) in seconds.enumerated().reversed() {
      let day = calendar.date(byAdding: .day, value: -offset, to: end)!
      days.append(
        try WidgetStats.Day(
          date: WidgetStatsPresentation.key(for: day, calendar: calendar), seconds: value))
    }
    return try WidgetStats(
      days: days, streakDaysBeforeWindow: before, totalSeconds: 9_000,
      fetchedAt: fetchedAt ?? end)
  }

  private func present(_ stats: WidgetStats, at moment: Date? = nil) -> WidgetStatsPresentation {
    WidgetStatsPresentation(stats: stats, now: moment ?? now, calendar: calendar)
  }

  @Test func thresholdIsOneMinute() {
    #expect(WidgetStatsPresentation.streakThresholdSeconds == 60)
  }

  @Test func theDayKeyIsYearMonthDayInTheInjectedCalendar() {
    // 23:30 UTC is the next day in a +1 zone, so the zone must come from the calendar, and the
    // format must not follow the device locale.
    let instant = Date(timeIntervalSince1970: 1_773_185_400)
    var tokyo = Calendar(identifier: .gregorian)
    tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!

    #expect(WidgetStatsPresentation.key(for: instant, calendar: utc) == "2026-03-10")
    #expect(WidgetStatsPresentation.key(for: instant, calendar: tokyo) == "2026-03-11")
  }

  @Test func totalsTodayAndTheLastSevenDays() throws {
    let result = present(try stats(seconds: [100, 200, 300, 400, 500, 600, 700, 800]))
    #expect(result.todaySeconds == 100)
    #expect(result.lastSevenDaysSeconds == 2_800)
    #expect(result.totalSeconds == 9_000)
    #expect(result.lastSevenDays.map(\.seconds) == [700, 600, 500, 400, 300, 200, 100])
    #expect(result.lastSevenDays.last?.date == calendar.startOfDay(for: now))
    #expect(result.lastSevenDays.allSatisfy { $0.listened })
  }

  @Test func missingDaysCountAsZero() throws {
    let result = present(try stats(seconds: [100, 100]))
    #expect(result.lastSevenDaysSeconds == 200)
    #expect(result.lastSevenDays.map(\.seconds) == [0, 0, 0, 0, 0, 100, 100])
  }

  @Test func streakEndingToday() throws {
    let result = present(try stats(seconds: [60, 120, 90, 0, 500, 500, 500, 500]))
    #expect(result.streakDays == 3)
  }

  @Test func streakEndingYesterdayWhileTodayIsBelowThreshold() throws {
    let result = present(try stats(seconds: [59, 120, 90, 0, 500, 500, 500, 500]))
    #expect(result.streakDays == 2)
    #expect(result.lastSevenDays.last?.listened == false)
  }

  @Test func subThresholdDayBreaksTheStreak() throws {
    let result = present(try stats(seconds: [100, 100, 59, 100, 100, 100, 100, 100], before: 5))
    #expect(result.streakDays == 2)
  }

  @Test func runReachingTheWindowStartAddsEarlierDays() throws {
    let result = present(try stats(seconds: Array(repeating: 100, count: 8), before: 4))
    #expect(result.streakDays == 12)
  }

  @Test func runNotReachingTheWindowStartIgnoresEarlierDays() throws {
    let result = present(try stats(seconds: [100, 100, 100, 100, 100, 100, 100, 0], before: 4))
    #expect(result.streakDays == 7)
    let broken = present(try stats(seconds: [100, 100, 0, 100, 100, 100, 100, 100], before: 4))
    #expect(broken.streakDays == 2)
  }

  @Test func renderingOneDayAfterTheWindowStillCounts() throws {
    let snapshot = try stats(seconds: Array(repeating: 100, count: 8), before: 4)
    let result = present(snapshot, at: date(2026, 3, 11))
    // Today is beyond the window and counts zero, so the run starts yesterday.
    #expect(result.todaySeconds == 0)
    #expect(result.streakDays == 12)
    #expect(result.lastSevenDaysSeconds == 600)
  }

  @Test func staleBeyondTheWindowGivesZero() throws {
    let snapshot = try stats(seconds: Array(repeating: 100, count: 8), before: 4)
    let result = present(snapshot, at: date(2026, 3, 14))
    #expect(result.todaySeconds == 0)
    #expect(result.lastSevenDaysSeconds == 300)
    #expect(result.streakDays == 0)
  }

  @Test func outdatedAfterMoreThanADay() throws {
    let fetched = date(2026, 3, 9, hour: 11)
    let old = present(try stats(seconds: [100], fetchedAt: fetched))
    #expect(old.isOutdated)
    #expect(old.fetchedAt == fetched)
    let recent = present(try stats(seconds: [100], fetchedAt: date(2026, 3, 9, hour: 13)))
    #expect(!recent.isOutdated)
  }

  @Test func nextMidnightIsTheStartOfTomorrow() {
    #expect(
      WidgetStatsPresentation.nextMidnight(after: now, calendar: calendar)
        == date(2026, 3, 11, hour: 0))
    #expect(
      WidgetStatsPresentation.nextMidnight(after: date(2026, 3, 10, hour: 0), calendar: calendar)
        == date(2026, 3, 11, hour: 0))
  }

  @Test func nextMidnightAcrossTheSpringDSTChange() {
    // Clocks go forward at 01:00 GMT on 2026-03-29, so that local day is 23 hours long.
    let midnight = WidgetStatsPresentation.nextMidnight(
      after: date(2026, 3, 28, hour: 18), calendar: calendar)
    #expect(midnight == date(2026, 3, 29, hour: 0))
    let following = WidgetStatsPresentation.nextMidnight(after: midnight, calendar: calendar)
    #expect(following == date(2026, 3, 30, hour: 0))
    #expect(following.timeIntervalSince(midnight) == 23 * 3_600)
  }

  @Test func durationText() {
    #expect(WidgetStatsPresentation.durationText(seconds: 0) == "0 min")
    #expect(WidgetStatsPresentation.durationText(seconds: 59) == "0 min")
    #expect(WidgetStatsPresentation.durationText(seconds: 720) == "12 min")
    #expect(WidgetStatsPresentation.durationText(seconds: 3_900) == "1 hr 5 min")
    #expect(WidgetStatsPresentation.durationText(seconds: 7_200) == "2 hr")
    #expect(WidgetStatsPresentation.durationText(seconds: .nan) == "0 min")
  }
}
