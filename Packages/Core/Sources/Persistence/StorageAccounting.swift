import Foundation
import GRDB

/// Purgeable on-disk download totals only. The cover cache is always disposable and never
/// counted; this only sums `download` rows. Mirrors `DownloadAggregate`'s read-only, UI-facing
/// projection shape.
public struct StorageTotals: Sendable, Equatable {
  public let totalBytes: Int64

  public init(totalBytes: Int64) {
    self.totalBytes = totalBytes
  }
}

/// The source of a downloaded show/item. `.abs` is the default, so ABS callers stay
/// source-compatible while RSS rows carry an explicit tag.
public enum DownloadedItemSource: String, Codable, Sendable, Equatable {
  case abs
  case rss
}

/// One item that has download rows on this device, with its purgeable byte total. The storage
/// screen's row source. Not derived from the library catalog: listing every synced item at zero
/// bytes would offer a delete action for files that were never downloaded, which
/// `StorageReading.observeDownloadedItems()` exists to prevent.
public struct DownloadedItemTotals: Sendable, Equatable, Identifiable {
  public var id: String { itemId }
  /// The server item id, which every AppModel-facing boundary is keyed by.
  public let itemId: String
  public let title: String
  /// Feed author for RSS rows; `nil` for ABS rows unless a caller supplies one.
  public let author: String?
  public let source: DownloadedItemSource
  public let totalBytes: Int64
  /// The share of `totalBytes` (not additional to it) stranded behind a soft-deleted podcast
  /// episode; see `DownloadStore.tombstonedEpisodeDownloads` for why those rows are kept. Lets a
  /// storage screen call the bytes reclaimable although the episode is hidden. `0` for audiobooks
  /// and shows with no tombstoned episode.
  public let tombstonedEpisodeBytes: Int64

  /// Source-compatible initializer for ABS callers.
  public init(itemId: String, title: String, totalBytes: Int64, tombstonedEpisodeBytes: Int64 = 0) {
    self.init(
      itemId: itemId, title: title, totalBytes: totalBytes,
      tombstonedEpisodeBytes: tombstonedEpisodeBytes, author: nil, source: .abs)
  }

  public init(
    itemId: String, title: String, totalBytes: Int64, tombstonedEpisodeBytes: Int64 = 0,
    author: String?, source: DownloadedItemSource
  ) {
    self.itemId = itemId
    self.title = title
    self.author = author
    self.source = source
    self.totalBytes = totalBytes
    self.tombstonedEpisodeBytes = tombstonedEpisodeBytes
  }
}

/// The account's download bytes split by what they are, for the storage screens' bar.
///
/// Counts what `StorageTotals` counts for the account (every row not `.deleting`, at
/// `receivedBytes` or `actualBytes`), so `totalBytes` equals the figure printed beside the bar.
public struct StorageBreakdown: Sendable, Equatable {
  public let audiobookBytes: Int64
  public let podcastBytes: Int64
  /// Ebooks, and the PDFs that accompany audiobooks.
  public let documentBytes: Int64

  public init(audiobookBytes: Int64 = 0, podcastBytes: Int64 = 0, documentBytes: Int64 = 0) {
    self.audiobookBytes = audiobookBytes
    self.podcastBytes = podcastBytes
    self.documentBytes = documentBytes
  }

  public var totalBytes: Int64 { audiobookBytes + podcastBytes + documentBytes }
}

/// Per-item and whole-account purgeable storage accounting, read-only over `DownloadStore`.
/// A pure DB sum, never a filesystem walk: `DownloadStore.complete` verifies `receivedBytes`
/// against the on-disk size before a row is `completed` (`DownloadFileStore.completeTransfer`).
/// Every row not `.deleting` counts: completed rows at their verified size, every other live
/// state (`pending`/`downloading`/`paused`/`pausedAuth`/`interrupted`/`failed`) at its
/// `receivedBytes` so far (0 if none). `.deleting` rows are mid-removal and not purgeable
/// (`DownloadStore.aggregate` excludes them too).
public struct StorageAccounting: Sendable {
  private let downloadStore: DownloadStore
  private let rssDownloadStore: RSSDownloadStore?

  public init(downloadStore: DownloadStore, rssDownloadStore: RSSDownloadStore? = nil) {
    self.downloadStore = downloadStore
    self.rssDownloadStore = rssDownloadStore
  }

  public func itemTotals(itemId: Int64) throws -> StorageTotals {
    Self.totals(rows: try downloadStore.fetchDownloads(itemId: itemId))
  }

  public func accountTotals() throws -> StorageTotals {
    let abs = Self.totals(rows: try downloadStore.fetchAll()).totalBytes
    let rss: Int64
    if let rssDownloadStore {
      rss = Self.rssTotals(rows: try rssDownloadStore.fetchAll()).totalBytes
    } else {
      rss = 0
    }
    return StorageTotals(totalBytes: abs + rss)
  }

  /// The shared summing core, used by the instance methods above (over `DownloadStore`'s fetch
  /// methods) and by `DefaultStorageReading`'s `ValueObservation` tracking closures (over the
  /// live `db` the closure is handed, so the observation path never nests a second
  /// `database.read` inside one already in progress).
  static func totals(rows: [DownloadRecord]) -> StorageTotals {
    let bytes =
      rows
      .filter { $0.state != .deleting }
      .reduce(into: Int64(0)) { $0 += $1.receivedBytes }
    return StorageTotals(totalBytes: bytes)
  }

  static func totals(_ db: Database, itemId: Int64) throws -> StorageTotals {
    totals(rows: try DownloadRecord.filter(Column("itemId") == itemId).fetchAll(db))
  }

  static func totals(_ db: Database) throws -> StorageTotals {
    totals(rows: try DownloadRecord.fetchAll(db))
  }

  static func rssTotals(rows: [RSSDownloadRecord]) -> StorageTotals {
    StorageTotals(
      totalBytes: rows.filter { $0.state != .deleting }.reduce(into: Int64(0)) {
        $0 += $1.actualBytes
      })
  }

  static func rssTotals(_ db: Database, feedId: Int64? = nil) throws -> StorageTotals {
    let rows: [RSSDownloadRecord]
    if let feedId {
      rows = try RSSDownloadRecord.fetchAll(
        db,
        sql: """
          SELECT download.* FROM rssDownload AS download
          JOIN rssEpisode AS episode ON episode.id = download.episodeId
          WHERE episode.feedId = ?
          """,
        arguments: [feedId])
    } else {
      rows = try RSSDownloadRecord.fetchAll(db)
    }
    return rssTotals(rows: rows)
  }

  /// The ceiling's accounting unit: only verified rows that have entered `.completed`.
  /// Ordinary `receivedBytes` writes stay in the tracked region; the observation applies
  /// `removeDuplicates` at the stream boundary below.
  static func completedBytes(_ db: Database) throws -> Int64 {
    let abs =
      try Int64.fetchOne(
        db,
        sql: "SELECT COALESCE(SUM(receivedBytes), 0) FROM download WHERE state = ?",
        arguments: [DownloadState.completed.rawValue]
      ) ?? 0
    let rss =
      try Int64.fetchOne(
        db,
        sql: "SELECT COALESCE(SUM(actualBytes), 0) FROM rssDownload WHERE state = ?",
        arguments: [DownloadState.completed.rawValue]
      ) ?? 0
    return abs + rss
  }

  /// The account's bytes by kind. A download row's own kind decides documents; an audio row is a
  /// podcast's when its item is one, and an audiobook's otherwise. RSS rows are podcast audio by
  /// construction.
  ///
  /// Takes every `download` row, filtering only `.deleting`, and left-joins: a filter by account,
  /// library or completion, or a dropped row, would make the segments disagree with the account
  /// total beside them.
  static func breakdown(_ db: Database) throws -> StorageBreakdown {
    let documentKinds = [DownloadMediaKind.ebook.rawValue, DownloadMediaKind.supplement.rawValue]
    let abs = try Row.fetchOne(
      db,
      sql: """
        SELECT
          COALESCE(SUM(CASE WHEN download.mediaKind IN (?, ?) THEN download.receivedBytes ELSE 0 END), 0)
            AS documentBytes,
          COALESCE(SUM(CASE WHEN download.mediaKind NOT IN (?, ?) AND item.mediaKind IS ?
                            THEN download.receivedBytes ELSE 0 END), 0) AS podcastBytes,
          COALESCE(SUM(CASE WHEN download.mediaKind NOT IN (?, ?) AND item.mediaKind IS NOT ?
                            THEN download.receivedBytes ELSE 0 END), 0) AS audiobookBytes
        FROM download
        LEFT JOIN item ON item.id = download.itemId
        WHERE download.state != ?
        """,
      arguments: StatementArguments(
        documentKinds + documentKinds + [ItemMediaCategory.podcast.rawValue] + documentKinds
          + [ItemMediaCategory.podcast.rawValue, DownloadState.deleting.rawValue]))
    return StorageBreakdown(
      audiobookBytes: abs?["audiobookBytes"] ?? 0,
      podcastBytes: (abs?["podcastBytes"] ?? 0) + (try rssTotals(db).totalBytes),
      documentBytes: abs?["documentBytes"] ?? 0)
  }

  /// Every item with at least one download row, titled from its `item` row and summed with
  /// `totals(rows:)` (so a mid-removal `.deleting` row contributes no bytes). An item whose rows
  /// are all `.deleting` still appears: it owns storage until the deletion protocol finishes
  /// removing the rows, and a screen showing "Removing…" needs it present. Ordered by
  /// `sortTitle`, as the browse index is.
  static func downloadedItems(_ db: Database) throws -> [DownloadedItemTotals] {
    let downloads = try DownloadRecord.fetchAll(db)

    let itemRowIds = Set(downloads.map(\.itemId))
    let items = try ItemRecord.filter(itemRowIds.contains(Column("id"))).fetchAll(db)
    let byItemRowId = Dictionary(grouping: downloads, by: \.itemId)
    // One extra query for the whole screen, not one per row: the tombstoned set is normally empty.
    let tombstonedIds = Set(try DownloadStore.tombstonedEpisodeDownloads(db).compactMap(\.id))

    var result: [DownloadedItemTotals] =
      items
      .sorted { ($0.sortTitle, $0.serverItemId) < ($1.sortTitle, $1.serverItemId) }
      .compactMap { item in
        guard let rowId = item.id, let rows = byItemRowId[rowId] else { return nil }
        let tombstonedRows = rows.filter { $0.id.map(tombstonedIds.contains) ?? false }
        return DownloadedItemTotals(
          itemId: item.serverItemId, title: item.title, totalBytes: totals(rows: rows).totalBytes,
          tombstonedEpisodeBytes: totals(rows: tombstonedRows).totalBytes)
      }

    let rss = try Row.fetchAll(
      db,
      sql: """
        SELECT feed.id AS feedId, feed.title AS title, feed.author AS author,
               SUM(CASE WHEN download.state != ? THEN download.actualBytes ELSE 0 END) AS totalBytes,
               SUM(CASE WHEN download.state != ? AND episode.retained = 1
                              AND episode.lastSeenGeneration < feed.refreshGeneration
                        THEN download.actualBytes ELSE 0 END) AS tombstonedBytes
        FROM rssDownload AS download
        JOIN rssEpisode AS episode ON episode.id = download.episodeId
        JOIN rssFeed AS feed ON feed.id = episode.feedId
        GROUP BY feed.id, feed.title, feed.author
        ORDER BY feed.title COLLATE NOCASE, feed.id
        """,
      arguments: [DownloadState.deleting.rawValue, DownloadState.deleting.rawValue])
    result.append(
      contentsOf: rss.map { row in
        DownloadedItemTotals(
          itemId: "rss:\(row["feedId"] as Int64)", title: (row["title"] as String?) ?? "",
          totalBytes: row["totalBytes"] as Int64? ?? 0,
          tombstonedEpisodeBytes: row["tombstonedBytes"] as Int64? ?? 0,
          author: row["author"], source: .rss)
      })
    // ABS rows come first; RSS follows as its own source section.
    return result
  }
}

/// Read side of storage accounting, mirroring `DownloadReading`'s boundary shape. Screens
/// observe this projection, never the raw `DownloadRecord`/`DownloadState` values.
public protocol StorageReading: Sendable {
  /// Every purgeable byte across every item, re-emitted whenever any download row's state or
  /// progress changes (completion, deletion, or otherwise).
  func observeAccountStorageTotals() -> AsyncStream<StorageTotals>

  /// One item's purgeable bytes, re-emitted only on that item's own download rows changing.
  /// `itemId` is the server item id, mirroring `DownloadReading.observeItemDownloadAggregate`.
  func observeItemStorageTotals(itemId: String) -> AsyncStream<StorageTotals>

  /// Every item that has download rows, re-emitted whenever that set (or any of their byte
  /// totals) changes. The storage screen's row source, so it never needs a list of library items
  /// that may or may not have anything on disk.
  func observeDownloadedItems() -> AsyncStream<[DownloadedItemTotals]>

  /// Completed bytes only, for the storage-ceiling trigger. Separate from
  /// `observeAccountStorageTotals()`, which includes progress on in-flight rows and must not be
  /// deduplicated because iterator-pinned consumers rely on its emissions.
  func observeCompletedDownloadTotals() -> AsyncStream<Int64>

  /// The account's bytes by kind, re-emitted when the split changes. Its total is the same figure
  /// `observeAccountStorageTotals()` reports.
  func observeStorageBreakdown() -> AsyncStream<StorageBreakdown>
}

/// Lightweight App-only readers need not take part in the storage-ceiling trigger, so these
/// defaults just finish the stream.
extension StorageReading {
  public func observeCompletedDownloadTotals() -> AsyncStream<Int64> {
    AsyncStream { $0.finish() }
  }

  public func observeStorageBreakdown() -> AsyncStream<StorageBreakdown> {
    AsyncStream { $0.finish() }
  }
}

/// The default no-op `StorageReading` conformance: every stream finishes immediately without
/// yielding. Mirrors `NoOpDownloadReading`.
public struct NoOpStorageReading: StorageReading, Sendable {
  public init() {}
  public func observeAccountStorageTotals() -> AsyncStream<StorageTotals> {
    AsyncStream { $0.finish() }
  }
  public func observeItemStorageTotals(itemId: String) -> AsyncStream<StorageTotals> {
    AsyncStream { $0.finish() }
  }
  public func observeDownloadedItems() -> AsyncStream<[DownloadedItemTotals]> {
    AsyncStream { $0.finish() }
  }
  public func observeCompletedDownloadTotals() -> AsyncStream<Int64> {
    AsyncStream { $0.finish() }
  }
}

/// The production `StorageReading` conformance: a GRDB `ValueObservation` bridged to a plain
/// `AsyncStream`, like `DefaultDownloadReading`. No GRDB type crosses into AppModel
/// (ARCHITECTURE.md).
public struct DefaultStorageReading: StorageReading, Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func observeAccountStorageTotals() -> AsyncStream<StorageTotals> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      let abs = try StorageAccounting.totals(db).totalBytes
      let rss = try StorageAccounting.rssTotals(db).totalBytes
      return StorageTotals(totalBytes: abs + rss)
    }
  }

  public func observeItemStorageTotals(itemId: String) -> AsyncStream<StorageTotals> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      if let feedId = PodcastSourceIdentity(itemId: itemId)?.rssFeedId {
        return try StorageAccounting.rssTotals(db, feedId: feedId)
      }
      guard let itemRowId = try ItemRecord.filter(Column("serverItemId") == itemId).fetchOne(db)?.id
      else { return StorageTotals(totalBytes: 0) }
      return try StorageAccounting.totals(db, itemId: itemRowId)
    }
  }

  public func observeDownloadedItems() -> AsyncStream<[DownloadedItemTotals]> {
    ObservationBridge.stream(in: database.dbWriter) { db in try StorageAccounting.downloadedItems(db) }
  }

  public func observeCompletedDownloadTotals() -> AsyncStream<Int64> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in try StorageAccounting.completedBytes(db) }
        .removeDuplicates())
  }

  public func observeStorageBreakdown() -> AsyncStream<StorageBreakdown> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in try StorageAccounting.breakdown(db) }
        .removeDuplicates())
  }
}
