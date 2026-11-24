import GRDB

/// v70: the capture seam. Every write to a synced podcast table marks the entity it touched, and
/// nothing else. See `PodcastCloudDirtyLog`.
///
/// The triggers perform no user mutation (one would go unstamped). They record which entity may
/// have changed, and `SyncEngine` later stamps the difference from the last accepted cloud value
/// in its own transaction. Every writer reaches the tables, so later ones are captured too.
///
/// Keyed by entity, so repeated edits collapse and size is bounded by the catalogue. It fills
/// while sync is off and drains on enable.
enum PodcastCloudDirtyLogMigration {
  static func migrate(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TABLE podcastCloudDirty (
          kind TEXT NOT NULL,
          key TEXT NOT NULL,
          PRIMARY KEY (kind, key)
        ) WITHOUT ROWID
        """)

    // Follow and unfollow are the catalogue row appearing and going; custom order is the one
    // column of it that is a synced register. Refresh rewrites titles and validators constantly,
    // and none of that is intent.
    try trigger("podcastCloudDirty_rssFeed_ai", "AFTER INSERT ON rssFeed", "sub", "NEW.feedURL", db)
    try trigger("podcastCloudDirty_rssFeed_ad", "AFTER DELETE ON rssFeed", "sub", "OLD.feedURL", db)
    try trigger(
      "podcastCloudDirty_rssFeed_au",
      "AFTER UPDATE OF customSortIndex ON rssFeed WHEN NEW.customSortIndex IS NOT OLD.customSortIndex",
      "sub", "NEW.feedURL", db)

    try trigger(
      "podcastCloudDirty_rssFeedSettings_ai", "AFTER INSERT ON rssFeedSettings", "settings",
      "CAST(NEW.feedId AS TEXT)", db)
    try trigger(
      "podcastCloudDirty_rssFeedSettings_au", "AFTER UPDATE ON rssFeedSettings", "settings",
      "CAST(NEW.feedId AS TEXT)", db)

    for table in ["nativePodcastSettings", "rssShowOrder"] {
      try trigger("podcastCloudDirty_\(table)_ai", "AFTER INSERT ON \(table)", "globals", "''", db)
      try trigger("podcastCloudDirty_\(table)_au", "AFTER UPDATE ON \(table)", "globals", "''", db)
    }

    // Deletions of state rows are cascades from a reaped episode or an unsubscribe, never intent,
    // so only inserts and updates mark.
    try trigger(
      "podcastCloudDirty_rssEpisodeState_ai", "AFTER INSERT ON rssEpisodeState", "state",
      "CAST(NEW.episodeId AS TEXT)", db)
    try trigger(
      "podcastCloudDirty_rssEpisodeState_au", "AFTER UPDATE ON rssEpisodeState", "state",
      "CAST(NEW.episodeId AS TEXT)", db)

    // A shelf deletion is intent only while its episode still exists; the drain decides that.
    try trigger(
      "podcastCloudDirty_rssSavedShelfEntry_ai", "AFTER INSERT ON rssSavedShelfEntry", "saved",
      "CAST(NEW.rssEpisodeId AS TEXT)", db)
    try trigger(
      "podcastCloudDirty_rssSavedShelfEntry_ad", "AFTER DELETE ON rssSavedShelfEntry", "saved",
      "CAST(OLD.rssEpisodeId AS TEXT)", db)

    try trigger(
      "podcastCloudDirty_rssPlaybackBookmark_ai", "AFTER INSERT ON rssPlaybackBookmark", "bookmark",
      "''", db)
    try trigger(
      "podcastCloudDirty_rssPlaybackBookmark_au", "AFTER UPDATE ON rssPlaybackBookmark", "bookmark",
      "''", db)
  }

  /// The body is a guarded plain insert rather than `INSERT OR IGNORE`: a trigger's conflict
  /// clause yields to the conflict resolution of the statement that fired it, so under a caller's
  /// `INSERT ... ON CONFLICT DO UPDATE` an `OR IGNORE` here would still abort on a duplicate.
  private static func trigger(
    _ name: String, _ event: String, _ kind: String, _ key: String, _ db: Database
  ) throws {
    try db.execute(
      sql: """
        CREATE TRIGGER \(name) \(event)
        BEGIN
          INSERT INTO podcastCloudDirty (kind, key)
          SELECT '\(kind)', \(key)
          WHERE NOT EXISTS (SELECT 1 FROM podcastCloudDirty WHERE kind = '\(kind)' AND key = \(key));
        END
        """)
  }
}
