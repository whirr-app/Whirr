import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The quiet row under item detail's action row. A row, never a capsule: the supplement stays out
/// of the Play/Read pair, and nothing here makes the item readable.
struct ItemDetailSupplementRow: View {
  let supplements: [ItemSupplement]
  let isOffline: Bool
  let onOpen: () -> Void

  var body: some View {
    let trailing = ItemSupplementPresentation.trailing(for: supplements, isOffline: isOffline)
    Button(action: onOpen) {
      HStack(spacing: WhirrSpacing.small) {
        Image(systemName: "doc.richtext")
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
        Text(ItemSupplementPresentation.rowTitle(for: supplements))
          .font(WhirrTypeToken.body.font)
          .foregroundStyle(WhirrMetadataProminence.primary.adaptiveStyle)
          .lineLimit(1)
        Spacer(minLength: WhirrSpacing.small)
        SupplementTrailingView(trailing: trailing)
        Image(systemName: "chevron.right")
          .font(WhirrTypeToken.caption.font.weight(.semibold))
          .foregroundStyle(WhirrMetadataProminence.tertiary.adaptiveStyle)
          .accessibilityHidden(true)
      }
      .frame(minHeight: WhirrMetric.minimumTouchTarget)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .opacity(trailing == .unavailableOffline ? 0.6 : 1)
    .accessibilityHint(
      supplements.count > 1 ? "Shows this book's PDFs." : "Opens this book's companion PDF.")
  }
}
