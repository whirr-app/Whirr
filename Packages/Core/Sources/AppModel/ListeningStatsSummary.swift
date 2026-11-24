import Foundation
import Persistence

/// The figures Home's card and the Stats screen show, derived on the device from the account's
/// stored snapshot.
///
/// The server keys each day by its own time zone and counts a session's whole length toward the
/// day it started. Keys are read in the device's calendar without correction, so a device far from
/// the server's zone can see today's listening land on yesterday.
public struct ListeningStatsSummary: Sendable, Equatable {
  public struct DailyTotal: Sendable, Equatable, Identifiable {
    /// The start of the day in the calendar the summary was made with.
    public let date: Date
    public let seconds: Double
    public var id: Date { date }

    public init(date: Date, seconds: Double) {
      self.date = date
      self.seconds = seconds
    }
  }

  public struct WeekdayTotal: Sendable, Equatable, Identifiable {
    /// `Calendar` numbering: Sunday is 1.
    public let weekday: Int
    public let seconds: Double
    public var id: Int { weekday }

    public init(weekday: Int, seconds: Double) {
      self.weekday = weekday
      self.seconds = seconds
    }
  }

  /// A day with less than this much listening neither extends nor starts a streak.
  public static let streakThresholdSeconds: Double = 60
  static let dailySeriesLength = 30
  static let topTitleCount = 10
  /// 53 weeks, so a full-year heatmap grid always has a whole number of columns however the weeks
  /// align with today.
  public static let historyLength = 371

  public let fetchedAt: Date
  public let todaySeconds: Double
  /// Today and the six days before it.
  public let lastSevenDaysSeconds: Double
  /// The server's all-time figure, which also covers days older than the snapshot keeps.
  public let totalSeconds: Double
  /// Consecutive qualifying days ending today, or ending yesterday while today has none yet.
  public let streakDays: Int
  /// Thirty days ending today, oldest first, with days without listening as zero.
  public let lastThirtyDays: [DailyTotal]
  /// A full year ending today, oldest first, with days without listening as zero.
  public let history: [DailyTotal]
  /// The start of the earliest day the snapshot holds, or nil when it holds none. A heatmap reads
  /// a day before this as "before the record began", distinct from a day with no listening.
  public let historyStart: Date?
  /// All seven weekdays, starting at the calendar's first weekday.
  public let weekdays: [WeekdayTotal]
  /// The largest titles, largest first.
  public let topTitles: [ListeningStatsSnapshot.Title]
  /// Every title the snapshot holds, largest first.
  public let titles: [ListeningStatsSnapshot.Title]

  public static func make(snapshot: ListeningStatsSnapshot, now: Date, calendar: Calendar) -> ListeningStatsSummary {
    var secondsByKey: [String: Double] = [:]
    for day in snapshot.days { secondsByKey[day.date, default: 0] += day.seconds }

    let today = calendar.startOfDay(for: now)
    func day(_ offset: Int) -> Date {
      calendar.date(byAdding: .day, value: -offset, to: today) ?? today
    }
    func seconds(_ date: Date) -> Double {
      secondsByKey[key(for: date, calendar: calendar)] ?? 0
    }

    let todaySeconds = seconds(today)
    let lastSevenDays = (0..<7).reduce(0) { $0 + seconds(day($1)) }
    let history = (0..<Self.historyLength).reversed().map { offset -> DailyTotal in
      let date = day(offset)
      return DailyTotal(date: date, seconds: seconds(date))
    }
    // The earliest key, not the earliest day in `history`: a listener with no recorded day yet has
    // no start at all, rather than one at the window's edge.
    let historyStart = snapshot.days.compactMap { entry in
      date(forKey: entry.date, calendar: calendar).map { calendar.startOfDay(for: $0) }
    }.min()

    // A run can be no longer than the days the snapshot holds, which bounds the walk.
    var streak = 0
    var offset = todaySeconds >= streakThresholdSeconds ? 0 : 1
    while streak < snapshot.days.count, seconds(day(offset)) >= streakThresholdSeconds {
      streak += 1
      offset += 1
    }

    let weekdays = (0..<7).map { index -> WeekdayTotal in
      let weekday = (calendar.firstWeekday - 1 + index) % 7 + 1
      return WeekdayTotal(weekday: weekday, seconds: snapshot.weekdaySeconds[weekday] ?? 0)
    }

    let titles = snapshot.titles.sorted { $0.seconds > $1.seconds }

    return ListeningStatsSummary(
      fetchedAt: snapshot.fetchedAt,
      todaySeconds: todaySeconds,
      lastSevenDaysSeconds: lastSevenDays,
      totalSeconds: snapshot.totalSeconds,
      streakDays: streak,
      lastThirtyDays: Array(history.suffix(dailySeriesLength)),
      history: history,
      historyStart: historyStart,
      weekdays: weekdays,
      topTitles: Array(titles.prefix(topTitleCount)),
      titles: titles)
  }

  /// Today and the six days before it, oldest first: the tail of `lastThirtyDays`.
  public var lastSevenDays: ArraySlice<DailyTotal> { lastThirtyDays.suffix(7) }

  /// The days in `history` that are on or after `historyStart` and reach the streak threshold.
  public var historyDaysListened: Int {
    history.reduce(0) { count, day in
      guard day.seconds >= Self.streakThresholdSeconds else { return count }
      if let historyStart, day.date < historyStart { return count }
      return count + 1
    }
  }

  /// The seven days before `lastSevenDays`, the basis the Stats screen compares the week with.
  public var previousSevenDaysSeconds: Double {
    lastThirtyDays.dropLast(7).suffix(7).reduce(0) { $0 + $1.seconds }
  }

  /// The 30-day series spread over all thirty days. Days without listening count, so the figure
  /// is a daily rate rather than an average listening session.
  public var lastThirtyDaysAverageSeconds: Double {
    guard lastThirtyDays.isEmpty == false else { return 0 }
    return lastThirtyDays.reduce(0) { $0 + $1.seconds } / Double(lastThirtyDays.count)
  }

  /// Whole minutes, reading "0 min" below one minute: a stats figure of nothing is a real zero,
  /// not the "unknown" `PodcastCopy.duration(seconds:)` gives an episode with no length.
  public static func durationText(seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 60 else { return "0 min" }
    return DurationText.long(seconds)
  }

  /// The server's `YYYY-MM-DD` key for the calendar day containing `date`.
  static func key(for date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// The day a server `YYYY-MM-DD` key names in `calendar`, or nil if it is not a day key.
  static func date(forKey key: String, calendar: Calendar) -> Date? {
    let parts = key.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
      let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
    else { return nil }
    return calendar.date(from: DateComponents(year: year, month: month, day: day))
  }
}
