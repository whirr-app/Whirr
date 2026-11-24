import GRDB

/// v103: each episode's own feed-declared artwork. Clearing the feed validators makes every
/// followed feed's next refresh a full fetch, so stored episodes backfill the column; a 304 would
/// otherwise leave it null until the feed changed.
enum RSSEpisodeArtworkMigration {
  static func migrate(_ db: Database) throws {
    try db.alter(table: "rssEpisode") { t in
      t.add(column: "artworkURL", .text)
    }
    try db.execute(sql: "UPDATE rssFeed SET etag = NULL, lastModified = NULL")
  }
}
