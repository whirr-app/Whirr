import AppModel
import DesignSystem
import SwiftUI
import SyncEngine

/// The listening-history sheet: `ItemDetailHistorySection` inside a titled, closable navigation
/// stack, shared by the detail page's overflow menu and the expanded player so the two cannot
/// drift. Caller-specific chrome (detents, themed tinting, accessibility identity) and refresh
/// policy stay with the caller.
struct ItemDetailHistorySheet: View {
  let historyModel: ItemHistoryModel?
  let onSelectEntry: (ListeningHistoryEntry) -> Void
  let onClose: () -> Void

  var body: some View {
    NavigationStack {
      ScrollView {
        ItemDetailHistorySection(
          historyModel: historyModel,
          onSelectEntry: onSelectEntry
        )
        .padding(.horizontal, WhirrSpacing.medium)
        .padding(.top, WhirrSpacing.small)
      }
      .navigationTitle(MediaActionCopy.listeningHistory.title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(role: .close) {
            onClose()
          }
        }
      }
    }
  }
}
