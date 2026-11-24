import SwiftUI

/// The shell-level host for item detail's regular-width card (ADR 0008). The caller supplies the
/// fully composed detail view; this wrapper owns only the sizing and dismissal contract.
///
/// Does not read `horizontalSizeClass`: a `.form` sheet is about 570 pt wide, which SwiftUI
/// resolves as compact even on a full-screen iPad, giving the compact detent stack with no Close
/// control. The shell reads the window's class and presents this only at regular width (same trap
/// as ADR 0008 records for item detail).
struct ItemDetailCardSheet<Content: View>: View {
  @ViewBuilder let content: () -> Content

  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      content()
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) { dismiss() }
          }
        }
    }
    .presentationSizing(.form)
    // A card at `.form` sizing has no detents to drag between, so the indicator would advertise a
    // gesture that does nothing; the close button is the affordance. It uses the label-less
    // `Button(role:)` initializer because a title becomes the label and shows "Close" instead of
    // the platform's X.
    .presentationDragIndicator(.hidden)
  }
}
