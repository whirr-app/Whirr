import Foundation
import GRDB

public struct CrossSourceDownloadDeletionRows: Sendable {
  public let abs: [DownloadRecord]
  public let rss: [RSSDownloadRecord]

  public init(abs: [DownloadRecord], rss: [RSSDownloadRecord]) {
    self.abs = abs
    self.rss = rss
  }
}

extension DownloadStore {
  /// First step of a purge: marks every row of `itemId` not already `.deleting` as `.deleting` in
  /// one transaction, so the item is non-playable and non-schedulable before SyncEngine's purge
  /// coordinator touches a transfer or file. Returns each row's pre-transition snapshot (so the
  /// caller can cancel `.downloading` transfers), omitting already-`.deleting` rows. A crash after
  /// the commit is resumed by `DownloadIntegritySweep` on the next launch.
  @discardableResult
  public func markDeleting(itemId: Int64) throws -> [DownloadRecord] {
    try database.write { db in try Self.markDeleting(itemId: itemId, in: db) }
  }

  @discardableResult
  public func markDeletingAsync(itemId: Int64) async throws -> [DownloadRecord] {
    try await database.writeAsync { db in try Self.markDeleting(itemId: itemId, in: db) }
  }

  private static func markDeleting(itemId: Int64, in db: Database) throws -> [DownloadRecord] {
    try Self.markDeleting(DownloadRecord.filter(Column("itemId") == itemId).fetchAll(db), in: db)
  }

  /// Medium-scoped variant used by the ebook intent surface. Item-wide purge uses
  /// `markDeleting(itemId:)` above so it removes every medium belonging to the item.
  @discardableResult
  public func markDeleting(itemId: Int64, mediaKind: DownloadMediaKind) throws -> [DownloadRecord] {
    try database.write { db in
      try Self.markDeleting(itemId: itemId, mediaKind: mediaKind, in: db)
    }
  }

  @discardableResult
  public func markDeletingAsync(
    itemId: Int64, mediaKind: DownloadMediaKind
  ) async throws -> [DownloadRecord] {
    try await database.writeAsync { db in
      try Self.markDeleting(itemId: itemId, mediaKind: mediaKind, in: db)
    }
  }

  private static func markDeleting(
    itemId: Int64, mediaKind: DownloadMediaKind, in db: Database
  ) throws -> [DownloadRecord] {
    try Self.markDeleting(
      DownloadRecord
        .filter(Column("itemId") == itemId)
        .filter(Column("mediaKind") == mediaKind.rawValue)
        .fetchAll(db),
      in: db)
  }

  /// Episode-scoped variant of `markDeleting(itemId:)`; preserves every sibling row belonging
  /// to the same podcast show.
  @discardableResult
  public func markDeleting(
    itemId: Int64, podcastEpisodeId: Int64
  ) throws -> [DownloadRecord] {
    try database.write { db in
      try Self.markDeleting(itemId: itemId, podcastEpisodeId: podcastEpisodeId, in: db)
    }
  }

  @discardableResult
  public func markDeletingAsync(
    itemId: Int64, podcastEpisodeId: Int64
  ) async throws -> [DownloadRecord] {
    try await database.writeAsync { db in
      try Self.markDeleting(itemId: itemId, podcastEpisodeId: podcastEpisodeId, in: db)
    }
  }

  private static func markDeleting(
    itemId: Int64, podcastEpisodeId: Int64, in db: Database
  ) throws -> [DownloadRecord] {
    try Self.markDeleting(
      DownloadRecord
        .filter(Column("itemId") == itemId)
        .filter(Column("podcastEpisodeId") == podcastEpisodeId)
        .fetchAll(db),
      in: db)
  }

  /// The whole-store variant of `markDeleting(itemId:)`, for purge-all.
  @discardableResult
  public func markAllDeleting() throws -> [DownloadRecord] {
    try database.write { db in try Self.markAllDeleting(in: db) }
  }

  @discardableResult
  public func markAllDeletingAsync() async throws -> [DownloadRecord] {
    try await database.writeAsync { db in try Self.markAllDeleting(in: db) }
  }

  /// Atomically marks both download tables for Storage's cross-source Delete All. One transaction
  /// on the shared database stops actor reentrancy scheduling an RSS row between the ABS and RSS
  /// marks.
  public func markAllDeletingIncludingRSSAsync() async throws -> CrossSourceDownloadDeletionRows {
    try await database.writeAsync { db in
      let abs = try Self.markAllDeleting(in: db)
      let rssRows = try RSSDownloadRecord.fetchAll(db, sql: "SELECT * FROM rssDownload ORDER BY id")
      let rss = try Self.markRSSDeleting(rssRows, in: db)
      return CrossSourceDownloadDeletionRows(abs: abs, rss: rss)
    }
  }

  /// Atomically claims the ABS and RSS retained-episode sets for explicit reclamation.
  public func markTombstonedIncludingRSSAsync() async throws -> CrossSourceDownloadDeletionRows {
    try await database.writeAsync { db in
      let abs = try Self.markDeleting(Self.tombstonedEpisodeDownloads(db), in: db)
      let rssRows = try RSSDownloadRecord.fetchAll(
        db,
        sql: """
          SELECT download.* FROM rssDownload AS download
          JOIN rssEpisode AS episode ON episode.id = download.episodeId
          JOIN rssFeed AS feed ON feed.id = episode.feedId
          WHERE \(EpisodeTombstoneSQL.rss)
          ORDER BY download.id
          """)
      let rss = try Self.markRSSDeleting(rssRows, in: db)
      return CrossSourceDownloadDeletionRows(abs: abs, rss: rss)
    }
  }

  private static func markRSSDeleting(
    _ rows: [RSSDownloadRecord], in db: Database
  ) throws -> [RSSDownloadRecord] {
    var snapshots: [RSSDownloadRecord] = []
    for var row in rows where row.state != .deleting {
      snapshots.append(row)
      row.state = .deleting
      row.holdReason = nil
      row.errorCode = nil
      row.updatedAt = Date()
      try row.update(db)
    }
    return snapshots
  }

  private static func markAllDeleting(in db: Database) throws -> [DownloadRecord] {
    try Self.markDeleting(DownloadRecord.fetchAll(db), in: db)
  }

  /// Shared transactional core for the bulk purge entry points above. Every state has a
  /// `.deleting` edge in `legalTransitions`, so the guard never throws in practice. It keeps this
  /// in step with the single-row `transition` rather than trusting the matrix.
  private static func markDeleting(_ rows: [DownloadRecord], in db: Database) throws -> [DownloadRecord] {
    var preTransitionSnapshots: [DownloadRecord] = []
    for var row in rows where row.state != .deleting {
      guard legalTransitions[row.state]?.contains(.deleting) == true else {
        throw DownloadStoreError.illegalTransition(from: row.state, to: .deleting)
      }
      preTransitionSnapshots.append(row)
      row.holdReason = nil
      row.errorCategory = nil
      row.state = .deleting
      try row.update(db)
    }
    return preTransitionSnapshots
  }

  /// Row-removal half of recoverable deletion: mark `deleting` (an ordinary `transition`), delete
  /// the file idempotently, then delete the row (this method). Legal only from `deleting`, so it
  /// cannot remove a row before `DownloadFileStore` has finished with the file. A crash before
  /// this call leaves the row `deleting`, which `DownloadIntegritySweep` resumes on the next
  /// launch.
  public func finalizeDeletion(downloadId: Int64) throws {
    try database.write { db in try Self.finalizeDeletion(downloadId: downloadId, in: db) }
  }

  public func finalizeDeletionAsync(downloadId: Int64) async throws {
    try await database.writeAsync { db in
      try Self.finalizeDeletion(downloadId: downloadId, in: db)
    }
  }

  private static func finalizeDeletion(downloadId: Int64, in db: Database) throws {
    guard let record = try DownloadRecord.fetchOne(db, key: downloadId) else {
      throw DownloadStoreError.downloadNotFound(downloadId)
    }
    guard record.state == .deleting else {
      throw DownloadStoreError.finalizeDeletionRequiresDeletingState(downloadId)
    }
    _ = try record.delete(db)
  }
}
