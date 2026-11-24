#if PERF_INVESTIGATION
  import AppModel
  import DesignSystem
  import SwiftUI
  import ABSApi
  import Persistence

  /// A fixed tile with the same resolved width for isolating Home shelf layout from card internals. It retains the
  /// resolved width and an approximate fixed cover-plus-metadata height, but does no artwork, text, badge,
  /// progress, wash, or context-menu work. The button and identifier keep the card's tap
  /// routing intact.
  struct StaticHomeShelfCard: View {
    let layout: HomeViewPresentation.ShelfLayout
    let accessibilityIdentifier: String
    let accessibilityLabel: String
    let onSelect: () -> Void

    var body: some View {
      Button(action: onSelect) {
        RoundedRectangle(cornerRadius: WhirrSpacing.xSmall, style: .continuous)
          .fill(Color.gray.opacity(0.25))
          .frame(width: layout.cardWidth, height: layout.drawnCoverWidth + 96)
      }
      .buttonStyle(.plain)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityIdentifier(accessibilityIdentifier)
    }
  }
#endif
