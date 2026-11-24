import Foundation
import GRDB

/// Projects the account and device-owned playback markers from one database observation, so
/// "what was last played" has a single answer across both origins.
///
/// Newer wins: every `PlaybackModel.start` writes exactly one surface, so the other row is left
/// over from an earlier start and `updatedAt` distinguishes them. Both stamps use the same wall
/// clock, so a device clock change between two starts could invert the order (a known limitation).
///
/// A surface that projects nothing does not suppress the other: the account store returns `nil`
/// for a soft-deleted item while keeping its row, so a tombstoned newest account bookmark falls
/// back to the device marker. The device side has no such state: a reaped episode takes its
/// bookmark row with it through the foreign key.
///
/// A tie keeps the account surface. Unreachable from `start`; the rule keeps the projection
/// independent of which row was read first.
///
/// A concrete type, not a protocol: this must be one `ValueObservation` over both tables, since
/// two independently-debounced streams can publish a torn ordering during an origin switch.
public struct MergedPlaybackBookmarkReading: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// `removeDuplicates` for the same reason as `DefaultPlaybackBookmarkStoring.observeBookmark()`.
  public func observeBookmark() -> AsyncStream<PlaybackBookmark?> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db in
        try Self.merge(
          abs: DefaultPlaybackBookmarkStoring.timestampedBookmark(in: db),
          rss: RSSPlaybackBookmarkStore.timestampedBookmark(in: db))
      }.removeDuplicates())
  }

  public func fetchBookmark() async -> PlaybackBookmark? {
    try? await database.readAsync { db in
      try Self.merge(
        abs: DefaultPlaybackBookmarkStoring.timestampedBookmark(in: db),
        rss: RSSPlaybackBookmarkStore.timestampedBookmark(in: db))
    }
  }

  private static func merge(
    abs: (bookmark: PlaybackBookmark, updatedAt: Date)?,
    rss: (bookmark: PlaybackBookmark, updatedAt: Date)?
  ) -> PlaybackBookmark? {
    switch (abs, rss) {
    case (nil, nil): nil
    case (let abs?, nil): abs.bookmark
    case (nil, let rss?): rss.bookmark
    case (let abs?, let rss?): rss.updatedAt > abs.updatedAt ? rss.bookmark : abs.bookmark
    }
  }
}
