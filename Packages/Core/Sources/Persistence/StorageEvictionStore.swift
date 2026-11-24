import Foundation
import GRDB

/// Candidate query and atomic claim boundary for the storage ceiling. Owns records and
/// protection predicates; never touches files, adapter tasks or scheduling.
public struct StorageEvictionStore: Sendable {
  private let database: AppDatabase
  private let accountId: Int64
  private let activeRSSExclusionProvider: @Sendable () -> Set<Int64>

  public init(
    database: AppDatabase, accountId: Int64, activeRSSEpisodeIDs: Set<Int64> = [],
    activeRSSExclusionProvider: @escaping @Sendable () -> Set<Int64> = { [] }
  ) {
    self.database = database
    self.accountId = accountId
    self.activeRSSExclusionProvider = {
      activeRSSEpisodeIDs.union(activeRSSExclusionProvider())
    }
  }

  /// Returns one candidate per audiobook or podcast-episode identity, in eviction order.
  public func fetchCandidates() async throws -> [StorageEvictionCandidate] {
    try await database.readAsync { db in
      try Self.fetchUnionCandidates(
        db, accountId: self.accountId, activeRSSExclusionIDs: self.activeRSSExclusionProvider())
    }
  }

  /// Selects identities until `targetBytes` of completed-byte candidates are covered, then
  /// revalidates all protections and marks every non-ebook row of those identities `.deleting` in
  /// this same write transaction. The returned rows are pre-mark, source-qualified snapshots,
  /// including the exact bytes that the caller may report as claimed.
  public func claimUnion(targetBytes: Int64) async throws -> [StorageEvictionClaimedRow] {
    guard targetBytes > 0 else { return [] }
    return try await database.writeAsync { db in
      let candidates = try Self.fetchUnionCandidates(
        db, accountId: self.accountId, activeRSSExclusionIDs: self.activeRSSExclusionProvider())
      var selected: [StorageEvictionCandidate] = []
      var projected: Int64 = 0
      for candidate in candidates {
        selected.append(candidate)
        projected += candidate.byteTotal
        if projected >= targetBytes { break }
      }
      var result: [StorageEvictionClaimedRow] = []
      for candidate in selected {
        if candidate.source == .rss {
          guard let id = candidate.downloadId,
            var row = try RSSDownloadRecord.fetchOne(db, key: id), row.state != .deleting,
            RSSDownloadStore.legalTransitions[row.state]?.contains(.deleting) == true
          else { continue }
          let snapshot = StorageEvictionClaimedRow(
            identity: candidate.identity, downloadId: id, podcastEpisodeId: candidate.podcastEpisodeId,
            bytes: row.actualBytes, state: row.state, holdReason: row.holdReason?.rawValue)
          row.state = .deleting
          row.holdReason = nil
          row.errorCode = nil
          try row.update(db)
          result.append(snapshot)
        } else {
          let rows = try Self.downloadRows(db, accountId: self.accountId, identity: candidate.identity)
          for var row in rows {
            guard let id = row.id, DownloadStore.legalTransitions[row.state]?.contains(.deleting) == true else {
              continue
            }
            let snapshot = StorageEvictionClaimedRow(
              identity: candidate.identity, downloadId: id, podcastEpisodeId: row.podcastEpisodeId,
              bytes: row.receivedBytes, state: row.state, holdReason: row.holdReason?.rawValue)
            row.state = .deleting
            row.holdReason = nil
            row.errorCategory = nil
            try row.update(db)
            result.append(snapshot)
          }
        }
      }
      return result
    }
  }

  // MARK: - Candidate query

  private struct RawCandidate {
    let itemId: Int64
    let podcastEpisodeId: Int64?
    let isFinished: Bool
    let lastActivityAt: Date?
    let byteTotal: Int64
    let isTombstoned: Bool
    let episodeRank: Int?
    let global: PodcastGlobalSettings
    let showOverride: PodcastShowAutoDownloadOverride
    let showKeepLatestOverride: Int?
    let showDeleteAfterPlayedOverride: Bool?
    let showEnabledAt: Date?
  }

  private static func fetchUnionCandidates(
    _ db: Database, accountId: Int64, activeRSSExclusionIDs: Set<Int64>
  ) throws -> [StorageEvictionCandidate] {
    let abs = try fetchCandidates(db, accountId: accountId)
    let rss = try fetchRSSCandidates(
      db, accountId: accountId, activeRSSExclusionIDs: activeRSSExclusionIDs)
    return (abs + rss).sorted { lhs, rhs in
      let l = [
        lhs.isTombstoned ? 0 : 1, lhs.isFinished ? 0 : 1,
        lhs.lastActivityAt == nil ? 1 : 0,
      ]
      let r = [
        rhs.isTombstoned ? 0 : 1, rhs.isFinished ? 0 : 1,
        rhs.lastActivityAt == nil ? 1 : 0,
      ]
      if l != r { return l.lexicographicallyPrecedes(r) }
      switch (lhs.lastActivityAt, rhs.lastActivityAt) {
      case (let left?, let right?) where left != right: return left < right
      case (nil, nil): break
      case (nil, _?): return false
      case (_?, nil): return true
      default: break
      }
      if lhs.itemId != rhs.itemId { return lhs.itemId < rhs.itemId }
      if lhs.podcastEpisodeId != rhs.podcastEpisodeId {
        return (lhs.podcastEpisodeId ?? 0) < (rhs.podcastEpisodeId ?? 0)
      }
      return lhs.source.rawValue < rhs.source.rawValue
    }
  }

  private static func fetchRSSCandidates(
    _ db: Database, accountId: Int64, activeRSSExclusionIDs: Set<Int64>
  ) throws -> [StorageEvictionCandidate] {
    let nativeKeepLatest = try NativePodcastSettingsRecord.fetchOne(db, key: 1)?.keepLatestCount ?? 3
    let rows = try Row.fetchAll(
      db,
      sql: """
        WITH episodeRanks AS (
          SELECT id AS episodeId,
                 ROW_NUMBER() OVER (
                   PARTITION BY feedId ORDER BY publishedAt DESC, id ASC
                 ) AS episodeRank
          FROM rssEpisode
        )
        SELECT download.id AS downloadId, download.episodeId AS episodeId,
               download.actualBytes AS actualBytes, download.state AS downloadState,
               download.holdReason AS holdReason, episode.feedId AS feedId,
               episode.publishedAt AS publishedAt, COALESCE(state.finished, 0) AS isFinished,
               state.updatedAt AS lastActivityAt, settings.keepLatest AS keepLatest,
               episodeRanks.episodeRank AS episodeRank,
               (episode.lastSeenGeneration != feed.refreshGeneration) AS isTombstoned
        FROM rssDownload AS download
        JOIN rssEpisode AS episode ON episode.id = download.episodeId
        JOIN episodeRanks ON episodeRanks.episodeId = episode.id
        JOIN rssFeed AS feed ON feed.id = episode.feedId
        LEFT JOIN rssEpisodeState AS state ON state.episodeId = episode.id
        LEFT JOIN rssFeedSettings AS settings ON settings.feedId = episode.feedId
        WHERE download.state != ? AND download.state = ?
          AND NOT EXISTS (
            SELECT 1 FROM rssListeningQueueEntry q
            WHERE q.rssEpisodeId = episode.id
          )
          -- An unfinished episode a smart list claimed. Without this the ceiling evicts
          -- what the list just requested and the next pass requests it again.
          AND NOT (
            COALESCE(state.finished, 0) = 0
            AND EXISTS (
              SELECT 1 FROM smartListDownloadClaim AS claim
              WHERE claim.itemID = 'rss:' || episode.feedId
                AND claim.episodeID = episode.identityKey
            )
          )
        ORDER BY episode.feedId, episode.publishedAt DESC, episode.id ASC
        """,
      arguments: [
        DownloadState.deleting.rawValue, DownloadState.completed.rawValue,
      ])

    var ranks: [Int64: Int] = [:]
    var result: [StorageEvictionCandidate] = []
    for row in rows {
      let episodeId: Int64 = row["episodeId"]
      if activeRSSExclusionIDs.contains(episodeId) { continue }
      let feedId: Int64 = row["feedId"]
      ranks[feedId, default: 0] += 1
      let keepLatest: Int = row["keepLatest"] ?? nativeKeepLatest
      let episodeRank: Int = row["episodeRank"] ?? ranks[feedId]!
      guard keepLatest == 0 || episodeRank > keepLatest else { continue }
      result.append(
        StorageEvictionCandidate(
          itemId: feedId, podcastEpisodeId: episodeId,
          isFinished: (row["isFinished"] as Int64? ?? 0) != 0,
          lastActivityAt: row["lastActivityAt"], byteTotal: row["actualBytes"],
          isTombstoned: (row["isTombstoned"] as Bool?) ?? false,
          source: .rss, downloadId: row["downloadId"]))
    }
    return result
  }

  private static func fetchCandidates(
    _ db: Database, accountId: Int64
  ) throws -> [StorageEvictionCandidate] {
    let rows = try Row.fetchAll(
      db,
      sql: """
        WITH episodeRank AS (
          SELECT
            id AS episodeId,
            ROW_NUMBER() OVER (
              PARTITION BY itemId
              ORDER BY publishedAt DESC, serverEpisodeId ASC
            ) AS episodeRank
          FROM podcastEpisode
          WHERE accountId = ? AND softDeleted = 0
        ), downloadIdentity AS (
          SELECT
            accountId,
            itemId,
            podcastEpisodeId,
            SUM(CASE WHEN state = ? THEN receivedBytes ELSE 0 END) AS completedBytes,
            MAX(CASE WHEN state = ? THEN 1 ELSE 0 END) AS hasCompleted
          FROM download
          WHERE accountId = ?
            AND state != ?
            AND mediaKind != ?
          GROUP BY accountId, itemId, podcastEpisodeId
        )
        SELECT
          identity.itemId AS itemId,
          identity.podcastEpisodeId AS podcastEpisodeId,
          identity.completedBytes AS completedBytes,
          COALESCE(progress.isFinished, 0) AS isFinished,
          progress.lastActivityAt AS lastActivityAt,
          COALESCE(episode.softDeleted, 0) AS isTombstoned,
          episodeRank.episodeRank AS episodeRank,
          COALESCE(globalSettings.autoDownloadEnabled, 0) AS globalAutoDownloadEnabled,
          COALESCE(globalSettings.keepLatestCount, 3) AS globalKeepLatestCount,
          COALESCE(globalSettings.deleteAfterPlayed, 0) AS globalDeleteAfterPlayed,
          globalSettings.enabledAt AS globalEnabledAt,
          COALESCE(showSettings.autoDownloadOverride, 'inherit') AS showAutoDownloadOverride,
          showSettings.keepLatestOverride AS showKeepLatestOverride,
          showSettings.deleteAfterPlayedOverride AS showDeleteAfterPlayedOverride,
          showSettings.enabledAt AS showEnabledAt
        FROM downloadIdentity AS identity
        JOIN item
          ON item.id = identity.itemId
          AND item.accountId = identity.accountId
        LEFT JOIN podcastEpisode AS episode
          ON episode.id = identity.podcastEpisodeId
          AND episode.itemId = identity.itemId
          AND episode.accountId = identity.accountId
        LEFT JOIN episodeRank
          ON episodeRank.episodeId = identity.podcastEpisodeId
        LEFT JOIN mediaProgress AS progress
          ON progress.accountId = identity.accountId
          AND progress.itemId = identity.itemId
          AND (
            (identity.podcastEpisodeId IS NULL AND progress.podcastEpisodeId IS NULL)
            OR (
              identity.podcastEpisodeId IS NOT NULL
              AND progress.podcastEpisodeId = identity.podcastEpisodeId
            )
          )
        LEFT JOIN podcastSettings AS globalSettings
          ON globalSettings.accountId = identity.accountId
        LEFT JOIN podcastShowSettings AS showSettings
          ON showSettings.accountId = identity.accountId
          AND showSettings.itemId = identity.itemId
        WHERE identity.hasCompleted = 1
          AND NOT EXISTS (
            SELECT 1
            FROM download AS inFlight
            WHERE inFlight.accountId = identity.accountId
              AND inFlight.itemId = identity.itemId
              AND (
                (
                  identity.podcastEpisodeId IS NULL
                  AND inFlight.podcastEpisodeId IS NULL
                )
                OR (
                  identity.podcastEpisodeId IS NOT NULL
                  AND inFlight.podcastEpisodeId = identity.podcastEpisodeId
                )
              )
              AND inFlight.state IN (?, ?, ?, ?, ?)
              -- A Wi-Fi-held supplement PDF must not pin its audiobook on disk.
              AND \(DownloadMediaKind.itemMediaSQL("inFlight"))
          )
          AND NOT EXISTS (
            SELECT 1
            FROM playbackSession AS playing
            WHERE playing.accountId = identity.accountId
              AND playing.state = ?
              AND (
                (
                  identity.podcastEpisodeId IS NULL
                  AND playing.itemId = identity.itemId
                  AND playing.podcastEpisodeId IS NULL
                )
                OR (
                  identity.podcastEpisodeId IS NOT NULL
                  AND playing.podcastEpisodeId = identity.podcastEpisodeId
                )
              )
          )
          AND NOT EXISTS (
            SELECT 1
            FROM listeningQueueEntry AS queued
            WHERE queued.accountId = identity.accountId
              AND (
                (
                  identity.podcastEpisodeId IS NULL
                  AND queued.itemId = identity.itemId
                  AND queued.podcastEpisodeId IS NULL
                )
                OR (
                  identity.podcastEpisodeId IS NOT NULL
                  AND queued.podcastEpisodeId = identity.podcastEpisodeId
                )
              )
          )
          -- An unfinished member of a stored pinned list. Without this the pin's
          -- reconciler would re-request what the ceiling had just evicted, indefinitely.
          AND NOT (
            COALESCE(progress.isFinished, 0) = 0
            AND EXISTS (
              SELECT 1
              FROM pinnedList AS pin
              JOIN library AS pinLibrary
                ON pinLibrary.accountId = pin.accountId
                AND pinLibrary.serverLibraryId = pin.serverLibraryId
                AND pinLibrary.softDeleted = 0 AND pinLibrary.isIncluded = 1
              JOIN libraryCollection AS pinList
                ON pinList.libraryId = pinLibrary.id
                AND pinList.kind = pin.kind AND pinList.serverId = pin.serverId
              JOIN libraryCollectionMember AS pinMember ON pinMember.collectionId = pinList.id
              WHERE pin.accountId = identity.accountId
                AND pinList.libraryId = item.libraryId
                AND pinMember.serverItemId = item.serverItemId
                AND (
                  (identity.podcastEpisodeId IS NULL AND pinMember.serverEpisodeId IS NULL)
                  OR (
                    identity.podcastEpisodeId IS NOT NULL
                    AND pinMember.serverEpisodeId = episode.serverEpisodeId
                  )
                )
            )
          )
          -- An unfinished episode a smart list claimed, for the same reason.
          AND NOT (
            COALESCE(progress.isFinished, 0) = 0
            AND identity.podcastEpisodeId IS NOT NULL
            AND EXISTS (
              SELECT 1
              FROM smartListDownloadClaim AS claim
              WHERE claim.accountId = identity.accountId
                AND claim.itemID = item.serverItemId
                AND claim.episodeID = episode.serverEpisodeId
            )
          )
        ORDER BY
          isTombstoned DESC,
          isFinished DESC,
          (lastActivityAt IS NULL) ASC,
          lastActivityAt ASC,
          itemId ASC,
          podcastEpisodeId ASC
        """,
      arguments: [
        accountId,
        DownloadState.completed.rawValue,
        DownloadState.completed.rawValue,
        accountId,
        DownloadState.deleting.rawValue,
        DownloadMediaKind.ebook.rawValue,
        DownloadState.pending.rawValue,
        DownloadState.downloading.rawValue,
        DownloadState.paused.rawValue,
        DownloadState.pausedAuth.rawValue,
        DownloadState.interrupted.rawValue,
        PlaybackSessionState.active.rawValue,
      ])

    let rawCandidates = rows.map { row in
      RawCandidate(
        itemId: row["itemId"],
        podcastEpisodeId: row["podcastEpisodeId"],
        isFinished: row["isFinished"],
        lastActivityAt: row["lastActivityAt"],
        byteTotal: row["completedBytes"],
        isTombstoned: row["isTombstoned"],
        episodeRank: row["episodeRank"],
        global: PodcastGlobalSettings(
          autoDownloadEnabled: row["globalAutoDownloadEnabled"],
          keepLatestCount: row["globalKeepLatestCount"],
          deleteAfterPlayed: row["globalDeleteAfterPlayed"],
          allowCellularAutoDownload: false,
          enabledAt: row["globalEnabledAt"]),
        showOverride: PodcastShowAutoDownloadOverride.parse(
          row["showAutoDownloadOverride"]),
        showKeepLatestOverride: row["showKeepLatestOverride"],
        showDeleteAfterPlayedOverride: row["showDeleteAfterPlayedOverride"],
        showEnabledAt: row["showEnabledAt"])
    }

    return rawCandidates.compactMap { raw in
      let effective = PodcastEffectiveSettingsResolver.resolve(
        global: raw.global,
        showOverride: raw.showOverride,
        showKeepLatestOverride: raw.showKeepLatestOverride,
        showDeleteAfterPlayedOverride: raw.showDeleteAfterPlayedOverride,
        showEnabledAt: raw.showEnabledAt)
      let isInsideKeepLatestWindow =
        raw.podcastEpisodeId != nil
        && effective.isEnabled
        && effective.keepLatestCount != 0
        && raw.episodeRank.map { $0 <= effective.keepLatestCount } == true
      guard isInsideKeepLatestWindow == false else { return nil }
      return StorageEvictionCandidate(
        itemId: raw.itemId,
        podcastEpisodeId: raw.podcastEpisodeId,
        isFinished: raw.isFinished,
        lastActivityAt: raw.lastActivityAt,
        byteTotal: raw.byteTotal,
        isTombstoned: raw.isTombstoned)
    }
  }

  private static func downloadRows(
    _ db: Database, accountId: Int64, identity: StorageEvictionIdentity
  ) throws -> [DownloadRecord] {
    if let episodeId = identity.podcastEpisodeId {
      return try DownloadRecord.fetchAll(
        db,
        sql: """
          SELECT * FROM download
          WHERE accountId = ? AND itemId = ? AND podcastEpisodeId = ?
            AND state != ? AND mediaKind != ?
          ORDER BY id ASC
          """,
        arguments: [
          accountId, identity.itemId, episodeId, DownloadState.deleting.rawValue,
          DownloadMediaKind.ebook.rawValue,
        ])
    }
    return try DownloadRecord.fetchAll(
      db,
      sql: """
        SELECT * FROM download
        WHERE accountId = ? AND itemId = ? AND podcastEpisodeId IS NULL
          AND state != ? AND mediaKind != ?
        ORDER BY id ASC
        """,
      arguments: [
        accountId, identity.itemId, DownloadState.deleting.rawValue,
        DownloadMediaKind.ebook.rawValue,
      ])
  }
}

extension StorageEvictionStore: StorageEvictionClaiming {}
