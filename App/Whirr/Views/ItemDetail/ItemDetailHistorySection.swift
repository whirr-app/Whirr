import AppModel
import DesignSystem
import SwiftUI
import SyncEngine

/// The item-detail screen's History tab: one row per past listening session, newest first
/// (`ItemHistoryModel`'s ordering, never re-sorted here). Tapping a row resumes playback from
/// that session's start position via `onSelectEntry`.
struct ItemDetailHistorySection: View {
  let historyModel: ItemHistoryModel?
  let onSelectEntry: (ListeningHistoryEntry) -> Void

  var body: some View {
    if let historyModel {
      if historyModel.entries.isEmpty {
        EmptyStateView(
          title: "No Listening History",
          message: "Past listening sessions for this title will appear here.",
          systemImage: "clock.arrow.circlepath"
        )
      } else {
        historyList(historyModel.entries, isStale: historyModel.isStale)
      }
    } else {
      EmptyStateView(
        title: "History Unavailable",
        message: "Listening history isn't available for this title right now.",
        systemImage: "clock.arrow.circlepath"
      )
    }
  }

  private func historyList(_ entries: [ListeningHistoryEntry], isStale: Bool) -> some View {
    let rows = ItemDetailHistoryPresentation.rows(entries: entries)

    return VStack(alignment: .leading, spacing: 0) {
      LazyVStack(spacing: 0) {
        ForEach(Array(zip(entries, rows)), id: \.1.id) { entry, row in
          historyRow(row, entry: entry)
          if row.id != rows.last?.id {
            Divider()
          }
        }
      }

      if isStale {
        Text("This list may be out of date.")
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .padding(.top, WhirrSpacing.small)
      }
    }
    .accessibilityIdentifier(ScreenAccessibilityID.itemDetailHistoryList)
  }

  private func historyRow(_ row: ItemDetailHistoryRow, entry: ListeningHistoryEntry) -> some View {
    Button {
      onSelectEntry(entry)
    } label: {
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        Text(row.dateLabel)
          .font(.body)
        Text(row.rangeLabel)
          .font(.caption)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
        Text(row.listenedLabel)
          .font(.caption)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
      }
      // The three lines clear the touch-target floor on their own, so without padding consecutive
      // rows would meet at their dividers.
      .padding(.vertical, WhirrSpacing.small)
      .frame(maxWidth: .infinity, minHeight: WhirrMetric.minimumTouchTarget, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("\(ScreenAccessibilityID.itemDetailHistoryRowPrefix)\(row.id)")
    .accessibilityElement(children: .combine)
    .accessibilityHint("Resumes playback from where this session started.")
  }
}
