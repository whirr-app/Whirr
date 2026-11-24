import Foundation
import GRDB

/// Failures while pointing the device-owned bookmark at an episode.
public enum RSSPlaybackBookmarkStoreError: Error, Equatable, Sendable {
  /// A feed was named without an episode. A native show is never itself playable, only its
  /// episodes are, so there is nothing to bookmark.
  case missingEpisodeID(feedId: Int64)
  case unknownEpisode(feedId: Int64, episodeID: String)
}

/// "What was last played" for device-owned episodes, the native mirror of the account's
/// `playbackBookmark`. A separate table because the account row is torn down at logout and these
/// subscriptions are not. Writes replace the single row, as `DefaultPlaybackBookmarkStoring` does;
/// a reaped or unsubscribed episode takes the bookmark with it through the foreign key.
public struct RSSPlaybackBookmarkStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Points the bookmark at `episodeID` (the episode's identity key, as the playback boundary
  /// carries it). Resolution and replacement share one transaction so a feed refresh cannot reap
  /// the episode between the two.
  public func setBookmark(feedId: Int64, episodeID: String?, now: Date = Date()) async throws {
    guard let episodeID else {
      throw RSSPlaybackBookmarkStoreError.missingEpisodeID(feedId: feedId)
    }
    try await database.writeAsync { db in
      guard
        let episodeRowId = try Int64.fetchOne(
          db, sql: "SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?",
          arguments: [feedId, episodeID])
      else {
        throw RSSPlaybackBookmarkStoreError.unknownEpisode(feedId: feedId, episodeID: episodeID)
      }
      try db.execute(
        sql: """
          INSERT INTO rssPlaybackBookmark (id, episodeId, updatedAt) VALUES (0, ?, ?)
          ON CONFLICT(id) DO UPDATE SET episodeId = excluded.episodeId,
            updatedAt = excluded.updatedAt
          """,
        arguments: [episodeRowId, now])
    }
  }

  /// The bookmarked episode's row id, or `nil` when nothing is bookmarked.
  public func fetchBookmarkedEpisodeId() async throws -> Int64? {
    try await database.readAsync { db in
      try Int64.fetchOne(db, sql: "SELECT episodeId FROM rssPlaybackBookmark WHERE id = 0")
    }
  }

  /// The device marker as the shared projection, paired with the stamp
  /// `MergedPlaybackBookmarkReading` orders the surfaces by. Takes a `Database` so both
  /// projections share one snapshot.
  ///
  /// `showTitle` is always populated: a native feed is never itself playable, so this is always an
  /// episode bookmark. Position is joined from `rssEpisodeState`, so a tick re-emits the
  /// projection without rewriting this table.
  static func timestampedBookmark(in db: Database) throws -> (
    bookmark: PlaybackBookmark, updatedAt: Date
  )? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: """
          SELECT
            episode.feedId AS feedId,
            episode.identityKey AS episodeID,
            episode.title AS episodeTitle,
            feed.title AS showTitle,
            COALESCE(episode.title, feed.title) AS title,
            feed.author AS author,
            \(RSSDownloadDurationStore.preferredDurationSQL(episode: "episode", download: "download"))
              AS durationSeconds,
            state.position AS position,
            state.finished AS finished,
            bookmark.updatedAt AS updatedAt
          FROM rssPlaybackBookmark AS bookmark
          JOIN rssEpisode AS episode ON episode.id = bookmark.episodeId
          JOIN rssFeed AS feed ON feed.id = episode.feedId
          LEFT JOIN rssEpisodeState AS state ON state.episodeId = episode.id
          LEFT JOIN rssDownload AS download ON download.episodeId = episode.id
          WHERE bookmark.id = 0
          """)
    else { return nil }

    let feedId: Int64 = row["feedId"]
    guard let itemId = PodcastSourceIdentity.rss(feedId: feedId)?.itemId else { return nil }
    return (
      bookmark: PlaybackBookmark(
        serverItemId: itemId,
        episodeID: row["episodeID"],
        episodeTitle: row["episodeTitle"],
        showTitle: row["showTitle"],
        title: (row["title"] as String?) ?? "",
        author: row["author"],
        durationSeconds: row["durationSeconds"],
        positionSeconds: (row["position"] as Double?) ?? 0,
        isFinished: (row["finished"] as Bool?) ?? false),
      updatedAt: row["updatedAt"]
    )
  }
}
