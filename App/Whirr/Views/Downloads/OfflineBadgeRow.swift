import AppModel
import DesignSystem
import SwiftUI

/// The downloaded/offline badge for one browse/search row, rendered into `ItemListRow`'s
/// `progress` slot. Renders nothing unless the shared download projection reports a completed
/// download. No `@State` or init side effect: SwiftUI builds throwaway `View` values constantly.
struct OfflineBadgeRow: View {
  let itemID: String
  let downloadStatus: DownloadStatusStore
  var isCompact: Bool = false

  var body: some View {
    if downloadStatus.isDownloaded(itemID) {
      OfflineBadgeView(
        label: ItemDownloadCopy.completed, systemImage: "arrow.down.circle.fill",
        style: isCompact ? .row : .detail
      )
      .accessibilityIdentifier(ScreenAccessibilityID.libraryRowOfflineBadgePrefix + itemID)
    }
  }
}
