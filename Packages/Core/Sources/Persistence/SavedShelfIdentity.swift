/// The one value identity the Saved for Later shelf accepts. Server-facing string IDs only:
/// local GRDB row ids remain inside Persistence and never cross this boundary.
public enum SavedShelfIdentity: Sendable, Hashable {
  case item(itemID: String)
  case podcastEpisode(itemID: String, episodeID: String)
  case rssEpisode(itemID: String, episodeID: String)

  /// The one rule for which shelf identity a row's `(itemID, episodeID?)` names. An episode under a
  /// device-owned `rss:` item is `.rssEpisode`; anything else is the ABS `.podcastEpisode` or
  /// `.item`. A device-owned item with no episode has no identity: a whole native show is never a
  /// Saved for Later entry. A malformed reserved id is not device-owned and keeps the ABS shapes,
  /// which the ABS store then fails to find.
  public static func resolving(itemID: String, episodeID: String? = nil) -> Self? {
    let isDeviceOwned = PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil
    switch (episodeID, isDeviceOwned) {
    case (let episodeID?, true): return .rssEpisode(itemID: itemID, episodeID: episodeID)
    case (let episodeID?, false): return .podcastEpisode(itemID: itemID, episodeID: episodeID)
    case (nil, true): return nil
    case (nil, false): return .item(itemID: itemID)
    }
  }

  public var itemID: String {
    switch self {
    case .item(let itemID): itemID
    case .podcastEpisode(let itemID, _): itemID
    case .rssEpisode(let itemID, _): itemID
    }
  }

  public var episodeID: String? {
    switch self {
    case .item: nil
    case .podcastEpisode(_, let episodeID): episodeID
    case .rssEpisode(_, let episodeID): episodeID
    }
  }
}
