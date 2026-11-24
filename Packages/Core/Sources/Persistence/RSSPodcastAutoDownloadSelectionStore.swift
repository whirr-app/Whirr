import Foundation
import GRDB

/// Device-owned RSS selection for the shared automatic-download coordinator. The coordinator
/// owns authentication/network/low-disk gates and the 5-per-feed/20-per-pass policy; this store
/// owns only deterministic eligibility and settings resolution.
public struct RSSPodcastAutoDownloadSelectionStore: Sendable {
  private let database: AppDatabase
  private let now: @Sendable () -> Date

  public init(
    database: AppDatabase,
    accountId: Int64,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.database = database
    _ = accountId
    self.now = now
  }

  public init(database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
    self.database = database
    self.now = now
  }

  public func fetchCandidates(
    maxPerShow: Int, maxPerPass: Int
  ) async throws -> [PodcastAutoDownloadCandidate] {
    try await database.readAsync { db in
      try Self.candidates(
        db, maxPerFeed: maxPerShow, maxPerPass: maxPerPass)
    }
  }

  /// Stamps the episode and its download row after planning. The claim also stamps the episode
  /// atomically, so a crash before this update cannot leave the episode eligible forever.
  public func markDecided(itemID: String, episodeID: String) async throws {
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else { return }
    let stamp = now()
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE rssEpisode
          SET autoDownloadDecidedAt = ?
          WHERE feedId = ? AND identityKey = ?
          """,
        arguments: [stamp, feedID, episodeID])
      try db.execute(
        sql: """
          UPDATE rssDownload
          SET decidedStamp = ?, updatedAt = ?
          WHERE origin = ? AND episodeId = (
            SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?
          )
          """,
        arguments: [
          stamp, stamp, DownloadOrigin.automatic.rawValue, feedID, episodeID,
        ])
    }
  }

  /// No repair write is required: the episode stamp is created in the same transaction as the
  /// automatic claim, and v62 backfills claims made by earlier schemas.
  public func repairDecidedStamps() async throws -> Int { 0 }

  private struct FeedSettings {
    let autoDownloadRaw: String
    let keepLatest: Int?
    let deleteAfterPlayed: Bool?
  }

  private static func candidates(
    _ db: Database, maxPerFeed: Int, maxPerPass: Int
  ) throws -> [PodcastAutoDownloadCandidate] {
    let global =
      try NativePodcastSettingsRecord.fetchOne(db, key: NativePodcastSettingsRecord.singletonID)?.settings ?? .defaults
    let settings = try feedSettings(db)
    let rows = try Row.fetchAll(
      db,
      sql: """
        WITH liveEpisodeRank AS (
          SELECT episode.id AS episodeId,
                 ROW_NUMBER() OVER (
                   PARTITION BY episode.feedId
                   ORDER BY episode.publishedAt DESC, episode.identityKey ASC
                 ) AS rankInFeed
          FROM rssEpisode AS episode
          JOIN rssFeed AS feed ON feed.id = episode.feedId
          WHERE episode.lastSeenGeneration = feed.refreshGeneration
        )
        SELECT episode.id AS episodeRowId, episode.feedId AS feedId,
               episode.identityKey AS episodeID, episode.publishedAt AS publishedAt,
               liveEpisodeRank.rankInFeed AS rankInFeed,
               COALESCE(state.finished, 0) AS isFinished
        FROM rssEpisode AS episode
        JOIN rssFeed AS feed ON feed.id = episode.feedId
        JOIN liveEpisodeRank ON liveEpisodeRank.episodeId = episode.id
        LEFT JOIN rssEpisodeState AS state ON state.episodeId = episode.id
        WHERE episode.publishedAt IS NOT NULL
          AND episode.lastSeenGeneration = feed.refreshGeneration
          AND COALESCE(state.finished, 0) = 0
          AND episode.autoDownloadDecidedAt IS NULL
          AND NOT EXISTS (
            SELECT 1 FROM rssDownload WHERE rssDownload.episodeId = episode.id
          )
        ORDER BY episode.publishedAt DESC, episode.identityKey ASC
        """)

    var perFeedCount: [Int64: Int] = [:]
    var result: [PodcastAutoDownloadCandidate] = []
    for row in rows {
      guard result.count < max(0, maxPerPass) else { break }
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
      let publishedAt: Date = row["publishedAt"]
      let rankInFeed: Int = row["rankInFeed"]
      guard effective.isEnabled, publishedAt > effective.floor else { continue }
      guard effective.keepLatestCount == 0 || rankInFeed <= effective.keepLatestCount else {
        continue
      }
      guard perFeedCount[feedID, default: 0] < max(0, maxPerFeed) else { continue }
      perFeedCount[feedID, default: 0] += 1
      let episodeID: String = row["episodeID"]
      result.append(
        PodcastAutoDownloadCandidate(
          itemID: "rss:\(feedID)", episodeID: episodeID, publishedAt: publishedAt))
    }
    return result
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
