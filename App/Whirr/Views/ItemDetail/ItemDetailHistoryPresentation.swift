import Foundation
import SyncEngine

/// History-list row presentation for the item-detail screen's History tab: one row per past
/// `ListeningHistoryEntry`, in the order `ItemHistoryModel` provides them (newest session first).
/// Never re-sorts.
struct ItemDetailHistoryRow: Identifiable, Equatable {
  let id: String
  let dateLabel: String
  let rangeLabel: String
  let listenedLabel: String
  let startPosition: Double
}

enum ItemDetailHistoryPresentation {
  static func rows(
    entries: [ListeningHistoryEntry], now: Date = Date(), calendar: Calendar = .current
  ) -> [ItemDetailHistoryRow] {
    entries.map { entry in
      ItemDetailHistoryRow(
        id: entry.sessionId,
        dateLabel: dateLabel(for: entry.startedAt, now: now, calendar: calendar),
        rangeLabel:
          "Started at \(PlayerTimeFormatting.clock(entry.startPosition)) "
          + "→ ended \(PlayerTimeFormatting.clock(entry.endPosition))",
        listenedLabel: "\(ChapterSelectorPresentation.duration(entry.listenedSeconds)) listened",
        startPosition: entry.startPosition
      )
    }
  }

  /// "Today, 3:45 PM" / "Yesterday, 9:12 AM" / "Jul 20, 2026, 3:45 PM". `now` and `calendar` are
  /// injectable so the day-boundary branching can be tested without the real wall clock.
  static func dateLabel(for date: Date, now: Date, calendar: Calendar) -> String {
    let time = timeFormatter.string(from: date)
    if calendar.isDate(date, inSameDayAs: now) {
      return "Today, \(time)"
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday)
    {
      return "Yesterday, \(time)"
    }
    return "\(dateFormatter.string(from: date)), \(time)"
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()
}
