import AppModel
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI
import SyncEngine

/// The item-detail chapters sheet's chapter list: the player's `ChapterSelectorList`, fed from the
/// item's extras rather than a loaded player item. Its own `View` because it resolves the playhead
/// for the current-chapter highlight, which changes on nearly every playback tick, so the read must
/// live in a small subview rather than the whole page's body (see `ExpandedPlayerView`).
struct ItemDetailChaptersSection: View {
  let itemID: String
  let extrasModel: ItemDetailExtrasModel?
  let playback: PlaybackModel
  /// The item's own finished flag, which completes every chapter without needing a playback
  /// position. "Mark as Finished" writes it and the server syncs it.
  let isFinished: Bool
  /// The item's saved audio position, for when the book is neither loaded nor the retained one.
  let persistedPositionSeconds: Double
  /// Queues one chapter in Up Next; nil where this title's chapters cannot be queued.
  var onQueueChapter: ((ChapterQueueAction, ListeningQueueChapter) -> Void)?
  /// Select mode, owned by the sheet's toolbar.
  var selection: Binding<ChapterSelection?> = .constant(nil)
  /// Appends Select mode's chapters in the order chosen.
  var onQueueChapters: (([ListeningQueueChapter]) -> Void)?
  let onSelectChapter: (PlaybackChapter) -> Void

  var body: some View {
    switch extrasModel?.state {
    case nil, .some(.unavailable):
      EmptyStateView(
        title: "Chapters Unavailable",
        message: "Chapter information isn't available for this title right now.",
        systemImage: "list.bullet"
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .some(.loading):
      LoadingStateView(message: "Loading chapters…")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .some(.loaded(let extras)):
      ChapterSelectorList(
        chapters: extras.chapters.map {
          PlaybackChapter(title: $0.title, start: $0.start, end: $0.end)
        },
        // The position the player prints, loaded or not: a cold launch shows the restored book
        // without loading it, and its chapters are still where the listener left them.
        currentTime: playback.displayedPositionSeconds(
          itemID: itemID, episodeID: nil, persisted: persistedPositionSeconds),
        isFinished: isFinished,
        onQueueAction: onQueueChapter.map { onQueueChapter in
          { row, action in
            guard
              let chapter = ChapterQueueAction.queueChapter(
                at: row.id, displayTitle: row.title, in: extras.chapters)
            else { return }
            onQueueChapter(action, chapter)
          }
        },
        selection: selection,
        onQueueSelection: onQueueChapters.map { onQueueChapters in
          { rows in
            onQueueChapters(
              rows.compactMap {
                ChapterQueueAction.queueChapter(at: $0.id, displayTitle: $0.title, in: extras.chapters)
              })
          }
        },
        onSelect: onSelectChapter
      )
    }
  }
}
