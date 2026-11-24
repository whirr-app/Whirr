import Foundation
import Persistence

/// User-facing copy for Home's listening-stats card and the Stats screen.
public enum ListeningStatsCopy {
  public static let title = "Listening Stats"
  public static let emptyMessage = "No listening recorded yet."
  /// No snapshot, and the fetch just failed.
  public static let unavailableMessage = "Your stats could not be loaded. Pull to try again."
  /// Matches the History sheet's wording for the same situation.
  public static let staleMessage = "These figures may be out of date."
  public static let openHint = "Shows your listening stats."

  public static let todayLabel = "Today"
  public static let lastSevenDaysLabel = "Last 7 Days"
  public static let allTimeLabel = "All Time"
  /// The Home card's weekly total, as a phrase rather than a figure and a label.
  public static func lastSevenDaysHeadline(_ duration: String) -> String { "\(duration) in the last 7 days" }
  public static let streakLabel = "Streak"

  public static let lastThirtyDaysTitle = "Last 30 Days"
  public static let weekdaysTitle = "By Weekday"
  /// The weekday totals are the server's all-time figures, unlike the 30-day chart above them.
  public static let weekdaysPeriod = "All time"
  public static let topTitlesTitle = "Most Listened"
  public static let untitledItem = "Untitled"

  public static let mediaSplitTitle = "Books and Podcasts"
  public static let mediaSplitPeriod = "Most-listened titles"
  public static let booksLabel = "Books"
  public static let podcastsLabel = "Podcasts"
  public static let otherLabel = "Other"
  /// Titles the device has no catalogued row for cannot be classified, so they sit apart rather
  /// than being guessed into one side of the split.
  public static let otherFootnote =
    "Other is listening to titles this device has not synced, so it cannot tell a book from a podcast."

  public static let historyTitle = "Past Year"
  public static let heatmapLess = "Less"
  public static let heatmapMore = "More"

  public static let weekCompareTitle = "This Week"
  public static let thisWeekLabel = "This week"
  public static let previousWeekLabel = "Week before"

  /// The server dates each session by its start, in the server's time zone.
  public static let dayBoundaryFootnote =
    "Figures come from your Audiobookshelf server. Each session counts toward the day it started."
  /// Shown only while native podcast subscriptions are on.
  public static let nativePodcastsFootnote =
    "Podcasts you follow in Whirr rather than in Audiobookshelf are not included."

  public static func streak(days: Int) -> String {
    switch days {
    case ..<1: "None"
    case 1: "1 day"
    default: "\(days) days"
    }
  }

  static let comparisonFloorSeconds: Double = 60

  /// The last seven days against the seven before, in words so the direction never rests on a sign
  /// or a colour. Nil when the earlier week has under a minute, since any percentage of nearly
  /// nothing is noise.
  public static func weekComparison(current: Double, previous: Double) -> String? {
    guard previous.isFinite, current.isFinite, previous >= comparisonFloorSeconds
    else { return nil }
    let percent = Int(((current - previous) / previous * 100).rounded())
    switch percent {
    case 0: return "Same as the week before"
    case 1...: return "Up \(percent)% on the week before"
    default: return "Down \(-percent)% on the week before"
    }
  }

  /// Today against the 30-day daily rate. Nil under the same minute floor as `weekComparison`:
  /// any percentage of nearly nothing is noise.
  public static func todayAgainstAverage(today: Double, average: Double) -> String? {
    guard average.isFinite, today.isFinite, average >= comparisonFloorSeconds else { return nil }
    let percent = Int((today / average * 100).rounded())
    return "\(percent)% of your daily average"
  }

  public static func daysListened(_ count: Int, of total: Int) -> String {
    "Listened on \(count) of the last \(total) days"
  }

  public static func historyCaption(daysListened: Int) -> String {
    daysListened == 1 ? "Listened on 1 day" : "Listened on \(daysListened) days"
  }

  public static func dailyAverage(seconds: Double) -> String {
    "Avg \(ListeningStatsSummary.durationText(seconds: seconds))"
  }

  public static func dailyAverageAccessibilityLabel(seconds: Double) -> String {
    "Daily average, \(ListeningStatsSummary.durationText(seconds: seconds))"
  }

  /// The Home card is one accessibility element; this is everything it shows, in reading order.
  public static func homeCardAccessibilityLabel(
    _ summary: ListeningStatsSummary, timeSaved: TimeSavedTotals = .zero
  ) -> String {
    let today = ListeningStatsSummary.durationText(seconds: summary.todaySeconds)
    let week = ListeningStatsSummary.durationText(seconds: summary.lastSevenDaysSeconds)
    let streak = summary.streakDays > 0 ? "\(summary.streakDays)-day streak" : "no streak"
    let label = "Listening: \(today) today, \(week) in the last 7 days, \(streak)"
    guard let saved = timeSavedLine(timeSaved) else { return label }
    return "\(label), \(saved)"
  }

  // MARK: - Time saved

  public static let timeSavedTitle = "Time Saved"

  public static func timeSavedSourceLabel(_ source: TimeSavedSource) -> String {
    switch source {
    case .ads: "Ads skipped"
    case .silence: "Silences trimmed"
    case .speed: "Faster playback"
    }
  }

  /// The total as Home and the Stats card show it: each source in whole minutes, then summed.
  /// Durations drop their part minute, so the raw total could read up to two minutes more than
  /// the legend beneath it adds up to.
  public static func timeSavedShownTotal(_ totals: TimeSavedTotals) -> Double {
    TimeSavedSource.allCases.reduce(0) { sum, source in
      let seconds = totals[source]
      return sum + (seconds.isFinite && seconds > 0 ? (seconds / 60).rounded(.down) * 60 : 0)
    }
  }

  /// Home's line under the week strip. Nil under a minute, so a new listener sees no "0 min".
  public static func timeSavedLine(_ totals: TimeSavedTotals) -> String? {
    let shown = timeSavedShownTotal(totals)
    guard shown >= 60 else { return nil }
    return "\(ListeningStatsSummary.durationText(seconds: shown)) saved"
  }

  /// Home's shorter heatmap, titled by what it draws rather than as the Stats screen's year.
  public static func recentWeeksTitle(weeks: Int) -> String { "Last \(weeks) Weeks" }

  public static func recentWeeksAccessibilityLabel(weeks: Int, daysListened: Int) -> String {
    "Last \(weeks) weeks, listened on \(daysListened) \(daysListened == 1 ? "day" : "days")"
  }

  public static func titleName(_ title: ListeningStatsSnapshot.Title) -> String {
    guard let name = title.title?.trimmingCharacters(in: .whitespacesAndNewlines), name.isEmpty == false
    else { return untitledItem }
    return name
  }

  public static func noTitles(podcasts: Bool) -> String {
    podcasts
      ? "No podcasts among your most-listened titles yet."
      : "No books among your most-listened titles yet."
  }

  public static func mediaShareAccessibilityLabel(label: String, seconds: Double, fraction: Double) -> String {
    let duration = ListeningStatsSummary.durationText(seconds: seconds)
    return "\(label), \(duration), \(Int((fraction * 100).rounded())) percent"
  }

  public static func heatmapAccessibilityLabel(daysListened: Int) -> String {
    daysListened == 1 ? "Past year, listened on 1 day" : "Past year, listened on \(daysListened) days"
  }
}
