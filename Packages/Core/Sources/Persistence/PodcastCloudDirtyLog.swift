import Foundation
import GRDB

/// One synced podcast entity that local writes may have changed since the cloud last heard of it.
public struct PodcastCloudDirtyEntry: Sendable, Hashable {
  public enum Kind: String, Sendable, CaseIterable {
    /// `key` is the feed URL as the catalogue stored it.
    case subscription = "sub"
    /// `key` is `rssFeed.id`.
    case feedSettings = "settings"
    /// `key` is empty.
    case globals
    /// `key` is `rssEpisode.id`.
    case episodeState = "state"
    /// `key` is `rssEpisode.id`.
    case saved
    /// `key` is empty.
    case bookmark
  }

  public let kind: Kind
  public let key: String

  public init(kind: Kind, key: String) {
    self.kind = kind
    self.key = key
  }

  public var rowID: Int64? { Int64(key) }
}

/// The v70 dirty log. Triggers fill it (`PodcastCloudDirtyLogMigration`); `SyncEngine`'s
/// reconciler drains it inside its own write transaction, so an entry and the outbox row it turns
/// into commit together.
public enum PodcastCloudDirtyLog {
  public static func entries(in db: Database, limit: Int = .max) throws -> [PodcastCloudDirtyEntry] {
    try Row.fetchAll(
      db, sql: "SELECT kind, key FROM podcastCloudDirty ORDER BY kind, key LIMIT ?",
      arguments: [limit]
    ).compactMap { row in
      guard let kind = PodcastCloudDirtyEntry.Kind(rawValue: row["kind"]) else { return nil }
      return PodcastCloudDirtyEntry(kind: kind, key: row["key"])
    }
  }

  public static func isEmpty(in db: Database) throws -> Bool {
    try Bool.fetchOne(db, sql: "SELECT NOT EXISTS (SELECT 1 FROM podcastCloudDirty)") ?? true
  }

  public static func clear(_ entry: PodcastCloudDirtyEntry, in db: Database) throws {
    try db.execute(
      sql: "DELETE FROM podcastCloudDirty WHERE kind = ? AND key = ?",
      arguments: [entry.kind.rawValue, entry.key])
  }

  /// Marks every synced entity this device holds, and every registry follow, so the next drain
  /// compares all of it against the accepted cloud values. Used at bootstrap: it is how state from
  /// before sync, and from while sync was off with an emptied log, reaches the outbox.
  public static func markAll(in db: Database) throws {
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO podcastCloudDirty (kind, key)
          SELECT 'sub', feedURL FROM rssFeed
          UNION SELECT 'sub', normalizedURL FROM podcastCloudSubscriptionRegistry WHERE isFollowed = 1
          UNION SELECT 'settings', CAST(feedId AS TEXT) FROM rssFeedSettings
          UNION SELECT 'globals', ''
          UNION SELECT 'state', CAST(episodeId AS TEXT) FROM rssEpisodeState
          UNION SELECT 'saved', CAST(rssEpisodeId AS TEXT) FROM rssSavedShelfEntry
          UNION SELECT 'bookmark', '' FROM rssPlaybackBookmark
        """)
  }

  /// Whether the log holds anything: once on subscription, then after every commit that touches
  /// it. Not deduplicated, so an edit landing while the log was already non-empty
  /// still wakes the consumer; a drain that finds nothing to publish is cheap.
  public static func observePending(in database: AppDatabase) -> AsyncStream<Bool> {
    ObservationBridge.stream(in: database.dbWriter) { db in try isEmpty(in: db) == false }
  }
}
