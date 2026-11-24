import AppModel
import Foundation
import Persistence
import Testing
import WidgetProtocol

@testable import Whirr

@Suite("Widget stats assembly")
struct WidgetStatsAssemblyTests {
  /// 2026-03-10 12:00 in London.
  static let now = Date(timeIntervalSince1970: 1_773_144_000)
  static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/London")!
    return calendar
  }()

  @Test("the window is the eight days ending today, oldest first, with missing days as zero")
  func windowIsZeroFilled() throws {
    let stats = try #require(
      Self.make(days: [("2026-03-10", 600), ("2026-03-07", 120), ("2026-02-20", 900)]))

    #expect(stats.days.map(\.date) == (3...10).map { String(format: "2026-03-%02d", $0) })
    #expect(stats.days.map(\.seconds) == [0, 0, 0, 0, 120, 0, 0, 600])
    #expect(stats.totalSeconds == 5_000)
    #expect(stats.fetchedAt == Self.now)
  }

  @Test("a run of qualifying days before the window is carried as a count")
  func runBeforeTheWindow() throws {
    // 2026-03-02 is the day before the window; four qualifying days end there, then a short one.
    let stats = try #require(
      Self.make(days: [
        ("2026-02-26", 30), ("2026-02-27", 60), ("2026-02-28", 300), ("2026-03-01", 61),
        ("2026-03-02", 3_600), ("2026-03-03", 600),
      ]))

    #expect(stats.streakDaysBeforeWindow == 4)
  }

  @Test("no listening the day before the window carries no run")
  func noRunBeforeTheWindow() throws {
    let stats = try #require(Self.make(days: [("2026-03-01", 3_600), ("2026-03-03", 600)]))

    #expect(stats.streakDaysBeforeWindow == 0)
  }

  @Test("duplicate keys add up and impossible values count as nothing")
  func sanitisesDays() throws {
    let stats = try #require(
      Self.make(
        days: [("2026-03-10", 100), ("2026-03-10", 50), ("2026-03-09", -.infinity), ("2026-03-08", .nan)],
        total: .nan))

    #expect(stats.days.last?.seconds == 150)
    #expect(stats.days.dropLast().allSatisfy { $0.seconds == 0 })
    #expect(stats.totalSeconds == 0)
  }

  @Test("the widget's streak threshold is the app's")
  func thresholdsAgree() {
    #expect(WidgetStatsPresentation.streakThresholdSeconds == ListeningStatsSummary.streakThresholdSeconds)
  }

  @Test(
    "the widget words a duration as the app's Stats screen does",
    arguments: [0, 59, 60, 61, 720, 3_599, 3_600, 3_900, 7_200, 90_061, Double.nan, -5])
  func durationWordingAgrees(seconds: Double) {
    #expect(
      WidgetStatsPresentation.durationText(seconds: seconds)
        == ListeningStatsSummary.durationText(seconds: seconds))
  }

  @Test("the widget derives the same today, week and streak the app shows")
  func agreesWithTheAppSummary() throws {
    let snapshot = Self.snapshot(
      days: [
        ("2026-02-25", 120), ("2026-02-26", 900), ("2026-02-27", 60), ("2026-02-28", 300),
        ("2026-03-01", 61), ("2026-03-02", 3_600), ("2026-03-03", 600), ("2026-03-04", 900),
        ("2026-03-05", 120), ("2026-03-06", 75), ("2026-03-07", 1_200), ("2026-03-08", 90),
        ("2026-03-09", 400), ("2026-03-10", 30),
      ], total: 50_000)
    let stats = try #require(WidgetStatsAssembly.make(snapshot: snapshot, now: Self.now, calendar: Self.calendar))
    let summary = ListeningStatsSummary.make(snapshot: snapshot, now: Self.now, calendar: Self.calendar)
    let widget = WidgetStatsPresentation(stats: stats, now: Self.now, calendar: Self.calendar)

    #expect(widget.todaySeconds == summary.todaySeconds)
    #expect(widget.lastSevenDaysSeconds == summary.lastSevenDaysSeconds)
    #expect(widget.streakDays == summary.streakDays)
    #expect(widget.streakDays == 13)
  }

  @Test("the widget's day key is the one the widget protocol reads")
  func dayKeyIsTheWidgetProtocolBuilder() {
    for day in [Self.now, Self.now.addingTimeInterval(-86_400), Date(timeIntervalSince1970: 1_772_000_000)] {
      #expect(
        WidgetStatsAssembly.key(for: day, calendar: Self.calendar)
          == WidgetStatsPresentation.key(for: day, calendar: Self.calendar))
    }
    #expect(WidgetStatsPresentation.key(for: Self.now, calendar: Self.calendar) == "2026-03-10")
  }

  @Test("a day keyed by the widget protocol is read by the app's summary")
  func widgetDayKeyIsReadByTheAppSummary() {
    let key = WidgetStatsPresentation.key(for: Self.now, calendar: Self.calendar)
    let summary = ListeningStatsSummary.make(
      snapshot: Self.snapshot(days: [(key, 240)], total: 240), now: Self.now,
      calendar: Self.calendar)

    #expect(summary.todaySeconds == 240)
  }

  private static func make(days: [(String, Double)], total: Double = 5_000) -> WidgetStats? {
    WidgetStatsAssembly.make(snapshot: snapshot(days: days, total: total), now: now, calendar: calendar)
  }

  private static func snapshot(days: [(String, Double)], total: Double) -> ListeningStatsSnapshot {
    ListeningStatsSnapshot(
      fetchedAt: now, totalSeconds: total,
      days: days.map { ListeningStatsSnapshot.Day(date: $0.0, seconds: $0.1) }, weekdaySeconds: [:],
      titles: [])
  }
}
