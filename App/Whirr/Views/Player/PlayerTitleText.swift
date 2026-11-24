import DesignSystem
import SwiftUI

/// The player title: wrapped lines up to the budget, truncated past it. It does not scroll; the
/// budget holds almost every title in full.
struct PlayerTitleText: View {
  let title: String
  let author: String?

  /// Not private: `ListeningMetadataSection` measures a full budget of these lines to hold the
  /// band open at that height, and a probe in a different font would measure the wrong block.
  static let font: Font = .title2.weight(.bold)

  var body: some View {
    Text(title)
      .font(Self.font)
      .lineLimit(PlayerMetric.metadataTitleLineBudget)
      .multilineTextAlignment(.leading)
      .foregroundStyle(.primary)
      .frame(maxWidth: .infinity, alignment: .leading)
      // The element speaks the title and author together.
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        ExpandedPlayerPresentation.metadataAccessibilityLabel(title: title, author: author))
  }
}
