import AppModel

/// Which lists the item-detail jump sheet offers. An audiobook gets the same Chapters | Bookmarks
/// pair as the player's chapter sheet, so a bookmark is reachable without starting playback.
nonisolated enum ItemDetailJumpListPresentation {
  enum Tab: Hashable, CaseIterable {
    case chapters
    case bookmarks
    case contents

    var title: String {
      switch self {
      case .chapters: "Chapters"
      case .bookmarks: "Bookmarks"
      case .contents: "Contents"
      }
    }
  }

  /// In switch order. Bookmarks follow the player's rule (`PlayerBookmarkPresentation`): a
  /// podcast's episodes share their show's item id, so only an audiobook takes them.
  static func tabs(capability: ItemMediaCapability, itemID: String) -> [Tab] {
    let bookmarkable = PlayerBookmarkPresentation.isBookmarkable(itemID: itemID, episodeID: nil)
    switch capability {
    case .audio:
      return bookmarkable ? [.chapters, .bookmarks] : [.chapters]
    case .audioAndEbook:
      return bookmarkable ? [.chapters, .bookmarks, .contents] : [.chapters, .contents]
    case .podcast:
      return [.chapters]
    case .ebook:
      return [.contents]
    case .unsupportedDocument:
      return []
    }
  }
}
