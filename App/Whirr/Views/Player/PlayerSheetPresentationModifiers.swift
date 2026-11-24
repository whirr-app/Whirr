import DesignSystem
import SwiftUI

/// Player-specific dressing around the shared sheet policy. Tint and the cover accent belong to
/// the player, while size-class behaviour remains in `AdaptiveSheetPresentationModifier` so the
/// player cannot grow a second sheet policy.
extension View {
  /// The requested role selects compact detents versus regular fitted sizing. `detents` is the
  /// compact set only; regular width never receives a fixed detent, even for a measured height.
  /// `contentInteraction` also applies at compact width only.
  func themedSheet(
    accent: Color,
    role: SheetViewPresentation.Role,
    detents: Set<PresentationDetent> = [.medium, .large],
    contentInteraction: PresentationContentInteraction = .automatic
  ) -> some View {
    adaptiveSheetPresentation(
      role: role, compactDetents: detents, contentInteraction: contentInteraction
    )
    .tint(accent)
    .environment(\.coverAccent, accent)
  }

  /// Compact width keeps the queue's own detents and initial-medium selection. Regular width uses a
  /// fitted form with no resizable detent or drag indicator.
  func queueDetents(
    accent: Color,
    selection: Binding<PresentationDetent>
  ) -> some View {
    modifier(
      PlayerQueueSheetPresentationModifier(
        accent: accent, selection: selection))
  }
}

private struct PlayerQueueSheetPresentationModifier: ViewModifier {
  let accent: Color
  let selection: Binding<PresentationDetent>

  /// The window's, not the sheet's (see `EnvironmentValues.windowHorizontalSizeClass`).
  @Environment(\.windowHorizontalSizeClass) private var windowHorizontalSizeClass

  @ViewBuilder
  func body(content: Content) -> some View {
    switch ListeningQueuePresentation.style(horizontalSizeClass: windowHorizontalSizeClass) {
    // As in `AdaptiveSheetPresentationModifier`'s default: `.automatic` interaction. The queue
    // is a scrolling list across `.medium` and `.large`, so `.scrolls` would make the grabber the
    // only way to expand it.
    case .sheet:
      content
        .presentationDetents(
          Set(ListeningQueuePresentation.detents(for: .sheet)), selection: selection
        )
        .presentationDragIndicator(.visible)
        .tint(accent)
        .environment(\.coverAccent, accent)
    case .formSheet:
      content
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .presentationDragIndicator(.hidden)
        .tint(accent)
        .environment(\.coverAccent, accent)
    }
  }
}
