import ABSApi
import AppModel
import Foundation
import Persistence

nonisolated func makeProviderArtworkSource(
  itemID: String, artworkURL: URL?, artworkFeedURL: URL?
) -> ArtworkSource? {
  guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId,
    let artworkURL, let artworkFeedURL,
    let source = RSSArtworkSource(
      feedID: feedID, artworkURL: artworkURL, feedURL: artworkFeedURL)
  else { return nil }
  return .rss(source)
}

/// The episode's own image under its show's `rss:<feedID>` identity and feed URL, or nil when the
/// episode declares none (or the item is not an RSS one), so a caller falls back to the show's.
nonisolated func makeEpisodeArtworkSource(
  itemID: String, episodeArtworkURL: URL?, artworkFeedURL: URL?
) -> ArtworkSource? {
  makeProviderArtworkSource(
    itemID: itemID, artworkURL: episodeArtworkURL, artworkFeedURL: artworkFeedURL)
}

extension ArtworkKey {
  /// The same cover geometry and revision under `source`: the show's cover standing in for an
  /// episode's. Nil when it is the key's own source, or when this key is only a generated
  /// placeholder identity (nothing real has been asked for yet).
  nonisolated func fallingBack(to source: ArtworkSource?) -> ArtworkKey? {
    guard let source, source != self.source else { return nil }
    if case .generated = self.source { return nil }
    return ArtworkKey(source: source, itemID: itemID, variant: variant, revision: revision)
  }
}

extension ItemSummary {
  nonisolated var providerArtworkSource: ArtworkSource? {
    makeProviderArtworkSource(
      itemID: serverItemId, artworkURL: artworkURL, artworkFeedURL: artworkFeedURL)
  }

  /// Every surface drawing one ABS item must agree on this, or the item's single palette row is
  /// re-derived each time a different surface asks for it.
  nonisolated var artworkRevision: ArtworkRevision {
    ArtworkRevision(serverUpdatedAt: serverUpdatedAt)
  }

  /// A task identity for work keyed by this item's cover: it changes when the cover does.
  nonisolated var artworkKeyIdentity: String { "\(serverItemId)|\(artworkRevision.rawValue)" }
}

extension HomeItem {
  nonisolated var artworkRevision: ArtworkRevision {
    ArtworkRevision(serverUpdatedAt: serverUpdatedAt)
  }
}

extension HomePodcastEpisode {
  nonisolated var providerArtworkSource: ArtworkSource? {
    makeProviderArtworkSource(
      itemID: itemID, artworkURL: artworkURL, artworkFeedURL: artworkFeedURL)
  }

  /// The show's revision: an episode draws its show's cover.
  nonisolated var artworkRevision: ArtworkRevision {
    ArtworkRevision(serverUpdatedAt: showServerUpdatedAt)
  }

  /// What opening this episode's show seeds the show page with. It carries the feed artwork so an
  /// RSS show's cover resolves before the page loads, rather than falling back to a server cover
  /// the show does not have.
  nonisolated var showSummary: ItemSummary {
    ItemSummary(
      serverItemId: itemID, mediaKind: "podcast", title: showTitle, author: showAuthor,
      durationSeconds: nil, category: .podcast, artworkURL: artworkURL,
      artworkFeedURL: artworkFeedURL)
  }
}

extension ListeningQueueViewPresentation.Row {
  nonisolated var providerArtworkSource: ArtworkSource? {
    makeProviderArtworkSource(
      itemID: identity.itemID, artworkURL: artworkURL, artworkFeedURL: artworkFeedURL)
  }

  /// The episode's own cover when it has one, else the show's.
  nonisolated var episodeArtworkSource: ArtworkSource? {
    makeEpisodeArtworkSource(
      itemID: identity.itemID, episodeArtworkURL: episodeArtworkURL,
      artworkFeedURL: artworkFeedURL) ?? providerArtworkSource
  }

  nonisolated var artworkRevision: ArtworkRevision {
    ArtworkRevision(serverUpdatedAt: serverUpdatedAt)
  }
}

extension PodcastEpisodeCardPresentation {
  nonisolated func providerArtworkSource(for itemID: String) -> ArtworkSource? {
    makeProviderArtworkSource(
      itemID: itemID, artworkURL: artworkURL, artworkFeedURL: artworkFeedURL)
  }

  /// The episode's own cover when it has one, else the show's.
  nonisolated func episodeArtworkSource(for itemID: String) -> ArtworkSource? {
    makeEpisodeArtworkSource(
      itemID: itemID, episodeArtworkURL: episodeArtworkURL, artworkFeedURL: artworkFeedURL)
      ?? providerArtworkSource(for: itemID)
  }

  /// The show's revision: the card draws its show's cover.
  nonisolated var artworkRevision: ArtworkRevision {
    ArtworkRevision(serverUpdatedAt: showServerUpdatedAt)
  }
}

extension SavedShelfItem {
  /// An episode entry draws its show's cover; a book entry its own.
  nonisolated var artworkRevision: ArtworkRevision {
    episode?.artworkRevision ?? itemSummary?.artworkRevision ?? .unversioned
  }
}

extension Array where Element == ItemSummary {
  /// Keyed by item ID for a prefetch window; a list never repeats an item, but folding is cheaper
  /// than trusting that.
  nonisolated var artworkRevisionsByID: [String: ArtworkRevision] {
    Dictionary(map { ($0.serverItemId, $0.artworkRevision) }, uniquingKeysWith: { first, _ in first })
  }
}

extension LibraryEntityGroup {
  /// The group draws its first item's cover, so it carries that item's revision.
  nonisolated var coverRevision: ArtworkRevision {
    items.first?.artworkRevision ?? .unversioned
  }
}

extension Array where Element == LibraryEntityGroup {
  nonisolated var coverRevisionsByID: [String: ArtworkRevision] {
    Dictionary(
      compactMap { group in group.coverItemID.map { ($0, group.coverRevision) } },
      uniquingKeysWith: { first, _ in first })
  }
}

extension SearchResultRow {
  nonisolated var artworkRevision: ArtworkRevision {
    ArtworkRevision(serverUpdatedAt: serverUpdatedAt)
  }
}

extension RSSDownloadedFeed {
  /// The canonical RSS item id for this feed, and so the artwork cache key its rows share with
  /// every other RSS surface. Falling back to the feed's own URL keeps the key stable and unique
  /// rather than reconstructing the `rss:` spelling by hand, which `PodcastSourceIdentity` owns.
  nonisolated var artworkItemID: String {
    PodcastSourceIdentity.rss(feedId: id)?.itemId ?? sourceURL.absoluteString
  }

  nonisolated var providerArtworkSource: ArtworkSource? {
    guard let itemID = PodcastSourceIdentity.rss(feedId: id)?.itemId else { return nil }
    return makeProviderArtworkSource(
      itemID: itemID, artworkURL: artworkURL, artworkFeedURL: sourceURL)
  }
}
