import AppModel
import Foundation
import Persistence
import PlayerCore

struct PlayerBookmarkRow: Identifiable, Equatable {
  let bookmark: AudioBookmark
  let title: String
  let positionLabel: String
  let chapterTitle: String?
  /// "1:03:20 · The Last Word", or the time alone when the item has no chapters.
  let detailText: String
  let accessibilityLabel: String

  var id: AudioBookmarkKey { bookmark.id }
  /// The stored time, unrounded: a bookmark made on another client may carry a fraction.
  var seekOffset: Double { bookmark.time }
}

/// What the player's audiobook bookmarks look like and when they are offered.
nonisolated enum PlayerBookmarkPresentation {
  struct Confirmation: Equatable {
    let message: String
    /// The bookmark the banner's Edit action renames; `nil` when nothing was saved.
    let editableBookmark: AudioBookmark?
  }

  static let untitled = "Untitled Bookmark"

  /// Audiobookshelf stores bookmarks per library item, so only a server audiobook takes them: a
  /// podcast episode shares its show's item id, and a device-owned (`rss:`) item has no server.
  static func isBookmarkable(itemID: String, episodeID: String?) -> Bool {
    episodeID == nil && itemID.isEmpty == false && itemID.hasPrefix("rss:") == false
  }

  /// Adding reads the live playhead, so the item on screen must be the one PlayerCore has loaded.
  /// Anything else would bookmark another item's position.
  static func canAddBookmark(
    itemID: String, episodeID: String?, activeItemID: String?, loadedItemID: String?,
    loadedEpisodeID: String?
  ) -> Bool {
    isBookmarkable(itemID: itemID, episodeID: episodeID)
      && activeItemID == itemID && loadedItemID == itemID && loadedEpisodeID == nil
  }

  /// One tap saves, so the title has to be useful without typing: the chapter the listener is
  /// in, as the chapter list names it.
  static func defaultTitle(position: Double, chapters: [PlaybackChapter]) -> String {
    chapterTitle(at: position, chapters: chapters)
      ?? "Bookmark at \(PlayerTimeFormatting.clock(position))"
  }

  static func rows(bookmarks: [AudioBookmark], chapters: [PlaybackChapter]) -> [PlayerBookmarkRow] {
    bookmarks.sorted { $0.time < $1.time }.map { bookmark in
      let trimmed = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
      let title = trimmed.isEmpty ? untitled : trimmed
      let position = PlayerTimeFormatting.clock(bookmark.time)
      let chapter = chapterTitle(at: bookmark.time, chapters: chapters)
      return PlayerBookmarkRow(
        bookmark: bookmark,
        title: title,
        positionLabel: position,
        chapterTitle: chapter,
        detailText: chapter.map { "\(position) · \($0)" } ?? position,
        accessibilityLabel: "\(title), at \(position)" + (chapter.map { ", in \($0)" } ?? ""))
    }
  }

  static func confirmation(for outcome: AudioBookmarksModel.AddOutcome) -> Confirmation? {
    switch outcome {
    case .added(let bookmark):
      Confirmation(
        message: "Bookmark added at \(PlayerTimeFormatting.clock(bookmark.time))",
        editableBookmark: bookmark)
    case .alreadyBookmarked(let existing):
      Confirmation(
        message: "Already bookmarked at \(PlayerTimeFormatting.clock(existing.time))",
        editableBookmark: existing)
    case .failed:
      Confirmation(message: AudioBookmarkCopy.saveFailed, editableBookmark: nil)
    }
  }

  /// Long enough to reach the Edit action, which the queue banners' two seconds are not.
  static let confirmationDuration: Double = 4

  private static func chapterTitle(at position: Double, chapters: [PlaybackChapter]) -> String? {
    ChapterSelectorPresentation.rows(chapters: chapters, currentTime: position)
      .first(where: \.isCurrent)?.title
  }
}
