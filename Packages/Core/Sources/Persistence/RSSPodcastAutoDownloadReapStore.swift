import Foundation
import GRDB

/// Retention candidates for device-owned RSS downloads. File deletion stays in the shared
/// `DownloadCoordinator`; this store supplies source-qualified identities only after applying
/// automatic-origin, completed-state, queue, and active-playback protections.
public struct RSSPodcastAutoDownloadReapStore: Sendable {
  private let database: AppDatabase
  private let activeEpisodeIDs: @Sendable () -> Set<Int64>

  public init(
    database: AppDatabase,
    accountId: Int64,
    activeEpisodeIDs: @escaping @Sendable () -> Set<Int64> = { [] }
  ) {
    self.database = database
    self.activeEpisodeIDs = activeEpisodeIDs
  }

  public init(database: AppDatabase, activeEpisodeIDs: @escaping @Sendable () -> Set<Int64> = { [] }) {
    self.database = database
    self.activeEpisodeIDs = activeEpisodeIDs
  }

  public func reapCandidates() async throws -> [EpisodeDownloadKey] {
    let active = activeEpisodeIDs()
    return try await database.readAsync { db in
      try Self.reapCandidates(
        db, activeEpisodeIDs: active)
    }
  }

  /// Returns a live active-playback predicate for the later deletion boundary. It invokes
  /// the tracker callback on every call rather than returning the selection snapshot.
  public func activePlaybackExclusion() -> @Sendable (Int64) -> Bool {
    let activeEpisodeIDs = self.activeEpisodeIDs
    return { episodeRowID in activeEpisodeIDs().contains(episodeRowID) }
  }

  private struct FeedSettings {
    let autoDownloadRaw: String
    let keepLatest: Int?
    let deleteAfterPlayed: Bool?
  }

  private static func reapCandidates(
    _ db: Database, activeEpisodeIDs: Set<Int64>
  ) throws -> [EpisodeDownloadKey] {
    let global =
      try NativePodcastSettingsRecord.fetchOne(db, key: NativePodcastSettingsRecord.singletonID)?.settings ?? .defaults
    let settings = try feedSettings(db)
    let rows = try Row.fetchAll(
      db,
      sql: """
        WITH episodeRank AS (
          SELECT id AS episodeId,
                 ROW_NUMBER() OVER (
                   PARTITION BY feedId
                   ORDER BY publishedAt DESC, identityKey ASC
                 ) AS rankInFeed
          FROM rssEpisode
        )
        SELECT episode.id AS episodeRowId, episode.feedId AS feedId,
               episode.identityKey AS episodeID, episode.publishedAt AS publishedAt,
               episodeRank.rankInFeed AS rankInFeed,
               COALESCE(state.finished, 0) AS isFinished
        FROM rssDownload AS download
        JOIN rssEpisode AS episode ON episode.id = download.episodeId
        JOIN rssFeed AS feed ON feed.id = episode.feedId
        JOIN episodeRank ON episodeRank.episodeId = episode.id
        LEFT JOIN rssEpisodeState AS state ON state.episodeId = episode.id
        WHERE download.origin = ? AND download.state = ?
          AND NOT EXISTS (
            SELECT 1 FROM rssListeningQueueEntry AS queue
            WHERE queue.rssEpisodeId = episode.id
          )
        ORDER BY feed.title COLLATE NOCASE, episode.publishedAt ASC, episode.identityKey ASC
        """,
      arguments: [
        DownloadOrigin.automatic.rawValue, DownloadState.completed.rawValue,
      ])

    return rows.compactMap { row in
      let episodeRowID: Int64 = row["episodeRowId"]
      guard activeEpisodeIDs.contains(episodeRowID) == false else { return nil }
      let feedID: Int64 = row["feedId"]
      let feedSettings = settings[feedID]
      let effective = PodcastEffectiveSettingsResolver.resolve(
        global: global,
        showOverride: PodcastShowAutoDownloadOverride.parse(
          feedSettings?.autoDownloadRaw
            ?? PodcastShowAutoDownloadOverride.inherit.rawValue),
        showKeepLatestOverride: feedSettings?.keepLatest,
        showDeleteAfterPlayedOverride: feedSettings?.deleteAfterPlayed,
        showEnabledAt: nil)
      let rankInFeed: Int = row["rankInFeed"]
      let isFinished: Bool = row["isFinished"]
      let outsideKeepLatest =
        effective.isEnabled && effective.keepLatestCount != 0
        && rankInFeed > effective.keepLatestCount
      let finishedAfterPlayed = effective.deleteAfterPlayed && isFinished
      guard outsideKeepLatest || finishedAfterPlayed else { return nil }
      let episodeID: String = row["episodeID"]
      return EpisodeDownloadKey(itemID: "rss:\(feedID)", episodeID: episodeID)
    }
  }

  private static func feedSettings(_ db: Database) throws -> [Int64: FeedSettings] {
    try Row.fetchAll(
      db,
      sql: "SELECT feedId, autoDownload, keepLatest, deleteAfterPlayed FROM rssFeedSettings"
    ).reduce(into: [:]) { result, row in
      let feedID: Int64 = row["feedId"]
      result[feedID] = FeedSettings(
        autoDownloadRaw: row["autoDownload"], keepLatest: row["keepLatest"],
        deleteAfterPlayed: row["deleteAfterPlayed"])
    }
  }

}
