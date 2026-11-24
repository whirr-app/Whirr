import Foundation

/// What the Stats widget draws, derived at render time from `WidgetStats`: the
/// extension works out "today" and the streak itself so the figures don't go stale at midnight.
/// Listening since the last fetch is not counted.
public struct WidgetStatsPresentation: Sendable, Equatable {
  public struct Day: Sendable, Equatable {
    /// The start of the day in the calendar the presentation was made with.
    public let date: Date
    public let seconds: Double
    /// Whether the day reaches `WidgetStatsPresentation.streakThresholdSeconds`.
    public let listened: Bool

    public init(date: Date, seconds: Double) {
      self.date = date
      self.seconds = seconds
      self.listened = seconds >= WidgetStatsPresentation.streakThresholdSeconds
    }
  }

  /// A day with less than this much listening neither extends nor starts a streak. Mirrors
  /// `ListeningStatsSummary.streakThresholdSeconds` in AppModel, which WidgetProtocol cannot
  /// import; an app-side test pins the two equal.
  public static let streakThresholdSeconds: Double = 60

  /// A snapshot older than this is shown as "as of <date>".
  static let outdatedAfter: TimeInterval = 24 * 60 * 60

  public let todaySeconds: Double
  /// Today and the six days before it.
  public let lastSevenDaysSeconds: Double
  /// Today and the six days before it, oldest first.
  public let lastSevenDays: [Day]
  public let streakDays: Int
  public let totalSeconds: Double
  public let fetchedAt: Date
  public let isOutdated: Bool

  public init(stats: WidgetStats, now: Date, calendar: Calendar) {
    var secondsByKey: [String: Double] = [:]
    for day in stats.days { secondsByKey[day.date, default: 0] += day.seconds }

    let today = calendar.startOfDay(for: now)
    func date(_ offset: Int) -> Date {
      calendar.date(byAdding: .day, value: -offset, to: today) ?? today
    }
    func seconds(_ date: Date) -> Double {
      secondsByKey[Self.key(for: date, calendar: calendar)] ?? 0
    }

    let week = (0..<7).reversed().map { offset -> Day in
      let day = date(offset)
      return Day(date: day, seconds: seconds(day))
    }
    let todaySeconds = seconds(today)
    self.lastSevenDays = week
    self.todaySeconds = todaySeconds
    self.lastSevenDaysSeconds = week.reduce(0) { $0 + $1.seconds }
    self.totalSeconds = stats.totalSeconds
    self.fetchedAt = stats.fetchedAt
    self.isOutdated = now.timeIntervalSince(stats.fetchedAt) > Self.outdatedAfter

    // The window is consecutive days, so its oldest day bounds the walk. A day newer than the
    // window counts as zero; a step past its oldest day means the whole run inside it qualified.
    var streak = 0
    if let oldest = stats.days.first.flatMap({ WidgetValidation.dayNumber($0.date) }) {
      var offset = todaySeconds >= Self.streakThresholdSeconds ? 0 : 1
      while offset <= stats.days.count + 1 {
        let day = date(offset)
        if let number = WidgetValidation.dayNumber(Self.key(for: day, calendar: calendar)),
          number < oldest
        {
          if streak > 0 { streak += stats.streakDaysBeforeWindow }
          break
        }
        guard seconds(day) >= Self.streakThresholdSeconds else { break }
        streak += 1
        offset += 1
      }
    }
    self.streakDays = streak
  }

  /// The next local midnight after `after`, when the timeline needs a fresh entry.
  public static func nextMidnight(after: Date, calendar: Calendar) -> Date {
    let start = calendar.startOfDay(for: after)
    return calendar.date(byAdding: .day, value: 1, to: start) ?? after.addingTimeInterval(86_400)
  }

  /// "1 hr 5 min", "2 hr" or "12 min"; below one minute (or unknown) is "0 min". Owned by
  /// `AppModel.DurationText.long`; WidgetProtocol is dependency-free, so this is a deliberate copy
  /// pinned by the app's `WidgetStatsAssemblyTests` against the app's own wording.
  public static func durationText(seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 60 else { return "0 min" }
    let minutes = Int(min(seconds, 1e9) / 60)
    let hours = minutes / 60
    let rest = minutes % 60
    if hours == 0 { return "\(rest) min" }
    return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
  }

  /// The server's `YYYY-MM-DD` key, as `ListeningStatsSummary.key(for:calendar:)` builds it.
  /// The app writes widget days with this and the extension reads them with it.
  public static func key(for date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }
}
