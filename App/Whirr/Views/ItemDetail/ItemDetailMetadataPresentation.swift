import AppModel
import DesignSystem
import Foundation
import Persistence

nonisolated struct ItemDetailMetadataRow: Equatable {
  let text: String?
  let reservesLayout: Bool
}

struct ItemDetailMetadataLayout: Sendable, Equatable {
  let reservesSeriesRow: Bool
  let reservesNarratorRow: Bool

  /// A podcast never reaches the book hero, and reserves nothing if a defensive path puts one
  /// there. Both book categories keep a series breadcrumb from the ordinary item summary, even
  /// before expanded metadata arrives.
  nonisolated init(item: ItemSummary) {
    guard item.category != .podcast else {
      reservesSeriesRow = false
      reservesNarratorRow = false
      return
    }
    reservesSeriesRow = ItemDetailMetadataPresentation.trimmed(item.seriesName) != nil
    // Only the category is latched. A narrator is expanded-only, so unlike the series breadcrumb
    // this row cannot decide at first frame whether it has a value; `narratorRow` decides live.
    // Latching on would leave a narrator-less book with a permanent placeholder; latching off
    // would never show a narrator that arrives.
    reservesNarratorRow = item.category == .audiobook
  }
}

enum ItemDetailMetadataPresentation {
  static func seriesRow(
    item: ItemSummary,
    layout: ItemDetailMetadataLayout
  ) -> ItemDetailMetadataRow {
    ItemDetailMetadataRow(
      text: layout.reservesSeriesRow ? trimmed(item.seriesName) : nil,
      reservesLayout: layout.reservesSeriesRow)
  }

  static func narratorRow(
    item: ItemSummary,
    layout: ItemDetailMetadataLayout
  ) -> ItemDetailMetadataRow {
    let text = trimmed(item.narratorName)
    return ItemDetailMetadataRow(
      text: text,
      reservesLayout: layout.reservesNarratorRow
        && (text != nil || item.expandedMetadataFetchedAt == nil))
  }

  fileprivate nonisolated static func trimmed(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      trimmed.isEmpty == false
    else {
      return nil
    }
    return trimmed
  }
}

/// What the hero's text may run to before it clips. Every cap is a last resort: where a cap would
/// bite routinely, there is none.
enum ItemDetailHeroTextPresentation {
  /// The title's budget. Both hero shapes set the title at the full content measure, so the cap
  /// is a plain line count.
  static let fullMeasureLineLimit = 2

  /// Nil at accessibility sizes. There a cap would truncate as a matter of course: the title
  /// alone runs to four or five lines, and the page is already scrolling.
  static func titleLineLimit(isAccessibilitySize: Bool) -> Int? {
    isAccessibilitySize ? nil : fullMeasureLineLimit
  }

  /// What one credit name may run to. The flow layout wraps between names, never within one, so a
  /// single line would clip a long series ("Scarlet City: An Audible Original Series"). Two lines,
  /// not uncapped, so a wrapped name still reads as one object. At accessibility sizes the cap
  /// comes off, as for the title (two lines is most names there).
  static func creditNameLineLimit(isAccessibilitySize: Bool) -> Int? {
    isAccessibilitySize ? nil : 2
  }
}
