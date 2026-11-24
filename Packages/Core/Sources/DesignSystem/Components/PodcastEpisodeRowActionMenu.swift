import SwiftUI

/// The episode row's ellipsis menu, held outside the row's own redraw scope.
///
/// The row can print the live playhead (the show page does, for the playing episode), so its body
/// re-runs about twice a second, and rebuilding a presented `Menu`'s source visibly pulses its
/// glass. The menu is compared on its sections (unchanged by a position tick) with `.equatable()`;
/// the closure is excluded because it is re-created on every pass.
struct PodcastEpisodeRowActionMenu: View, Equatable {
  let sections: [[MediaContextAction]]
  let accessibilityLabel: String
  let accessibilityHint: String
  let minimumWidth: CGFloat
  let minimumHeight: CGFloat
  let onSelectAction: (MediaContextAction) -> Void

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.sections == rhs.sections && lhs.accessibilityLabel == rhs.accessibilityLabel
      && lhs.accessibilityHint == rhs.accessibilityHint && lhs.minimumWidth == rhs.minimumWidth
      && lhs.minimumHeight == rhs.minimumHeight
  }

  var body: some View {
    Menu {
      MediaActionMenuItems(sections: sections, onSelectAction: onSelectAction)
    } label: {
      Image(systemName: "ellipsis")
        .frame(minWidth: minimumWidth, minHeight: minimumHeight)
    }
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(accessibilityHint)
  }
}
