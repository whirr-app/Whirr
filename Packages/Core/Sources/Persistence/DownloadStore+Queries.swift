import Foundation
import GRDB

extension DownloadStore {
  // MARK: - Queries

  public func fetch(downloadId: Int64) throws -> DownloadRecord? {
    try database.read { db in try DownloadRecord.fetchOne(db, key: downloadId) }
  }

  public func fetchAsync(downloadId: Int64) async throws -> DownloadRecord? {
    try await database.readAsync { db in try DownloadRecord.fetchOne(db, key: downloadId) }
  }

  /// Every download row for one item, ordered to reassemble playback order across files.
  public func fetchDownloads(itemId: Int64) throws -> [DownloadRecord] {
    try database.read { db in try Self.fetchDownloads(db, itemId: itemId) }
  }

  public func fetchDownloadsAsync(itemId: Int64) async throws -> [DownloadRecord] {
    try await database.readAsync { db in try Self.fetchDownloads(db, itemId: itemId) }
  }

  private static func fetchDownloads(_ db: Database, itemId: Int64) throws -> [DownloadRecord] {
    try DownloadRecord
      .filter(Column("itemId") == itemId)
      .order(Column("orderIndex"))
      .fetchAll(db)
  }

  /// Every row for one exact podcast episode. A sibling episode under the same show can never
  /// participate in episode-scoped pause/resume/purge decisions.
  public func fetchDownloads(
    itemId: Int64, podcastEpisodeId: Int64
  ) throws -> [DownloadRecord] {
    try database.read { db in
      try Self.fetchDownloads(db, itemId: itemId, podcastEpisodeId: podcastEpisodeId)
    }
  }

  public func fetchDownloadsAsync(
    itemId: Int64, podcastEpisodeId: Int64
  ) async throws -> [DownloadRecord] {
    try await database.readAsync { db in
      try Self.fetchDownloads(db, itemId: itemId, podcastEpisodeId: podcastEpisodeId)
    }
  }

  private static func fetchDownloads(
    _ db: Database, itemId: Int64, podcastEpisodeId: Int64
  ) throws -> [DownloadRecord] {
    try DownloadRecord
      .filter(Column("itemId") == itemId)
      .filter(Column("podcastEpisodeId") == podcastEpisodeId)
      .order(Column("orderIndex"))
      .fetchAll(db)
  }

  /// Every download row, across every account and item. The integrity sweep is directory-driven,
  /// so it needs the full row set to reconcile against what is on disk.
  public func fetchAll() throws -> [DownloadRecord] {
    try database.read { db in try DownloadRecord.fetchAll(db) }
  }

  public func fetchAllAsync() async throws -> [DownloadRecord] {
    try await database.readAsync { db in try DownloadRecord.fetchAll(db) }
  }

  /// The item's aggregate download state and progress fraction, derived in one query.
  /// `DefaultDownloadReading` wraps this same logic in a `ValueObservation`.
  public func aggregate(
    itemId: Int64, mediaKind: DownloadMediaKind? = nil
  ) throws -> DownloadAggregate {
    try database.read { db in try Self.aggregate(db, itemId: itemId, mediaKind: mediaKind) }
  }

  static func aggregate(
    _ db: Database, itemId: Int64, mediaKind: DownloadMediaKind? = nil
  ) throws -> DownloadAggregate {
    let rows: [DownloadRecord]
    if let mediaKind {
      rows =
        try DownloadRecord
        .filter(Column("itemId") == itemId)
        .filter(Column("mediaKind") == mediaKind.rawValue)
        .filter(Column("state") != DownloadState.deleting.rawValue)
        .fetchAll(db)
    } else {
      rows =
        try DownloadRecord
        .filter(Column("itemId") == itemId)
        .filter(sql: DownloadMediaKind.itemMediaSQL())
        .filter(Column("state") != DownloadState.deleting.rawValue)
        .fetchAll(db)
    }

    guard rows.isEmpty == false else {
      return DownloadAggregate(state: .none, progressFraction: 0)
    }
    if rows.allSatisfy({ $0.state == .completed }) {
      return DownloadAggregate(state: .complete, progressFraction: 1)
    }

    let totalExpected = rows.reduce(into: Int64(0)) { $0 += $1.expectedBytes }
    let totalReceived = rows.reduce(into: Int64(0)) { $0 += $1.receivedBytes }
    let fraction = totalExpected > 0 ? Double(totalReceived) / Double(totalExpected) : 0
    return DownloadAggregate(state: .partial, progressFraction: min(max(fraction, 0), 1))
  }

  // MARK: - Tombstoned-episode downloads

  /// Every download row whose podcast episode has been soft-deleted, oldest row first.
  ///
  /// A structurally complete refresh that no longer sees an episode soft-deletes it
  /// (`PodcastRefreshStore`), and the show screen lists only `softDeleted = 0` episodes, so a
  /// pulled episode's download loses its remove affordance while the file survives (a soft delete
  /// does not cascade, so `DownloadIntegritySweep` keeps its path).
  ///
  /// A query, not a purge: soft-deletion is a reversible inference (a later traversal can revive
  /// the row), so deleting audio on it could be wrong. Nor can it wait for a hard delete: episodes
  /// cascade away only with their whole `item`. The bytes are reported
  /// (`StorageAccounting.downloadedItems` attributes them as `tombstonedEpisodeBytes`) and
  /// reclaimed only by explicit intent (`DownloadCoordinator.purgeTombstonedEpisodeDownloads`),
  /// never a launch-time sweep.
  public func tombstonedEpisodeDownloads() throws -> [DownloadRecord] {
    try database.read { db in try Self.tombstonedEpisodeDownloads(db) }
  }

  public func tombstonedEpisodeDownloadsAsync() async throws -> [DownloadRecord] {
    try await database.readAsync { db in try Self.tombstonedEpisodeDownloads(db) }
  }

  static func tombstonedEpisodeDownloads(_ db: Database) throws -> [DownloadRecord] {
    try DownloadRecord.fetchAll(
      db,
      sql: """
        SELECT download.* FROM download
        JOIN podcastEpisode AS episode ON episode.id = download.podcastEpisodeId
        WHERE download.podcastEpisodeId IS NOT NULL AND \(EpisodeTombstoneSQL.server)
        ORDER BY download.id
        """)
  }
}

/// When a downloaded episode counts as removed from its show, for "Reclaim removed episodes" and
/// the Up Next decline that must flag exactly the entries that purge empties.
enum EpisodeTombstoneSQL {
  /// Over `podcastEpisode` aliased `episode`.
  static let server = "episode.softDeleted = 1"
  /// Over `rssEpisode` aliased `episode`, joined to `rssFeed` aliased `feed`.
  static let rss = "episode.retained = 1 AND episode.lastSeenGeneration < feed.refreshGeneration"
}
