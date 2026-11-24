import ABSApi
import AppModel
import Foundation
import Persistence

/// What a screen hands the wash provider when it wants an item coloured: the palette key and,
/// when the item's artwork does not live on the server, where that artwork is.
///
/// The coordinator can't colour an `rss:` item from its id (a feed's artwork URL lives only in the
/// feed record) and silently skips it without a source. The model that knows its artwork builds
/// the subject, so a surface can't ask for a wash without saying where the cover is.
nonisolated struct EditorialWashSubject: Hashable, Sendable {
  let itemID: String
  /// No default: a caller that has no source says so, and the `washSubject` helpers below are the
  /// ordinary way to build one.
  let artworkSource: ArtworkSource?
  /// No default, for the same reason as `artworkSource`: a subject's wash shares its cover's
  /// palette row, so it must name the same revision every other surface for the item does.
  let artworkRevision: ArtworkRevision

  /// A server item (an author, a series, a book) whose artwork the coordinator resolves through
  /// the account scope without a source of its own.
  static func audiobookshelf(_ itemID: String, revision: ArtworkRevision) -> EditorialWashSubject {
    EditorialWashSubject(itemID: itemID, artworkSource: nil, artworkRevision: revision)
  }
}

extension Array where Element == EditorialWashSubject {
  /// First occurrence wins: a shelf legitimately carries many episodes of one show, and every
  /// episode of a show resolves to the show's own artwork.
  nonisolated var sourcesByID: [String: ArtworkSource] {
    Dictionary(
      compactMap { subject in subject.artworkSource.map { (subject.itemID, $0) } },
      uniquingKeysWith: { first, _ in first })
  }

  nonisolated var itemIDs: [String] { map(\.itemID) }

  /// First occurrence wins, as for `sourcesByID`.
  nonisolated var revisionsByID: [String: ArtworkRevision] {
    Dictionary(map { ($0.itemID, $0.artworkRevision) }, uniquingKeysWith: { first, _ in first })
  }
}

extension ItemSummary {
  nonisolated var washSubject: EditorialWashSubject {
    EditorialWashSubject(
      itemID: serverItemId, artworkSource: providerArtworkSource, artworkRevision: artworkRevision)
  }
}

extension HomeItem {
  nonisolated var washSubject: EditorialWashSubject { itemSummary.washSubject }
}

extension HomePodcastEpisode {
  /// Keyed by the owning show: every episode of a show shares the show's palette.
  nonisolated var washSubject: EditorialWashSubject {
    EditorialWashSubject(
      itemID: itemID, artworkSource: providerArtworkSource, artworkRevision: artworkRevision)
  }
}

extension SavedShelfItem {
  /// The saved subject's palette key, whether the entry is a book, a server episode, or an RSS
  /// episode, including a tombstoned entry, whose cover is still worth colouring.
  nonisolated var washSubject: EditorialWashSubject {
    EditorialWashSubject(
      itemID: identity.itemID,
      artworkSource: episode?.providerArtworkSource ?? itemSummary?.providerArtworkSource,
      artworkRevision: artworkRevision)
  }
}

extension RSSDownloadedFeed {
  nonisolated var washSubject: EditorialWashSubject {
    EditorialWashSubject(
      itemID: artworkItemID, artworkSource: providerArtworkSource, artworkRevision: .unversioned)
  }
}

extension HomeArtworkPrefetching {
  static func washSubjects(for content: HomeViewPresentation.Section.Content) -> [EditorialWashSubject] {
    switch content {
    case .items(let items): items.map(\.washSubject)
    case .podcastEpisodes(let episodes): episodes.map(\.washSubject)
    case .savedEntries(let entries): entries.map(\.washSubject)
    case .listeningStats, .smartLists: []
    }
  }
}
