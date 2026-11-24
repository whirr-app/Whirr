import Foundation
import GRDB

/// The retention query: which automatic-origin, completed download rows are reapable under
/// keep-latest-N and/or delete-after-played. Returns plain identities; never deletes a file or
/// row nor touches `podcastEpisode.autoDownloadDecidedAt`. The caller
/// (`PodcastAutoDownloadReaper`) forwards each to
/// `DownloadIntents.purgeEpisodeDownload(itemID:episodeID:source:)`.
///
/// Each show's settings resolve through `PodcastEffectiveSettingsResolver.resolve` over its own
/// raw `podcastSettings`/`podcastShowSettings` reads, as `PodcastSettingsStore` does.
/// `showEnabledAt` is always `nil`: retention never reads `.floor`, the only thing it feeds.
public struct PodcastAutoDownloadReapStore: Sendable {
  private let database: AppDatabase
  private let accountId: Int64

  public init(database: AppDatabase, accountId: Int64) {
    self.database = database
    self.accountId = accountId
  }

  /// Every automatic-origin, completed download whose episode currently satisfies at least one
  /// retention policy and none of the exclusions. Deterministic order: per show (`sortTitle`),
  /// oldest `publishedAt` first, tiebroken by `serverEpisodeId`.
  public func reapCandidates() async throws -> [EpisodeDownloadKey] {
    try await database.readAsync { db in try Self.reapCandidates(db, accountId: self.accountId) }
  }

  static func reapCandidates(_ db: Database, accountId: Int64) throws -> [EpisodeDownloadKey] {
    let global = try globalSettings(db, accountId: accountId)
    let overrides = try showOverrideRows(db, accountId: accountId)
    var effectiveByItemRowId: [Int64: PodcastEffectiveSettings] = [:]

    return try candidateRows(db, accountId: accountId).compactMap { row -> EpisodeDownloadKey? in
      let effective =
        effectiveByItemRowId[row.itemRowId]
        ?? {
          let resolved = resolveEffective(itemRowId: row.itemRowId, global: global, overrides: overrides)
          effectiveByItemRowId[row.itemRowId] = resolved
          return resolved
        }()

      // Keep-latest: only while the show is effectively enabled, and never when it resolves to
      // "keep all". Delete-after-played applies regardless of the enabled state.
      let outsideKeepLatestWindow =
        effective.isEnabled && effective.keepLatestCount != 0 && row.rank > effective.keepLatestCount
      let finishedUnderDeleteAfterPlayed = effective.deleteAfterPlayed && row.isFinished

      guard outsideKeepLatestWindow || finishedUnderDeleteAfterPlayed else { return nil }
      return EpisodeDownloadKey(itemID: row.itemID, episodeID: row.episodeID)
    }
  }

  // MARK: - Internals

  private struct CandidateRow {
    let itemRowId: Int64
    let itemID: String
    let episodeID: String
    let rank: Int
    let isFinished: Bool
  }

  /// Every live automatic-origin completed download row, joined to its episode's rank within its
  /// show's live-episode window (publishedAt DESC, `serverEpisodeId` ascending tiebreak, the same
  /// window `PodcastAutoDownloadSelectionStore` uses) and to its episode-level `mediaProgress`,
  /// with every exclusion (an active playback session, an Up Next entry) already applied.
  /// Ordered per show, oldest `publishedAt` first.
  private static func candidateRows(_ db: Database, accountId: Int64) throws -> [CandidateRow] {
    let sql = """
      WITH liveEpisodeRank AS (
        SELECT
          id AS episodeId,
          itemId,
          ROW_NUMBER() OVER (
            PARTITION BY itemId
            ORDER BY publishedAt DESC, serverEpisodeId ASC
          ) AS rank
        FROM podcastEpisode
        WHERE accountId = ? AND softDeleted = 0
      )
      SELECT DISTINCT
        item.id AS itemRowId,
        item.serverItemId AS itemID,
        item.sortTitle AS sortTitle,
        episode.serverEpisodeId AS episodeID,
        episode.publishedAt AS publishedAt,
        liveEpisodeRank.rank AS rank,
        COALESCE(progress.isFinished, 0) AS isFinished
      FROM download
      JOIN podcastEpisode AS episode ON episode.id = download.podcastEpisodeId
      JOIN item ON item.id = download.itemId
      JOIN liveEpisodeRank ON liveEpisodeRank.episodeId = episode.id
      LEFT JOIN mediaProgress AS progress
        ON progress.podcastEpisodeId = episode.id
        AND progress.accountId = download.accountId
      WHERE download.accountId = ?
        AND download.origin = ?
        AND download.state = ?
        AND NOT EXISTS (
          SELECT 1 FROM playbackSession
          WHERE playbackSession.podcastEpisodeId = episode.id
            AND playbackSession.accountId = download.accountId
            AND playbackSession.state = ?
        )
        AND NOT EXISTS (
          SELECT 1 FROM listeningQueueEntry
          WHERE listeningQueueEntry.podcastEpisodeId = episode.id
            AND listeningQueueEntry.accountId = download.accountId
        )
      ORDER BY item.sortTitle, episode.publishedAt ASC, episode.serverEpisodeId ASC
      """
    let rows = try Row.fetchAll(
      db,
      sql: sql,
      arguments: [
        accountId,
        accountId,
        DownloadOrigin.automatic.rawValue,
        DownloadState.completed.rawValue,
        PlaybackSessionState.active.rawValue,
      ])
    return rows.map { row in
      CandidateRow(
        itemRowId: row["itemRowId"],
        itemID: row["itemID"],
        episodeID: row["episodeID"],
        rank: row["rank"],
        isFinished: row["isFinished"])
    }
  }

  /// Mirrors `PodcastSettingsStore`'s raw-column shape for a show's stored override. Not decoded
  /// into `PodcastShowSettingsRecord`, whose `FetchableRecord` conformance throws on an
  /// unrecognised `autoDownloadOverride` string instead of failing closed.
  private struct ShowOverrideRow {
    var autoDownloadOverrideRaw: String
    var keepLatestOverride: Int?
    var deleteAfterPlayedOverride: Bool?
  }

  private static func globalSettings(_ db: Database, accountId: Int64) throws -> PodcastGlobalSettings {
    guard let record = try PodcastSettingsRecord.fetchOne(db, key: accountId) else {
      return .defaults
    }
    return PodcastGlobalSettings(
      autoDownloadEnabled: record.autoDownloadEnabled,
      keepLatestCount: record.keepLatestCount,
      deleteAfterPlayed: record.deleteAfterPlayed,
      allowCellularAutoDownload: record.allowCellularAutoDownload,
      enabledAt: record.enabledAt)
  }

  /// Every show-override row for this account, keyed by `itemId`. A show absent from the result
  /// means "inherit", so no backfill is needed.
  private static func showOverrideRows(_ db: Database, accountId: Int64) throws
    -> [Int64: ShowOverrideRow]
  {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT itemId, autoDownloadOverride, keepLatestOverride, deleteAfterPlayedOverride
        FROM podcastShowSettings
        WHERE accountId = ?
        """,
      arguments: [accountId])
    return rows.reduce(into: [:]) { result, row in
      let itemId: Int64 = row["itemId"]
      result[itemId] = ShowOverrideRow(
        autoDownloadOverrideRaw: row["autoDownloadOverride"],
        keepLatestOverride: row["keepLatestOverride"],
        deleteAfterPlayedOverride: row["deleteAfterPlayedOverride"])
    }
  }

  private static func resolveEffective(
    itemRowId: Int64,
    global: PodcastGlobalSettings,
    overrides: [Int64: ShowOverrideRow]
  ) -> PodcastEffectiveSettings {
    let row = overrides[itemRowId]
    let override = PodcastShowAutoDownloadOverride.parse(
      row?.autoDownloadOverrideRaw ?? PodcastShowAutoDownloadOverride.inherit.rawValue)
    return PodcastEffectiveSettingsResolver.resolve(
      global: global,
      showOverride: override,
      showKeepLatestOverride: row?.keepLatestOverride ?? nil,
      showDeleteAfterPlayedOverride: row?.deleteAfterPlayedOverride ?? nil,
      showEnabledAt: nil)
  }
}
