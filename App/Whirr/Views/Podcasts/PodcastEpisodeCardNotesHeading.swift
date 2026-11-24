import SwiftUI

/// The episode card's "Show notes" heading row, with the ad-skip status in its trailing half.
///
/// The row is laid out on every loaded card, so the status has a slot that never appears or
/// disappears. A card without notes keeps the label's space and hides the label. The row is one
/// line of the label's font whatever `status` draws: `AdSkipCardStatusText` adds no height.
struct PodcastEpisodeCardNotesHeading<Status: View>: View {
  let showsLabel: Bool
  /// The card's ink, which depends on whether it sits on glass.
  let secondaryInk: AnyShapeStyle
  @ViewBuilder let status: Status

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text("Show notes")
        .font(.footnote.weight(.semibold))
        .foregroundStyle(secondaryInk)
        .lineLimit(1)
        .fixedSize()
        .opacity(showsLabel ? 1 : 0)
        .accessibilityHidden(showsLabel == false)
        .accessibilityAddTraits(.isHeader)
      status
    }
  }
}
