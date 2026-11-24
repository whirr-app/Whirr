import AppModel
import Persistence
import PlayerCore
import SyncEngine

/// The Up Next entries on an audiobook chapter's context menu.
nonisolated enum ChapterQueueAction: String, CaseIterable, Identifiable {
  case playNext
  case addToUpNext

  var id: String { rawValue }

  var label: String {
    switch self {
    case .playNext: MediaActionCopy.playNext.title
    case .addToUpNext: MediaActionCopy.addToUpNext.title
    }
  }

  var systemImage: String {
    switch self {
    case .playNext: MediaActionCopy.playNext.systemImage
    case .addToUpNext: MediaActionCopy.addToUpNext.systemImage
    }
  }

  /// Only a book's chapters can be queued: a podcast episode queues whole, and an ebook has no
  /// audio chapters.
  static func isOffered(for capability: ItemMediaCapability) -> Bool {
    switch capability {
    case .audio, .audioAndEbook: true
    case .podcast, .ebook, .unsupportedDocument: false
    }
  }

  /// The queued chapter for row `index` of the item's own chapter list. Taken from the item's
  /// extras, not the display row, and named as the list names it so an untitled chapter keeps its
  /// number in Up Next. Nil when the list changed under the menu.
  static func queueChapter(
    at index: Int, displayTitle: String, in chapters: [ItemChapterInfo]
  ) -> ListeningQueueChapter? {
    guard chapters.indices.contains(index) else { return nil }
    let chapter = chapters[index]
    return ListeningQueueChapter(start: chapter.start, end: chapter.end, title: displayTitle)
  }

  /// The player lists whatever is playing: a book's chapters can be queued, an episode's cannot.
  static func isOffered(playingEpisodeID: String?) -> Bool { playingEpisodeID == nil }

  /// The queued chapter for a row of the player's list, which holds the playing title's own
  /// chapter map.
  static func queueChapter(_ chapter: PlaybackChapter, displayTitle: String) -> ListeningQueueChapter {
    ListeningQueueChapter(start: chapter.start, end: chapter.end, title: displayTitle)
  }
}
