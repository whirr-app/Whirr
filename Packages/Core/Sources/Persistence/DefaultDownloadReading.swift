import Foundation
import GRDB

/// The production `DownloadReading` conformance: a GRDB `ValueObservation` bridged to a plain
/// `AsyncStream`, so no GRDB type ever crosses into AppModel (ARCHITECTURE.md §1). Mirrors
/// `DefaultLibraryReading`. The server-facing `itemId` resolves to the internal row id inside
/// the tracked fetch closure, not up front, so the stream still reacts if the item row appears
/// after observation starts.
public struct DefaultDownloadReading: DownloadReading, Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func currentItemDownloadStatus(itemId: String) -> ItemDownloadStatus {
    (try? database.read { db in
      guard
        let itemRowId =
          try ItemRecord
          .filter(Column("serverItemId") == itemId)
          .fetchOne(db)?.id
      else {
        return .notDownloaded
      }
      return try DownloadStore.itemStatus(db, itemId: itemRowId)
    }) ?? .notDownloaded
  }

  public func currentItemDownloadStatusAsync(itemId: String) async -> ItemDownloadStatus {
    (try? await database.readAsync { db in
      guard
        let itemRowId =
          try ItemRecord
          .filter(Column("serverItemId") == itemId)
          .fetchOne(db)?.id
      else {
        return .notDownloaded
      }
      return try DownloadStore.itemStatus(db, itemId: itemRowId)
    }) ?? .notDownloaded
  }

  public func currentItemFormatDownloadStatus(itemId: String) -> ItemFormatDownloadStatus {
    (try? database.read { db in
      guard
        let itemRowId =
          try ItemRecord
          .filter(Column("serverItemId") == itemId)
          .fetchOne(db)?.id
      else {
        return ItemFormatDownloadStatus()
      }
      return try DownloadStore.itemFormatStatus(db, itemId: itemRowId)
    }) ?? ItemFormatDownloadStatus()
  }

  public func currentItemFormatDownloadStatusAsync(itemId: String) async -> ItemFormatDownloadStatus {
    (try? await database.readAsync { db in
      guard
        let itemRowId =
          try ItemRecord
          .filter(Column("serverItemId") == itemId)
          .fetchOne(db)?.id
      else {
        return ItemFormatDownloadStatus()
      }
      return try DownloadStore.itemFormatStatus(db, itemId: itemRowId)
    }) ?? ItemFormatDownloadStatus()
  }

  public func observeItemDownloadAggregate(itemId: String) -> AsyncStream<DownloadAggregate> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      guard
        let itemRowId =
          try ItemRecord
          .filter(Column("serverItemId") == itemId)
          .fetchOne(db)?.id
      else {
        return DownloadAggregate(state: .none, progressFraction: 0)
      }
      return try DownloadStore.aggregate(db, itemId: itemRowId)
    }
  }

  public func observeItemDownloadStatus(itemId: String) -> AsyncStream<ItemDownloadStatus> {
    ObservationBridge.stream(in: database.dbWriter) { db in
      guard
        let itemRowId =
          try ItemRecord
          .filter(Column("serverItemId") == itemId)
          .fetchOne(db)?.id
      else {
        return .notDownloaded
      }
      return try DownloadStore.itemStatus(db, itemId: itemRowId)
    }
  }

  public func observeItemFormatDownloadStatus(itemId: String)
    -> AsyncStream<ItemFormatDownloadStatus>
  {
    ObservationBridge.stream(in: database.dbWriter) { db in
      guard
        let itemRowId =
          try ItemRecord
          .filter(Column("serverItemId") == itemId)
          .fetchOne(db)?.id
      else {
        return ItemFormatDownloadStatus()
      }
      return try DownloadStore.itemFormatStatus(db, itemId: itemRowId)
    }
  }

  /// One observation for every downloaded item. `removeDuplicates` is load-bearing: every row on
  /// a screen renders from this single value, so without it each byte-progress write would
  /// re-emit and invalidate the whole list. `ItemDownloadPresence` is coarse enough that such
  /// writes produce an identical map and are dropped here.
  public func observeItemDownloadPresence() -> AsyncStream<[String: ItemDownloadPresence]> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in try DownloadStore.itemPresence(db) }
        .removeDuplicates())
  }

  /// The episode-scoped presence projection, deduplicated like `observeItemDownloadPresence` so
  /// byte-progress writes don't re-emit the map.
  ///
  /// One tracked fetch covers both spines: account-owned episodes in `download`, device-owned ones
  /// in `rssDownload` under the reserved `rss:` item namespace. The key sets cannot collide, so
  /// the maps are merged, not reconciled.
  public func observeEpisodeDownloadPresence()
    -> AsyncStream<[EpisodeDownloadKey: ItemDownloadPresence]>
  {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation:
        ValueObservation
        .tracking { db in
          try DownloadStore.episodePresence(db)
            .merging(RSSDownloadStore.episodePresence(db)) { abs, _ in abs }
        }
        .removeDuplicates())
  }

}
