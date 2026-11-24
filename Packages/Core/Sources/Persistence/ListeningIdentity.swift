/// The one value identity the universal listening queue accepts. Server-facing string IDs only,
/// never a GRDB row id (`ListeningQueueStore` resolves those internally).
public struct ListeningIdentity: Sendable, Hashable {
  public enum Source: Sendable, Hashable {
    case audiobook(itemID: String)
    case podcastEpisode(itemID: String, episodeID: String)
    case rssEpisode(feedID: Int64, episodeID: String)
  }

  private enum Storage: Sendable, Hashable {
    case audiobook(itemID: String)
    case podcastEpisode(itemID: String, episodeID: String)
    case rssEpisode(feedID: Int64, itemID: String, episodeID: String)
  }

  private let storage: Storage

  /// Builds an ABS audiobook identity only from the unreserved server namespace.
  public static func audiobook(itemID: String) -> Self? {
    guard PodcastSourceIdentity.abs(itemId: itemID) != nil else { return nil }
    return Self(storage: .audiobook(itemID: itemID))
  }

  /// Builds an ABS podcast identity only from a valid server item and non-empty episode id.
  public static func podcastEpisode(itemID: String, episodeID: String) -> Self? {
    guard PodcastSourceIdentity.abs(itemId: itemID) != nil, episodeID.isEmpty == false else {
      return nil
    }
    return Self(storage: .podcastEpisode(itemID: itemID, episodeID: episodeID))
  }

  /// Builds a native-feed listening identity only when its feed can produce the canonical
  /// `rss:<positive row id>` item identity. Invalid feed row ids fail closed at construction.
  public static func rssEpisode(feedID: Int64, episodeID: String) -> Self? {
    guard
      episodeID.isEmpty == false,
      let itemID = PodcastSourceIdentity.rss(feedId: feedID)?.itemId
    else { return nil }
    return Self(storage: .rssEpisode(feedID: feedID, itemID: itemID, episodeID: episodeID))
  }

  /// The one rule for which listening identity a row's `(itemID, episodeID?)` names, mirroring
  /// `SavedShelfIdentity.resolving`. An episode under a device-owned `rss:` item is `.rssEpisode`;
  /// anything else goes to the ABS `.podcastEpisode` or `.audiobook` factory, which reject a
  /// malformed reserved id. A device-owned item with no episode is a whole native show and has no
  /// identity.
  public static func resolving(itemID: String, episodeID: String? = nil) -> Self? {
    let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId
    switch (episodeID, feedID) {
    case (let episodeID?, let feedID?): return .rssEpisode(feedID: feedID, episodeID: episodeID)
    case (let episodeID?, nil): return .podcastEpisode(itemID: itemID, episodeID: episodeID)
    case (nil, _?): return nil
    case (nil, nil): return .audiobook(itemID: itemID)
    }
  }

  public var source: Source {
    switch storage {
    case .audiobook(let itemID): .audiobook(itemID: itemID)
    case .podcastEpisode(let itemID, let episodeID):
      .podcastEpisode(itemID: itemID, episodeID: episodeID)
    case .rssEpisode(let feedID, _, let episodeID):
      .rssEpisode(feedID: feedID, episodeID: episodeID)
    }
  }

  public var itemID: String {
    switch storage {
    case .audiobook(let itemID): itemID
    case .podcastEpisode(let itemID, _): itemID
    case .rssEpisode(_, let itemID, _): itemID
    }
  }

  public var episodeID: String? {
    switch storage {
    case .audiobook: nil
    case .podcastEpisode(_, let episodeID): episodeID
    case .rssEpisode(_, _, let episodeID): episodeID
    }
  }

  private init(storage: Storage) {
    self.storage = storage
  }
}
