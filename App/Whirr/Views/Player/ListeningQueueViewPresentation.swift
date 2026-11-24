import AppModel
import DesignSystem
import Foundation
import Persistence

/// The pure row-projection layer over `[ListeningQueueItem]`: ordering, `canMoveEarlier`/
/// `canMoveLater` edges, which row is "Next", selectability, and the media glyph/context-menu
/// inventory per category. Nothing here presents anything or mutates the queue.
nonisolated enum ListeningQueueViewPresentation {
  struct Row: Equatable, Identifiable {
    let id: Int64
    let identity: ListeningIdentity
    /// The row's two lines. A chapter row is named by its chapter, over its book and author.
    let primaryTitle: String
    let secondaryTitle: String
    /// The title's own name and author, whatever the row shows: the cover's placeholder and the
    /// player's metadata seed describe the book, not the chapter.
    let itemTitle: String
    let itemAuthor: String
    /// The chapter a chapter row plays; nil for a whole book or an episode.
    let chapter: ListeningQueueChapter?
    let category: ItemMediaCategory
    let artworkURL: URL?
    let artworkFeedURL: URL?
    /// The episode's own artwork; `artworkURL` stays the show's.
    let episodeArtworkURL: URL?
    let serverUpdatedAt: Date?
    let position: Int
    /// The first live row in the sheet, never Now Playing itself. The sheet only receives future
    /// items, so index `0` here is always the row the quiet distinction applies to.
    let isNext: Bool
    let isSelectable: Bool
    let canMoveEarlier: Bool
    let canMoveLater: Bool

    var mediaKind: MediaKindBadge { ListeningQueueViewPresentation.mediaKind(for: category) }
    /// Spoken after the two lines, so a chapter row reads as a chapter of its book.
    var mediaKindLabel: String {
      chapter == nil
        ? ListeningQueueViewPresentation.mediaKindLabel(for: category)
        : ListeningQueueViewPresentation.chapterKindLabel
    }
  }

  static func rows(_ items: [ListeningQueueItem]) -> [Row] {
    items.enumerated().map { index, item in
      Row(
        id: item.id, identity: item.identity,
        primaryTitle: ListeningQueueRowText.primary(item),
        secondaryTitle: ListeningQueueRowText.secondary(item) ?? "",
        itemTitle: item.primaryTitle, itemAuthor: item.secondaryTitle, chapter: item.chapter,
        category: item.category, artworkURL: item.artworkURL,
        artworkFeedURL: item.artworkFeedURL, episodeArtworkURL: item.episodeArtworkURL,
        serverUpdatedAt: item.serverUpdatedAt,
        position: item.position,
        isNext: index == 0,
        isSelectable: item.isTombstone == false,
        canMoveEarlier: index > 0, canMoveLater: index < items.count - 1)
    }
  }

  static func mediaKind(for category: ItemMediaCategory) -> MediaKindBadge {
    switch category {
    case .audiobook: return .audiobook
    case .podcast: return .podcast
    case .ebook: return .ebook
    }
  }

  /// The accessible name for a row's media-type glyph. Distinct from `HomeRowPresentation
  /// .badgeLabel` ("Podcast") because a queue row's secondary line is already the show's own
  /// title, so repeating "Podcast" adds nothing "Podcast episode" doesn't say more precisely.
  static func mediaKindLabel(for category: ItemMediaCategory) -> String {
    switch category {
    case .audiobook: return "Audiobook"
    case .podcast: return "Podcast episode"
    case .ebook: return "eBook"
    }
  }

  static let chapterKindLabel = "Audiobook chapter"

  /// The Accessibility contract's "position" element ("Position 2 of 4"); `rank` is 1-based.
  static func positionText(rank: Int, total: Int) -> String {
    "Position \(rank) of \(total)"
  }

  /// The queue sheet's context-menu inventory: Play Now plus View Details, the same words every
  /// other route to an item's page uses. An episode opens its card, not its show: the row is the
  /// episode.
  static func contextActions(for category: ItemMediaCategory) -> [MediaContextAction] {
    let playNow = MediaContextAction(
      id: "play-now", label: MediaActionCopy.playNow.title, hint: "Starts playing this item now",
      systemImage: MediaActionCopy.playNow.systemImage)
    let hint =
      switch category {
      case .audiobook, .ebook: "Opens this book's detail page"
      case .podcast: "Opens this episode's details"
      }
    let open = MediaContextAction(
      id: "open-item", label: MediaActionCopy.viewDetails.title, hint: hint,
      systemImage: MediaActionCopy.viewDetails.systemImage)
    return [playNow, open]
  }
}
