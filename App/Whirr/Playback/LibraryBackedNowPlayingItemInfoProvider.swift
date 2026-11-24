import ABSApi
import Foundation
import GRDB
import Persistence

/// Production `NowPlayingItemInfoProviding`: resolves title/author from the local database
/// `LibraryReading` reads, for the signed-in account (`PlayerCore` has no title/author/cover art).
/// A podcast episode resolves through `EpisodeDisplayTitle`: its own title in the primary slot and
/// the show in the secondary one, the same pair `DefaultPlaybackBookmarkStoring` projects; item id
/// alone would name the show for every episode on the lock screen, CarPlay and Control Center.
final class LibraryBackedNowPlayingItemInfoProvider: NowPlayingItemInfoProviding {
  private let itemDAO: ItemDAO
  private let episodeDAO: PodcastEpisodeDAO
  private let accountDAO: AccountDAO

  init(database: AppDatabase, accountDAO: AccountDAO) {
    itemDAO = ItemDAO(database: database)
    episodeDAO = PodcastEpisodeDAO(database: database)
    self.accountDAO = accountDAO
  }

  func nowPlayingItemInfo(forItemID itemID: String) -> NowPlayingItemInfo? {
    nowPlayingItemInfo(forItemID: itemID, episodeID: nil)
  }

  func nowPlayingItemInfo(forItemID itemID: String, episodeID: String?) -> NowPlayingItemInfo? {
    guard let accountId = (try? accountDAO.fetch())?.id,
      let item = try? itemDAO.fetchOne(accountId: accountId, serverItemId: itemID)
    else { return nil }
    // An episode that no longer resolves (soft-deleted by a sync traversal, or an id this store has
    // never seen) falls back to the show's own metadata rather than to nothing: something true is
    // better on a lock screen than a blank one.
    guard let episodeID, let itemRowId = item.id,
      let episode = try? episodeDAO.fetchOne(itemId: itemRowId, serverEpisodeId: episodeID),
      episode.softDeleted == false
    else {
      return NowPlayingItemInfo(
        title: item.title, author: item.author, artworkRevision: Self.revision(of: item))
    }
    let displayTitle = EpisodeDisplayTitle(episodeTitle: episode.title, showTitle: item.title)
    return NowPlayingItemInfo(
      title: displayTitle.primary, author: displayTitle.secondary,
      artworkRevision: Self.revision(of: item))
  }

  /// An episode draws its show's cover, so both cases carry the item's revision.
  private static func revision(of item: ItemRecord) -> ArtworkRevision {
    ArtworkRevision(serverUpdatedAt: item.serverUpdatedAt)
  }
}

/// Resolves static metadata for a device-owned RSS feed. RSS item ids stay out of the
/// account DAOs: asking an account DAO for `rss:<feed-id>` would both return nothing and make a
/// native lock-screen session look like an unresolved ABS item.
final class RSSBackedNowPlayingItemInfoProvider: NowPlayingItemInfoProviding {
  private let database: AppDatabase

  init(database: AppDatabase) {
    self.database = database
  }

  func nowPlayingItemInfo(forItemID itemID: String) -> NowPlayingItemInfo? {
    nowPlayingItemInfo(forItemID: itemID, episodeID: nil)
  }

  func nowPlayingItemInfo(forItemID itemID: String, episodeID: String?) -> NowPlayingItemInfo? {
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else { return nil }
    return try? database.read { db in
      guard let feed = try RSSFeedRecord.fetchOne(db, key: feedID) else { return nil }
      let showTitle = feed.title ?? ""
      let artworkSource = feed.artworkURL.flatMap(URL.init(string:)).flatMap { artworkURL in
        URL(string: feed.feedURL).flatMap { feedURL in
          RSSArtworkSource(
            feedID: feedID, artworkURL: artworkURL, feedURL: feedURL)
        }
      }.map(ArtworkSource.rss)
      guard
        let episodeID,
        let episode = try RSSEpisodeRecord.fetchOne(
          db,
          sql: "SELECT * FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
          arguments: [feedID, episodeID])
      else {
        return NowPlayingItemInfo(
          title: showTitle, author: feed.author, artworkSource: artworkSource)
      }
      let episodeSource = makeEpisodeArtworkSource(
        itemID: itemID, episodeArtworkURL: episode.artworkURL.flatMap(URL.init(string:)),
        artworkFeedURL: URL(string: feed.feedURL))
      return NowPlayingItemInfo(
        title: episode.title ?? showTitle,
        // Match the ABS episode projection: the episode occupies the title slot and the show
        // occupies the secondary slot. If a feed has no title, its author remains useful metadata.
        author: showTitle.isEmpty ? feed.author : showTitle,
        artworkSource: episodeSource ?? artworkSource,
        fallbackArtworkSource: episodeSource == nil ? nil : artworkSource)
    }
  }
}

/// Routes Now Playing metadata using the same strict source identity as playback and bookmark
/// routing. A malformed reserved id is rejected rather than guessed to be ABS, and a valid but
/// unknown RSS feed never falls through to an account DAO.
final class RoutingNowPlayingItemInfoProvider: NowPlayingItemInfoProviding {
  private let abs: any NowPlayingItemInfoProviding
  private let rss: any NowPlayingItemInfoProviding

  init(abs: any NowPlayingItemInfoProviding, rss: any NowPlayingItemInfoProviding) {
    self.abs = abs
    self.rss = rss
  }

  func nowPlayingItemInfo(forItemID itemID: String) -> NowPlayingItemInfo? {
    nowPlayingItemInfo(forItemID: itemID, episodeID: nil)
  }

  func nowPlayingItemInfo(forItemID itemID: String, episodeID: String?) -> NowPlayingItemInfo? {
    switch PodcastSourceIdentity(itemId: itemID)?.source {
    case .rss:
      return rss.nowPlayingItemInfo(forItemID: itemID, episodeID: episodeID)
    case .abs:
      return abs.nowPlayingItemInfo(forItemID: itemID, episodeID: episodeID)
    case nil:
      return nil
    }
  }
}
