import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The publication details that remain after the header and description have carried their own
/// content. Every row comes from the synced item summary, so extras loading does not affect it.
struct ItemDetailDetailsSection: View {
  let item: ItemSummary

  var body: some View {
    let rows = ItemDetailAboutPresentation.rows(
      for: item,
      formattedDuration: formattedDuration,
      formattedAudioDownloadSize: formattedByteCount(item.audioDownloadExpectedBytes),
      formattedEbookDownloadSize: formattedByteCount(item.ebookDownloadExpectedBytes))

    if rows.isEmpty == false {
      VStack(alignment: .leading, spacing: WhirrSpacing.small) {
        BrowseSectionHeaderView(title: "Details")

        VStack(spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            detailRow(row)
            if index != rows.count - 1 {
              Divider()
            }
          }
        }
        .accessibilityIdentifier(ItemDetailDetailsAccessibilityID.detailList)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var formattedDuration: String? {
    guard let durationSeconds = item.durationSeconds,
      ItemDetailDurationPresentation.showsDuration(
        category: item.category, durationSeconds: durationSeconds)
    else {
      return nil
    }
    return ItemDetailViewPresentation.formattedDuration(durationSeconds)
  }

  private func formattedByteCount(_ bytes: Int64?) -> String? {
    guard let bytes, bytes > 0 else { return nil }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  private func detailRow(_ row: ItemDetailAboutRow) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: WhirrSpacing.medium) {
      Text(row.label)
        .font(.subheadline)
        // On the ladder, not `textSecondary`: this section sits on the ambient page, and a fixed
        // grey measured 1.9:1 against a mid-tone cover there.
        .foregroundStyle(WhirrMetadataProminence.tertiary.adaptiveStyle)
      Spacer(minLength: WhirrSpacing.small)
      Text(row.value)
        .font(.subheadline)
        .multilineTextAlignment(.trailing)
    }
    .padding(.vertical, WhirrSpacing.xSmall)
    .accessibilityElement(children: .combine)
  }
}

enum ItemDetailDetailsAccessibilityID {
  static let description = "item-detail-details-description"
  static let detailList = "item-detail-details-list"
}
