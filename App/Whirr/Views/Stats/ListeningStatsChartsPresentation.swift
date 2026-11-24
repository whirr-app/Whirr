import AppModel
import Foundation
import Persistence

/// Pure derivation behind the Stats screen's media split, heatmap and ring. Kept apart from
/// `ListeningStatsScreenPresentation`, which owns the screen's rows and labels, so neither type
/// has to hold the other's fixtures.
nonisolated enum ListeningStatsChartsPresentation {
  /// What a title is, as far as the split can tell. A title the device has never catalogued has
  /// no category, so it is `other` rather than being guessed into one side.
  enum MediaKind: String, CaseIterable, Hashable, Sendable {
    case books
    case podcasts
    case other
  }

  static func kind(of item: ItemSummary?) -> MediaKind {
    guard let item else { return .other }
    switch item.category {
    case .podcast: return .podcasts
    case .audiobook, .ebook: return .books
    }
  }

  /// One side of the split: its listening and its share of the titles' total.
  struct MediaShare: Equatable, Identifiable, Sendable {
    let kind: MediaKind
    let seconds: Double
    let fraction: Double

    var id: MediaKind { kind }
  }

  /// Every title summed into books, podcasts and other, in that order. Kinds with no listening
  /// are left out, so a legend never shows an empty row; a library with nothing recorded is an
  /// empty split rather than three zero rows.
  static func mediaSplit(
    _ titles: [ListeningStatsSnapshot.Title],
    catalogued: (String) -> ItemSummary?
  ) -> [MediaShare] {
    var secondsByKind: [MediaKind: Double] = [:]
    for title in titles {
      secondsByKind[kind(of: catalogued(title.serverItemId)), default: 0] += title.seconds
    }
    let total = secondsByKind.values.reduce(0, +)
    guard total > 0, total.isFinite else { return [] }
    return MediaKind.allCases.compactMap { kind in
      guard let seconds = secondsByKind[kind], seconds > 0 else { return nil }
      return MediaShare(kind: kind, seconds: seconds, fraction: seconds / total)
    }
  }

  static func label(for kind: MediaKind) -> String {
    switch kind {
    case .books: ListeningStatsCopy.booksLabel
    case .podcasts: ListeningStatsCopy.podcastsLabel
    case .other: ListeningStatsCopy.otherLabel
    }
  }

  // MARK: - Heatmap

  /// One day in the year grid. `level` is 1...4 for a day that cleared the streak threshold and 0
  /// otherwise; a day before the record began is flagged apart from a day with no listening.
  struct HeatCell: Equatable, Identifiable, Sendable {
    let date: Date
    let seconds: Double
    let level: Int
    let isBeforeHistory: Bool

    var id: Date { date }
  }

  /// Columns of weeks, oldest first, each with seven slots in `calendar.firstWeekday` order. The
  /// last column holds today; the slots after today are nil. Levels rank the window's listened
  /// days against each other rather than against an absolute scale, so a quiet year still shades
  /// as a gradient instead of one faint block.
  static func heatmapWeeks(
    _ summary: ListeningStatsSummary, weeks: Int, calendar: Calendar
  ) -> [[HeatCell?]] {
    guard weeks > 0, summary.history.isEmpty == false, let today = summary.history.last?.date
    else { return [] }
    // History holds whole days, so the grid cannot reach past its first one.
    let historyDays = summary.history.count
    let todayIndex = weekdayIndex(of: today, calendar: calendar)
    let availableWeeks = (historyDays - 1 - todayIndex) / 7 + 1
    let weekCount = min(weeks, max(0, availableWeeks))
    guard weekCount > 0,
      let start = calendar.date(byAdding: .day, value: -((weekCount - 1) * 7 + todayIndex), to: today)
    else { return [] }

    let secondsByDate = Dictionary(
      summary.history.map { ($0.date, $0.seconds) }, uniquingKeysWith: { first, _ in first })

    let cells: [[HeatCell?]] = (0..<weekCount).map { column in
      (0..<7).map { slot -> HeatCell? in
        guard
          let date = calendar.date(byAdding: .day, value: column * 7 + slot, to: start),
          date <= today
        else { return nil }
        let isBeforeHistory = summary.historyStart.map { date < $0 } ?? true
        return HeatCell(
          date: date, seconds: secondsByDate[date] ?? 0, level: 0,
          isBeforeHistory: isBeforeHistory)
      }
    }

    // Levels rank the days this grid shows, not the whole record: a sixteen-week slice has to
    // spread across the same four shades as a year, or it would sit in one.
    let listenedSeconds = cells.flatMap { $0 }.compactMap { $0 }
      .filter { $0.isBeforeHistory == false && $0.seconds >= ListeningStatsSummary.streakThresholdSeconds }
      .map(\.seconds)
      .sorted()
    let ranks = listenedRankBySeconds(listenedSeconds)

    return cells.map { column in
      column.map { cell -> HeatCell? in
        guard let cell else { return nil }
        let level = heatLevel(
          seconds: cell.seconds, listenedSeconds: listenedSeconds, ranks: ranks,
          isBeforeHistory: cell.isBeforeHistory)
        return HeatCell(
          date: cell.date, seconds: cell.seconds, level: level,
          isBeforeHistory: cell.isBeforeHistory)
      }
    }
  }

  /// The columns where each month first appears, each with its short month symbol. A label that
  /// would sit within two columns of the previous one is dropped: at a 12pt cell two adjacent
  /// labels collide, and the month they would name is on screen anyway.
  static func monthLabels(
    for weeks: [[HeatCell?]], calendar: Calendar
  ) -> [(column: Int, label: String)] {
    var labels: [(column: Int, label: String)] = []
    var lastMonth: Int?
    var lastColumn = -1_000
    let symbols = calendar.shortMonthSymbols
    for (column, week) in weeks.enumerated() {
      guard let first = week.compactMap({ $0 }).first else { continue }
      let month = calendar.component(.month, from: first.date)
      guard month != lastMonth else { continue }
      lastMonth = month
      guard column - lastColumn >= 2, symbols.indices.contains(month - 1) else { continue }
      labels.append((column: column, label: symbols[month - 1]))
      lastColumn = column
    }
    return labels
  }

  /// Today against the 30-day daily rate, as a ring's fill. Zero under the copy's minute floor:
  /// nearly nothing is not a rate worth filling a ring for.
  static func todayProgress(_ summary: ListeningStatsSummary) -> Double {
    let average = summary.lastThirtyDaysAverageSeconds
    guard average.isFinite, average >= 60, summary.todaySeconds.isFinite else { return 0 }
    return min(max(summary.todaySeconds / average, 0), 1)
  }

  /// A day's slot within its week, where the calendar's first weekday is slot 0.
  static func weekdayIndex(of date: Date, calendar: Calendar) -> Int {
    let weekday = calendar.component(.weekday, from: date)
    return (weekday - calendar.firstWeekday + 7) % 7
  }

  // MARK: - Private

  /// Each listened day's rank among the listened days, 1 for the quietest. Equal values share the
  /// highest rank, so two identical days can never shade differently.
  private static func listenedRankBySeconds(_ sortedSeconds: [Double]) -> [Double: Int] {
    var ranks: [Double: Int] = [:]
    for (index, seconds) in sortedSeconds.enumerated() { ranks[seconds] = index + 1 }
    return ranks
  }

  private static func heatLevel(
    seconds: Double, listenedSeconds: [Double], ranks: [Double: Int], isBeforeHistory: Bool
  ) -> Int {
    guard isBeforeHistory == false,
      seconds >= ListeningStatsSummary.streakThresholdSeconds,
      let rank = ranks[seconds]
    else { return 0 }
    // One listened day is the whole scale, and the lightest shade would read as nothing at all.
    guard listenedSeconds.count > 1 else { return 4 }
    let count = listenedSeconds.count
    return min(4, (rank * 4 + count - 1) / count)
  }
}
