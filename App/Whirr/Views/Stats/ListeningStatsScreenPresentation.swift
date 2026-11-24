import ABSApi
import AppModel
import Foundation
import Persistence
import SwiftUI

/// Pure derivation behind `ListeningStatsView`.
nonisolated enum ListeningStatsScreenPresentation {
  /// The widest the page's cards grow. Past it a two-column figure grid strands its figures at
  /// the card's edges and the charts stretch thin.
  static let pageMeasure = AdaptiveLayoutPresentation.readingMeasure

  /// The row inset that centres the page at `pageMeasure` on regular width. Compact width, a
  /// window narrower than the measure, and an unmeasured width all keep `baseInset`.
  static func pageHorizontalInset(
    availableWidth: CGFloat,
    horizontalSizeClass: UserInterfaceSizeClass?,
    baseInset: CGFloat
  ) -> CGFloat {
    guard horizontalSizeClass == .regular, availableWidth.isFinite, availableWidth > 0 else {
      return baseInset
    }
    return max(baseInset, (availableWidth - pageMeasure) / 2)
  }

  struct TitleRow: Equatable, Identifiable {
    let id: String
    let name: String
    let author: String?
    let duration: String
    /// Set only when the item is in the local catalogue; the row is plain text otherwise, since
    /// item detail cannot resolve a title the device has never synced.
    let item: ItemSummary?
    /// The row's bar: this title's time as a fraction of the most-listened title's, or of the
    /// most-listened title of its own kind when the rows are filtered to one tab.
    let share: Double
    /// What the split calls this title. `other` rows are in no tab.
    let kind: ListeningStatsChartsPresentation.MediaKind
    /// The cover the row's card colours from. An item the device has not catalogued is still a
    /// server item, so its own cover answers at the unversioned revision.
    let washSubject: EditorialWashSubject

    var accessibilityLabel: String {
      [name, author, duration].compactMap { $0 }.joined(separator: ", ")
    }
  }

  static func titleRows(
    _ titles: [ListeningStatsSnapshot.Title],
    catalogued: (String) -> ItemSummary?
  ) -> [TitleRow] {
    titleRows(titles, catalogued: catalogued, kind: nil, limit: nil)
  }

  /// A title with the catalogue row it resolved to, and the side that puts it on.
  private typealias Classified = (
    title: ListeningStatsSnapshot.Title, item: ItemSummary?,
    kind: ListeningStatsChartsPresentation.MediaKind
  )

  /// Rows of one kind, or every row when `kind` is nil. The bar of a filtered row is its share of
  /// that kind's leader, so a books tab is not squeezed by a podcast that has run for years.
  /// `limit` keeps the top rows of the (already largest-first) list.
  static func titleRows(
    _ titles: [ListeningStatsSnapshot.Title],
    catalogued: (String) -> ItemSummary?,
    kind: ListeningStatsChartsPresentation.MediaKind?,
    limit: Int?
  ) -> [TitleRow] {
    let classified: [Classified] = titles.map { title in
      let item = catalogued(title.serverItemId)
      return (title, item, ListeningStatsChartsPresentation.kind(of: item))
    }
    let selected = kind.map { wanted in classified.filter { $0.kind == wanted } } ?? classified
    let leader = selected.map { $0.title.seconds }.max() ?? 0
    let limited = limit.map { Array(selected.prefix(max(0, $0))) } ?? selected
    return limited.map { entry in
      let author = entry.title.author?.trimmingCharacters(in: .whitespacesAndNewlines)
      return TitleRow(
        id: entry.title.serverItemId,
        name: ListeningStatsCopy.titleName(entry.title),
        author: author?.isEmpty == false ? author : nil,
        duration: ListeningStatsSummary.durationText(seconds: entry.title.seconds),
        item: entry.item,
        share: leader > 0 ? min(max(entry.title.seconds / leader, 0), 1) : 0,
        kind: entry.kind,
        washSubject: entry.item?.washSubject
          ?? .audiobookshelf(entry.title.serverItemId, revision: .unversioned))
    }
  }

  /// One day of Home's and the Stats screen's week strip.
  struct WeekDot: Equatable, Identifiable {
    let date: Date
    let initial: String
    /// Whether the day had enough listening to count toward a streak.
    let listened: Bool
    let isToday: Bool
    var id: Date { date }
  }

  static func weekDots(_ summary: ListeningStatsSummary, calendar: Calendar) -> [WeekDot] {
    let today = summary.lastSevenDays.last?.date
    return summary.lastSevenDays.map { day in
      let weekday = calendar.component(.weekday, from: day.date)
      let symbols = calendar.veryShortWeekdaySymbols
      return WeekDot(
        date: day.date,
        initial: symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : "",
        listened: day.seconds >= ListeningStatsSummary.streakThresholdSeconds,
        isToday: day.date == today)
    }
  }

  static func weekStripAccessibilityLabel(_ dots: [WeekDot]) -> String {
    ListeningStatsCopy.daysListened(dots.filter(\.listened).count, of: dots.count)
  }

  /// The weekday the chart picks out: the largest, the earliest on a tie, none for an empty week.
  static func busiestWeekday(_ totals: [ListeningStatsSummary.WeekdayTotal]) -> Int? {
    guard let peak = totals.map(\.seconds).max(), peak > 0 else { return nil }
    return totals.first { $0.seconds == peak }?.weekday
  }

  /// The unit a chart's bars and axis share. The bars' own annotations read in hours and minutes,
  /// so a bare axis of minutes ("2,000") would contradict them.
  enum ChartUnit: Equatable {
    case minutes, hours

    var name: String { self == .minutes ? "Minutes" : "Hours" }

    func value(seconds: Double) -> Double { seconds / (self == .minutes ? 60 : 3_600) }
  }

  static func chartUnit(maxSeconds: Double) -> ChartUnit {
    maxSeconds.isFinite && maxSeconds >= 2 * 3_600 ? .hours : .minutes
  }

  /// Never grouped: the axis is narrow, and "1,500 min" crowds it.
  static func chartAxisLabel(_ value: Double, unit: ChartUnit) -> String {
    guard value != 0 else { return "0" }
    let number = value.formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    return "\(number) \(unit == .minutes ? "min" : "hr")"
  }

  /// Home's card wears the colour of what is being listened to now. The stats themselves carry
  /// only all-time totals per title, which would paint the card one colour for good.
  static func homeCardWashSubject(continueListening: [HomeItem]) -> EditorialWashSubject? {
    continueListening.first?.washSubject
  }

  /// A bar's spoken label: the day, then the time.
  static func dayAccessibilityLabel(
    _ day: ListeningStatsSummary.DailyTotal, calendar: Calendar, locale: Locale = .autoupdatingCurrent
  ) -> String {
    let style = Date.FormatStyle(
      date: .complete, time: .omitted, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    return "\(day.date.formatted(style)), \(ListeningStatsSummary.durationText(seconds: day.seconds))"
  }

  static func weekdayName(_ weekday: Int, calendar: Calendar, short: Bool) -> String {
    let symbols = short ? calendar.shortWeekdaySymbols : calendar.weekdaySymbols
    return symbols.indices.contains(weekday - 1) ? symbols[weekday - 1] : ""
  }

  static func weekdayAccessibilityLabel(
    _ total: ListeningStatsSummary.WeekdayTotal, calendar: Calendar
  ) -> String {
    "\(weekdayName(total.weekday, calendar: calendar, short: false)), \(ListeningStatsSummary.durationText(seconds: total.seconds))"
  }

  /// The native-podcasts note appears only while that feature can have added listening.
  static func footnotes(nativePodcastsEnabled: Bool) -> [String] {
    var notes = [ListeningStatsCopy.dayBoundaryFootnote]
    if nativePodcastsEnabled { notes.append(ListeningStatsCopy.nativePodcastsFootnote) }
    return notes
  }
}
