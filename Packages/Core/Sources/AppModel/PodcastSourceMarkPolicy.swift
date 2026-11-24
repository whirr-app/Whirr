import Persistence

/// Where a podcast came from, drawn as a mark in the corner of its artwork.
///
/// Only the server case exists: a mark on every tile is texture, not signal, so the followed feed
/// is left bare. The server show is the one that behaves differently (its progress syncs with ABS,
/// its episodes come from the library).
public enum PodcastSourceMark: Sendable, Equatable {
  case server

  public var symbolName: String { "server.rack" }
  public var accessibilityLabel: String { Self.serverLabel }

  /// Shared with the Podcasts tab's show tiles, which mark provenance the same way. One constant,
  /// so the same mark cannot come to mean two different things on two screens.
  public static let serverLabel = "On your server"
}

/// Decides which podcast tiles carry a source mark.
///
/// Pure and surface-agnostic: Home's shelves, their disclosure pages and the Podcasts grid ask
/// whether the surface mixes sources and whether a tile is the marked kind.
public enum PodcastSourceMarkPolicy {
  /// True only when the surface holds both a server show and a followed feed. Taken over the
  /// surface's resolved contents rather than re-derived per tile, so every tile on one surface
  /// agrees about which surface it is on.
  public static func surfaceMixesSources(podcastItemIDs: [String]) -> Bool {
    var sawServer = false
    var sawFeed = false
    for itemID in podcastItemIDs {
      switch PodcastShowSourcePresentation.source(itemID: itemID) {
      case .audiobookshelf: sawServer = true
      case .rssFeed: sawFeed = true
      case nil: continue
      }
      if sawServer, sawFeed { return true }
    }
    return false
  }

  /// Non-nil only for a server-sourced podcast on a surface that mixes sources. Audiobooks and
  /// ebooks are never followed from a feed, so their provenance is not the question this mark
  /// answers even when they share a shelf with podcasts.
  public static func mark(
    itemID: String, category: ItemMediaCategory, surfaceMixesSources: Bool
  ) -> PodcastSourceMark? {
    guard surfaceMixesSources, category == .podcast,
      PodcastShowSourcePresentation.source(itemID: itemID) == .audiobookshelf
    else { return nil }
    return .server
  }
}
