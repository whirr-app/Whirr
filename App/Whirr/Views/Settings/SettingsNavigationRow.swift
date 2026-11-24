import DesignSystem
import SwiftUI

/// The label a Settings row that pushes a destination wears: an icon, the destination's name, a
/// one-line explanation of what is behind it, and an optional attention badge.
///
/// Shared because a destination can carry destinations of its own (`DownloadSettingsView` pushes
/// the downloaded-items list and the Resolution Center), and those rows must match this one.
struct SettingsNavigationRow: View {
  let title: String
  let detail: String
  let systemImage: String
  var badgeCount: Int = 0
  var trailingValue: String?
  /// Holds the trailing slot open at its eventual width while an asynchronous `trailingValue` is
  /// still being read. Otherwise the value appears into a zero-width slot and re-truncates the
  /// detail line beside it, flickering the row.
  var trailingValuePlaceholder: String?

  var body: some View {
    HStack(spacing: WhirrSpacing.small) {
      Image(systemName: systemImage)
        .font(.body.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body)
        Text(detail)
          .font(.caption)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .lineLimit(1)
      }

      Spacer()

      if let slotValue = trailingValue ?? trailingValuePlaceholder {
        Text(slotValue)
          .font(.body)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .monospacedDigit()
          .opacity(trailingValue == nil ? 0 : 1)
          .accessibilityHidden(trailingValue == nil)
      }

      if badgeCount > 0 {
        Text("\(badgeCount)")
          .font(.caption.weight(.bold))
          .foregroundStyle(.white)
          .padding(.horizontal, WhirrSpacing.xSmall)
          .padding(.vertical, 2)
          .background(.red, in: Capsule())
          .accessibilityLabel("\(badgeCount) items need attention")
      }
    }
    .frame(minHeight: 56)
    .accessibilityElement(children: .combine)
  }
}
