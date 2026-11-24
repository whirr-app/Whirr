import AppModel
import DesignSystem
import SwiftUI

/// The finished badge for one browse row (finished-state-display), rendered into `ItemListRow`'s
/// trailing slot beside the offline badge. Compact glyph style so it takes no title width; the
/// full accessibility label stays on the glyph. Reads the shared finished projection
/// synchronously, as `OfflineBadgeRow` does: nothing to tear down on a recycled row.
struct FinishedBadgeRow: View {
  let itemID: String
  let finishedStatus: FinishedStatusStore

  var body: some View {
    if finishedStatus.isFinished(itemID) {
      FinishedRowBadge(itemID: itemID, isCompact: true)
    }
  }
}

/// The mutually exclusive playback marker used by Library title rows. The finished checkmark and
/// podcast half-filled in-progress circle share the same compact slot, so changing state changes
/// the glyph without changing row geometry.
struct LibraryPlaybackStatusBadge: View {
  let itemID: String
  let status: LibraryBrowsePresentation.RowPlaybackStatus

  var body: some View {
    OfflineBadgeView(label: status.label, systemImage: status.systemImage, style: .row)
      .accessibilityIdentifier(accessibilityIdentifier)
  }

  private var accessibilityIdentifier: String {
    switch status {
    case .inProgress: InProgressAccessibilityID.rowBadgePrefix + itemID
    case .finished: FinishedAccessibilityID.rowBadgePrefix + itemID
    }
  }
}

/// The badge itself, for rows whose own projection already carries the finished flag (the Home
/// more-screens read `HomeItem.isFinished`) and so need no store lookup to decide.
struct FinishedRowBadge: View {
  let itemID: String
  var isCompact: Bool = false

  var body: some View {
    OfflineBadgeView(
      label: ItemFinishedCopy.badgeLabel, systemImage: ItemFinishedCopy.badgeSystemImage,
      style: isCompact ? .row : .detail
    )
    .accessibilityIdentifier(FinishedAccessibilityID.rowBadgePrefix + itemID)
  }
}

/// The one place the finished-state copy lives (finished-state-display), shared by this row badge
/// and item detail's hero checkmark so the two surfaces cannot drift.
nonisolated enum ItemFinishedCopy {
  static let badgeLabel = "Finished"
  static let badgeSystemImage = "checkmark.circle.fill"
}

nonisolated enum ItemProgressCopy {
  static let badgeLabel = "In progress"
}

/// Accessibility identifiers for the finished-state surfaces, kept beside the other screens' own
/// id enums (`ScreenAccessibilityID`, `HomeAccessibilityID`) rather than spelled inline.
enum FinishedAccessibilityID {
  static let rowBadgePrefix = "finished.row.badge."
}

enum InProgressAccessibilityID {
  static let rowBadgePrefix = "inProgress.row.badge."
}
