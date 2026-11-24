import ABSApi
import AppModel
import Persistence
import SwiftUI

/// Shared interaction wiring for a Library title, regardless of whether its label is a compact
/// `ItemListRow` or a regular-width cover tile. The label remains owned by each layout because its
/// artwork and metadata geometry differ; the menu and spoken label do not.
struct LibraryBrowseTitleInteractionModifier: ViewModifier {
  let item: ItemSummary
  let coverClient: any ArtworkServing
  let finishedStatus: FinishedStatusStore
  let playback: PlaybackModel
  let actions: ItemActionsModel
  let onSelect: (ItemSummary) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onSearch: (String) -> Void

  func body(content: Content) -> some View {
    harnessTimedSpan("Tile.interactions") { interactions(content: content) }
  }

  private func interactions(content: Content) -> some View {
    content
      .itemContextMenu(
        ItemMenuSubject(
          summary: item,
          playbackStatus: { finishedStatus.playbackStatus(item.serverItemId) },
          coverClient: coverClient,
          source: nil,
          revision: item.artworkRevision,
          playback: playback,
          actions: actions),
        placement: .libraryBrowseRow,
        onOpen: { onSelect(item) },
        onRead: { onPresentReader(item.serverItemId, item.title, item.category) },
        onSearch: onSearch
      )
      .ablatable(HarnessSwitch.skipsTileAccessibility) {
        $0.accessibilityLabel(
          Text(
            LibraryBrowsePresentation.rowAccessibilityLabel(
              item: item, playbackStatus: finishedStatus.playbackStatus(item.serverItemId)
            )
          )
        )
      }
  }
}

extension View {
  /// Keeps the Library title menu's complete action contract in one App-layer call site. Download
  /// status remains in the caller's label (`OfflineBadgeRow`), so the compact and regular labels
  /// can choose their own metadata geometry without changing the shared context menu.
  func libraryBrowseTitleInteractions(
    item: ItemSummary,
    coverClient: any ArtworkServing,
    finishedStatus: FinishedStatusStore,
    playback: PlaybackModel,
    actions: ItemActionsModel,
    onSelect: @escaping (ItemSummary) -> Void,
    onPresentReader: @escaping (String, String, ItemMediaCategory) -> Void,
    onSearch: @escaping (String) -> Void
  ) -> some View {
    modifier(
      LibraryBrowseTitleInteractionModifier(
        item: item,
        coverClient: coverClient,
        finishedStatus: finishedStatus,
        playback: playback,
        actions: actions,
        onSelect: onSelect,
        onPresentReader: onPresentReader,
        onSearch: onSearch
      )
    )
  }
}
