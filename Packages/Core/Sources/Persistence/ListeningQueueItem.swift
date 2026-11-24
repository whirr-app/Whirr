import Foundation

/// One durable local Up Next row projected without GRDB types: a whole audiobook or a single
/// podcast episode. For an audiobook, `primaryTitle`/`secondaryTitle` are the item's title and
/// author; for an episode, the episode's title and its show's title. RSS rows also carry the
/// feed's declared artwork so presentation layers keep the provider identity without a second
/// read.
public struct ListeningQueueItem: Sendable, Equatable, Identifiable {
  public let id: Int64
  public let position: Int
  public let identity: ListeningIdentity
  public let primaryTitle: String
  public let secondaryTitle: String
  public let category: ItemMediaCategory
  public let isTombstone: Bool
  public let artworkURL: URL?
  public let artworkFeedURL: URL?
  /// The RSS episode's own declared artwork; nil for ABS entries and episodes that declare none.
  /// `artworkURL` stays the show's.
  public let episodeArtworkURL: URL?
  /// The ABS item's server `updatedAt`, which revisions its cover (an episode's show). `nil` for
  /// RSS, whose artwork is addressed by URL.
  public let serverUpdatedAt: Date?
  /// The chapter an audiobook row is limited to; `nil` for the whole book and for episodes.
  public let chapter: ListeningQueueChapter?

  public init(
    id: Int64,
    position: Int,
    identity: ListeningIdentity,
    primaryTitle: String,
    secondaryTitle: String,
    category: ItemMediaCategory,
    isTombstone: Bool,
    artworkURL: URL? = nil,
    artworkFeedURL: URL? = nil,
    serverUpdatedAt: Date? = nil,
    chapter: ListeningQueueChapter? = nil,
    episodeArtworkURL: URL? = nil
  ) {
    self.id = id
    self.position = position
    self.identity = identity
    self.primaryTitle = primaryTitle
    self.secondaryTitle = secondaryTitle
    self.category = category
    self.isTombstone = isTombstone
    self.artworkURL = artworkURL
    self.artworkFeedURL = artworkFeedURL
    self.serverUpdatedAt = serverUpdatedAt
    self.chapter = chapter
    self.episodeArtworkURL = episodeArtworkURL
  }

  /// The row's chapter with the row that holds it; `nil` for a whole-book or episode row.
  public var rowChapter: ListeningQueueRowChapter? {
    chapter.map { ListeningQueueRowChapter(rowID: id, chapter: $0) }
  }
}

/// A queued chapter and its Up Next row. A book may have several chapter rows, so the row, not
/// the title, names what a start plays and consumes.
public struct ListeningQueueRowChapter: Sendable, Hashable {
  public let rowID: Int64
  public let chapter: ListeningQueueChapter

  public init(rowID: Int64, chapter: ListeningQueueChapter) {
    self.rowID = rowID
    self.chapter = chapter
  }
}
