import Persistence

/// Maps a native feed's episode identity keys to the device-owned `rssEpisode` row ids.
///
/// The show and card models address episodes by `PodcastEpisodeSummary.id`, which for a native
/// feed is the feed-derived identity key (a GUID or an enclosure hash), not the row id. The
/// server-save coordinator and status projection are keyed by row id, so every server-save entry
/// point resolves through this seam first. A key with no row is omitted: the caller treats it as a
/// missing episode and the coordinator is never asked.
public protocol NativeEpisodeIDResolving: Sendable {
  /// The row ids for the keys that exist in `feedId`; keys with no row are omitted.
  func nativeEpisodeIDs(feedId: Int64, identityKeys: [String]) async -> [String: Int64]
}

extension NativeEpisodeIDResolving {
  public func nativeEpisodeID(feedId: Int64, identityKey: String) async -> Int64? {
    await nativeEpisodeIDs(feedId: feedId, identityKeys: [identityKey])[identityKey]
  }
}

public struct PersistenceNativeEpisodeIDResolver: NativeEpisodeIDResolving, Sendable {
  private let episodeStore: RSSEpisodeStore

  public init(database: AppDatabase) {
    episodeStore = RSSEpisodeStore(database: database)
  }

  public func nativeEpisodeIDs(feedId: Int64, identityKeys: [String]) async -> [String: Int64] {
    guard identityKeys.isEmpty == false else { return [:] }
    let ids =
      (try? await episodeStore.fetchEpisodeIDs(feedId: feedId, identityKeys: identityKeys))
      ?? [:]
    return ids
  }
}

/// Resolves nothing, so a model composed with it reports every server-save entry point as a
/// missing episode rather than guessing an id. This is the correct inert default: production
/// composition always supplies the persistence-backed resolver.
public struct NoOpNativeEpisodeIDResolving: NativeEpisodeIDResolving, Sendable {
  public init() {}

  public func nativeEpisodeIDs(feedId: Int64, identityKeys: [String]) async -> [String: Int64] {
    [:]
  }
}
