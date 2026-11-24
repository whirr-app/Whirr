import Foundation
import GRDB

/// The production `PlaybackBookmarkStoring` conformance: a GRDB `ValueObservation` bridged to an
/// `AsyncStream`, so no GRDB type crosses into AppModel (ARCHITECTURE.md §1). Mirrors
/// `DefaultHomeReading`, including resolving the single account row (`AccountDAO`'s contract)
/// inside the tracked closure so a stream started before login emits once it appears.
///
/// Tombstones: a soft-deleted item keeps its bookmark row but projects `nil`. Soft-deletion is a
/// reversible sync inference, so it must not discard the resume point. The second traversal's hard
/// delete is the real removal (the `item` FK cascade takes the bookmark, also projecting `nil`),
/// as for an id that never resolved.
public struct DefaultPlaybackBookmarkStoring: PlaybackBookmarkStoring, Sendable {

  /// Thrown by `setBookmark` when there is no account row, or no item with that server id: a
  /// caller-side mistake (or a race with account removal), never a state to silently swallow.
  public struct UnresolvedBookmarkTarget: Error, Equatable {
    public let serverItemId: String
    public let episodeID: String?

    public init(serverItemId: String, episodeID: String? = nil) {
      self.serverItemId = serverItemId
      self.episodeID = episodeID
    }
  }

  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// `removeDuplicates` because a sync rewrites progress rows unchanged, and the Watch catalogue
  /// publisher holds this stream for the app's life and republishes on every value.
  public func observeBookmark() -> AsyncStream<PlaybackBookmark?> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db in
        try Self.timestampedBookmark(in: db)?.bookmark
      }.removeDuplicates())
  }

  public func fetchBookmark() async -> PlaybackBookmark? {
    try? await database.readAsync { db in
      try Self.timestampedBookmark(in: db)?.bookmark
    }
  }

  public func setBookmark(itemID: String) async throws {
    try await setBookmark(itemID: itemID, episodeID: nil)
  }

  public func setBookmark(itemID: String, episodeID: String?) async throws {
    try await database.writeAsync { db in
      guard let accountId = try AccountRecord.fetchOne(db)?.id,
        let item =
          try ItemRecord
          .filter(Column("accountId") == accountId)
          .filter(Column("serverItemId") == itemID)
          .fetchOne(db),
        let itemRowId = item.id
      else {
        throw UnresolvedBookmarkTarget(serverItemId: itemID, episodeID: episodeID)
      }
      let episodeRowId: Int64?
      if let episodeID {
        guard
          let resolved =
            try PodcastEpisodeRecord
            .filter(Column("accountId") == accountId)
            .filter(Column("itemId") == itemRowId)
            .filter(Column("serverEpisodeId") == episodeID)
            .fetchOne(db)?.id
        else {
          throw UnresolvedBookmarkTarget(serverItemId: itemID, episodeID: episodeID)
        }
        episodeRowId = resolved
      } else {
        episodeRowId = nil
      }
      // Replace rather than upsert: one row per account, and the previous row's id carries no
      // meaning worth preserving.
      try db.execute(sql: "DELETE FROM playbackBookmark WHERE accountId = ?", arguments: [accountId])
      var record = PlaybackBookmarkRecord(
        accountId: accountId, itemId: itemRowId, podcastEpisodeId: episodeRowId, updatedAt: Date())
      try record.insert(db)
    }
  }

  static func timestampedBookmark(in db: Database) throws -> (
    bookmark: PlaybackBookmark, updatedAt: Date
  )? {
    guard let accountId = try AccountRecord.fetchOne(db)?.id else { return nil }
    // `IS` rather than `=` on the episode join: SQLite compares NULLs as distinct under `=`, so
    // an item-level bookmark would never find its item-level progress row.
    let sql = """
      SELECT
        item.serverItemId AS serverItemId,
        episode.serverEpisodeId AS episodeID,
        episode.title AS episodeTitle,
        item.title AS itemTitle,
        item.author AS itemAuthor,
        CASE
          WHEN playbackBookmark.podcastEpisodeId IS NOT NULL THEN episode.durationSeconds
          ELSE item.durationSeconds
        END AS durationSeconds,
        mediaProgress.currentTime AS progressCurrentTime,
        mediaProgress.isFinished AS progressIsFinished,
        playbackBookmark.updatedAt AS updatedAt
      FROM playbackBookmark
      -- Not a catalogue projection: a bookmark reads the item it was stored against.
      JOIN item ON item.id = playbackBookmark.itemId AND item.softDeleted = 0
      LEFT JOIN podcastEpisode AS episode
        ON episode.id = playbackBookmark.podcastEpisodeId
        AND episode.itemId = playbackBookmark.itemId
        AND episode.accountId = playbackBookmark.accountId
        AND episode.softDeleted = 0
      LEFT JOIN mediaProgress
        ON mediaProgress.itemId = item.id
        AND mediaProgress.accountId = playbackBookmark.accountId
        AND mediaProgress.podcastEpisodeId IS playbackBookmark.podcastEpisodeId
      WHERE playbackBookmark.accountId = ?
        AND (
          playbackBookmark.podcastEpisodeId IS NULL
          OR episode.id IS NOT NULL
        )
      LIMIT 1
      """
    guard let row = try Row.fetchOne(db, sql: sql, arguments: [accountId]) else { return nil }
    let episodeID: String? = row["episodeID"]
    let episodeTitle: String? = row["episodeTitle"]
    let itemTitle: String = row["itemTitle"]
    let itemAuthor: String? = row["itemAuthor"]
    // A podcast bookmark projects the one episode display pair; a book keeps its own title/author.
    let displayTitle = episodeID.map { _ in
      EpisodeDisplayTitle(episodeTitle: episodeTitle, showTitle: itemTitle)
    }
    return (
      bookmark: PlaybackBookmark(
        serverItemId: row["serverItemId"],
        episodeID: episodeID,
        episodeTitle: episodeTitle,
        showTitle: displayTitle?.secondary,
        title: displayTitle?.primary ?? itemTitle,
        author: displayTitle?.secondary ?? itemAuthor,
        durationSeconds: row["durationSeconds"],
        positionSeconds: (row["progressCurrentTime"] as Double?) ?? 0,
        isFinished: (row["progressIsFinished"] as Bool?) ?? false),
      updatedAt: row["updatedAt"]
    )
  }

}
