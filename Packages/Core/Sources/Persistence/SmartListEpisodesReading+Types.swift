import Foundation

/// Where an episode stands for a list's status toggles. Finished, or with under
/// `LatestPodcastEpisodePolicy.minimumRemainingSeconds` of known length left, is played.
public enum SmartListEpisodeStatus: Sendable, Equatable {
  case unplayed
  case inProgress
  case played
}

/// One row of a smart list, from either source. `itemID` and `episodeID` are the
/// `ListeningIdentity` pair (`rss:<feedId>` and the episode's `identityKey` for a native episode).
public struct SmartListEpisode: Sendable, Equatable, Identifiable {
  public let source: SmartListShowSource
  public let itemID: String
  public let episodeID: String
  /// What `smartListShow.showKey` holds for this episode's show.
  public let showKey: String
  public let showTitle: String
  public let showAuthor: String?
  public let title: String
  public let publishedAt: Date?
  /// Nil when the length is unknown (missing or not positive).
  public let durationSeconds: Double?
  /// Quantized with `PlaybackPositionListProjection.quantizedSeconds`.
  public let progressSeconds: Double
  public let status: SmartListEpisodeStatus
  public let isDownloaded: Bool
  public let isSaved: Bool
  public let isPriority: Bool
  /// Native shows' own artwork, and the feed URL the artwork cache keys on.
  public let artworkURL: URL?
  public let artworkFeedURL: URL?
  /// Server shows' cover cache buster.
  public let showServerUpdatedAt: Date?
  public let sortKey: SmartListSortKey

  public var id: String { "\(source.rawValue)/\(itemID)/\(episodeID)" }

  public var isFinished: Bool { status == .played }
}

/// An episode a run may play next.
public struct SmartListCandidate: Sendable, Equatable {
  public let episode: SmartListEpisode
  public var source: SmartListShowSource { episode.source }
  public var itemID: String { episode.itemID }
  public var episodeID: String { episode.episodeID }
  public var sortKey: SmartListSortKey { episode.sortKey }
}

/// A list's rows in order. `matchCount` counts every match, not just the rows returned.
public struct SmartListSnapshot: Sendable, Equatable {
  public let episodes: [SmartListEpisode]
  /// Whether more rows match than `episodes` holds.
  public let hasMore: Bool
  public let matchCount: Int?

  public init(episodes: [SmartListEpisode], hasMore: Bool, matchCount: Int?) {
    self.episodes = episodes
    self.hasMore = hasMore
    self.matchCount = matchCount
  }

  public static let empty = SmartListSnapshot(episodes: [], hasMore: false, matchCount: 0)
}

/// An episode an auto-downloading list wants kept downloaded.
public struct SmartListWantedEpisode: Sendable, Equatable {
  public let listID: Int64
  public let source: SmartListShowSource
  public let itemID: String
  public let episodeID: String

  public init(listID: Int64, source: SmartListShowSource, itemID: String, episodeID: String) {
    self.listID = listID
    self.source = source
    self.itemID = itemID
    self.episodeID = episodeID
  }

  /// What a change to the wanted set compares: membership, not progress or download state.
  public struct Key: Sendable, Hashable {
    public let listID: Int64
    public let itemID: String
    public let episodeID: String

    public init(listID: Int64, itemID: String, episodeID: String) {
      self.listID = listID
      self.itemID = itemID
      self.episodeID = episodeID
    }
  }

  public var key: Key { Key(listID: listID, itemID: itemID, episodeID: episodeID) }
}
