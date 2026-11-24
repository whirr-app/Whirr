import Foundation
import Persistence
import Testing

@testable import AppModel

/// The words the Home card and the Stats screen use.
@Suite struct ListeningStatsCopyTests {

  @Test(
    "the streak figure counts days",
    arguments: [(0, "None"), (1, "1 day"), (4, "4 days")])
  func streakFigure(days: Int, expected: String) {
    #expect(ListeningStatsCopy.streak(days: days) == expected)
  }

  @Test("the Home card's weekly total reads as a phrase")
  func lastSevenDaysHeadline() {
    #expect(ListeningStatsCopy.lastSevenDaysHeadline("1 hr 12 min") == "1 hr 12 min in the last 7 days")
  }

  @Test("the Home card reads as one sentence")
  func homeCardLabel() {
    let summary = Self.summary(days: ["2026-11-02": 600, "2026-11-03": 600, "2026-11-04": 600, "2026-11-05": 2_520])

    #expect(
      ListeningStatsCopy.homeCardAccessibilityLabel(summary)
        == "Listening: 42 min today, 1 hr 12 min in the last 7 days, 4-day streak")
  }

  @Test("the Home card reads the time saved once it reaches a minute")
  func homeCardLabelWithTimeSaved() {
    let summary = Self.summary(days: [:])

    #expect(
      ListeningStatsCopy.homeCardAccessibilityLabel(
        summary, timeSaved: TimeSavedTotals(ads: 600, silence: 300, speed: 2_700))
        == "Listening: 0 min today, 0 min in the last 7 days, no streak, 1 hr saved")
    #expect(
      ListeningStatsCopy.homeCardAccessibilityLabel(
        summary, timeSaved: TimeSavedTotals(ads: 20, silence: 10, speed: 29))
        == "Listening: 0 min today, 0 min in the last 7 days, no streak")
  }

  @Test(
    "the time-saved line is hidden under a minute and counts hours past a day",
    arguments: [
      (59.0, nil),
      (60, "1 min saved"),
      (3_600, "1 hr saved"),
      (11_520, "3 hr 12 min saved"),
      (93_900, "26 hr 5 min saved"),
      (Double.nan, nil),
    ] as [(Double, String?)])
  func timeSavedLine(seconds: Double, expected: String?) {
    #expect(
      ListeningStatsCopy.timeSavedLine(TimeSavedTotals(ads: 0, silence: 0, speed: seconds))
        == expected)
  }

  @Test("the shown total is the sum of the shown parts, so the legend adds up")
  func timeSavedShownTotal() {
    // 4 min 30 s in all, but each source shows "1 min".
    let totals = TimeSavedTotals(ads: 90, silence: 90, speed: 90)

    #expect(ListeningStatsCopy.timeSavedShownTotal(totals) == 180)
    #expect(ListeningStatsCopy.timeSavedLine(totals) == "3 min saved")
    #expect(ListeningStatsCopy.timeSavedLine(TimeSavedTotals(ads: 59, silence: 59, speed: 59)) == nil)
  }

  @Test("the time-saved totals sum by source")
  func timeSavedTotalsSum() {
    var totals = TimeSavedTotals(ads: 1, silence: 2, speed: 3)
    totals[.ads] += 4

    #expect(totals + TimeSavedTotals(ads: 1, silence: 1, speed: 1) == TimeSavedTotals(ads: 6, silence: 3, speed: 4))
    #expect(totals.total == 10)
  }

  @Test("the Home card says so when there is no streak")
  func homeCardLabelWithoutStreak() {
    let summary = Self.summary(days: [:])

    #expect(
      ListeningStatsCopy.homeCardAccessibilityLabel(summary)
        == "Listening: 0 min today, 0 min in the last 7 days, no streak")
  }

  @Test(
    "the week compares with the week before in words, not only a sign",
    arguments: [
      (1_180.0, 1_000.0, "Up 18% on the week before"),
      (880, 1_000, "Down 12% on the week before"),
      (1_004, 1_000, "Same as the week before"),
      (0, 1_000, "Down 100% on the week before"),
    ])
  func weekComparison(current: Double, previous: Double, expected: String) {
    #expect(ListeningStatsCopy.weekComparison(current: current, previous: previous) == expected)
  }

  @Test("there is no comparison against a week with under a minute of listening")
  func weekComparisonWithoutBasis() {
    #expect(ListeningStatsCopy.weekComparison(current: 600, previous: 59) == nil)
    #expect(ListeningStatsCopy.weekComparison(current: 600, previous: 0) == nil)
  }

  @Test("a large rise is not capped")
  func weekComparisonLargeRise() {
    #expect(ListeningStatsCopy.weekComparison(current: 6_000, previous: 600) == "Up 900% on the week before")
  }

  @Test("the average line is labelled with its figure")
  func averageLabel() {
    #expect(ListeningStatsCopy.dailyAverage(seconds: 2_520) == "Avg 42 min")
    #expect(ListeningStatsCopy.dailyAverageAccessibilityLabel(seconds: 2_520) == "Daily average, 42 min")
  }

  @Test("a title without metadata still has a name")
  func untitledItem() {
    let title = ListeningStatsSnapshot.Title(serverItemId: "i1", title: nil, author: nil, seconds: 60)
    #expect(ListeningStatsCopy.titleName(title) == ListeningStatsCopy.untitledItem)

    let blank = ListeningStatsSnapshot.Title(serverItemId: "i1", title: "  ", author: nil, seconds: 60)
    #expect(ListeningStatsCopy.titleName(blank) == ListeningStatsCopy.untitledItem)
  }

  @Test(
    "the history caption counts days, singular at one",
    arguments: [(0, "Listened on 0 days"), (1, "Listened on 1 day"), (4, "Listened on 4 days")])
  func historyCaption(days: Int, expected: String) {
    #expect(ListeningStatsCopy.historyCaption(daysListened: days) == expected)
  }

  @Test(
    "today is read as a share of the daily average",
    arguments: [
      (600.0, 600.0, "100% of your daily average"),
      (900, 600, "150% of your daily average"),
      (100, 240, "42% of your daily average"),
      (0, 600, "0% of your daily average"),
      // 0.5% rounds away from zero.
      (3, 600, "1% of your daily average"),
    ])
  func todayAgainstAverage(today: Double, average: Double, expected: String) {
    #expect(ListeningStatsCopy.todayAgainstAverage(today: today, average: average) == expected)
  }

  @Test("there is no share of an average under a minute or without a finite figure")
  func todayAgainstAverageWithoutBasis() {
    #expect(ListeningStatsCopy.todayAgainstAverage(today: 600, average: 59) == nil)
    #expect(ListeningStatsCopy.todayAgainstAverage(today: 600, average: 0) == nil)
    #expect(ListeningStatsCopy.todayAgainstAverage(today: 600, average: .nan) == nil)
    #expect(ListeningStatsCopy.todayAgainstAverage(today: 600, average: .infinity) == nil)
    #expect(ListeningStatsCopy.todayAgainstAverage(today: .nan, average: 600) == nil)
    #expect(ListeningStatsCopy.todayAgainstAverage(today: .infinity, average: 600) == nil)
  }

  @Test("an empty list says which kind of title is missing")
  func noTitles() {
    #expect(
      ListeningStatsCopy.noTitles(podcasts: true) == "No podcasts among your most-listened titles yet.")
    #expect(
      ListeningStatsCopy.noTitles(podcasts: false) == "No books among your most-listened titles yet.")
  }

  @Test("a media share reads its label, duration and percentage")
  func mediaShareAccessibilityLabel() {
    #expect(
      ListeningStatsCopy.mediaShareAccessibilityLabel(label: "Books", seconds: 2_520, fraction: 1.0 / 3)
        == "Books, 42 min, 33 percent")
    #expect(
      ListeningStatsCopy.mediaShareAccessibilityLabel(label: "Podcasts", seconds: 3_600, fraction: 0.25)
        == "Podcasts, 1 hr, 25 percent")
  }

  @Test(
    "the heatmap reads the year's day count, singular at one",
    arguments: [(1, "Past year, listened on 1 day"), (4, "Past year, listened on 4 days")])
  func heatmapAccessibilityLabel(days: Int, expected: String) {
    #expect(ListeningStatsCopy.heatmapAccessibilityLabel(daysListened: days) == expected)
  }

  @Test("Home's shorter heatmap names its own span, singular at one day")
  func recentWeeks() {
    #expect(ListeningStatsCopy.recentWeeksTitle(weeks: 16) == "Last 16 Weeks")
    #expect(
      ListeningStatsCopy.recentWeeksAccessibilityLabel(weeks: 16, daysListened: 1)
        == "Last 16 weeks, listened on 1 day")
    #expect(
      ListeningStatsCopy.recentWeeksAccessibilityLabel(weeks: 16, daysListened: 9)
        == "Last 16 weeks, listened on 9 days")
  }

  private static func summary(days: [String: Double]) -> ListeningStatsSummary {
    ListeningStatsSummary.make(
      snapshot: ListeningStatsSummaryTests.snapshot(days: days),
      now: ListeningStatsSummaryTests.date(2026, 11, 5, hour: 12),
      calendar: ListeningStatsSummaryTests.calendar)
  }
}
