import AppModel
import Foundation
import Persistence
import WidgetProtocol

/// The stats part of the widget snapshot, from the account's stored listening-stats snapshot.
/// The extension derives "today" and the streak at render time, so the snapshot carries dated
/// days. Keyed as `ListeningStatsSummary` does: server `YYYY-MM-DD` read in the device's calendar.
nonisolated enum WidgetStatsAssembly {
  /// The window ends on the publication's day. One day longer than a week, so a widget drawn the
  /// day after the last publication still has a full seven days ending yesterday.
  static let windowDays = WidgetStats.maxDays

  static func make(snapshot: ListeningStatsSnapshot, now: Date, calendar: Calendar) -> WidgetStats? {
    var secondsByKey: [String: Double] = [:]
    for day in snapshot.days where day.seconds.isFinite && day.seconds > 0 {
      secondsByKey[day.date, default: 0] += day.seconds
    }
    let today = calendar.startOfDay(for: now)
    func date(_ offset: Int) -> Date? {
      calendar.date(byAdding: .day, value: -offset, to: today)
    }
    func seconds(_ offset: Int) -> Double {
      guard let date = date(offset) else { return 0 }
      return secondsByKey[key(for: date, calendar: calendar)] ?? 0
    }

    var days: [WidgetStats.Day] = []
    for offset in (0..<windowDays).reversed() {
      guard let date = date(offset),
        let day = try? WidgetStats.Day(date: key(for: date, calendar: calendar), seconds: seconds(offset))
      else { return nil }
      days.append(day)
    }

    // The qualifying run ending the day before the window. Bounded by the days the snapshot
    // holds, as `ListeningStatsSummary`'s own walk is.
    var before = 0
    while before < snapshot.days.count,
      seconds(windowDays + before) >= ListeningStatsSummary.streakThresholdSeconds
    {
      before += 1
    }

    let total = snapshot.totalSeconds.isFinite ? max(0, snapshot.totalSeconds) : 0
    return try? WidgetStats(
      days: days, streakDaysBeforeWindow: before, totalSeconds: total, fetchedAt: snapshot.fetchedAt)
  }

  /// `WidgetProtocol.WidgetStatsPresentation.key(for:calendar:)`, the extension's reader.
  static func key(for date: Date, calendar: Calendar) -> String {
    WidgetStatsPresentation.key(for: date, calendar: calendar)
  }
}
