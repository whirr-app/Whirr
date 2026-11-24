import Foundation
import GRDB

/// The measured length of an episode's completed download, as last read.
public struct RSSDownloadMeasuredDuration: Equatable, Sendable {
  public let downloadId: Int64
  /// The row's `updatedAt` when this was read. A re-download reuses the row id, so the id alone
  /// cannot tell the file that was measured from the one that replaced it.
  public let observedAt: Date
  /// `nil` until this file has been measured.
  public let seconds: Double?
}

/// The length of a downloaded RSS episode's own file, stored on its download row. Dynamic ad
/// insertion makes the file and the feed's declaration differ and positions are on the file's
/// timeline, so the stopped player, Continue Listening and the near-zero reset guard prefer this
/// length while the file exists.
///
/// Like `RSSEpisodeChapterStore`, construction has no side effects; `RSSDownloadStore.init`
/// interrupts in-flight transfers, so the composition must not build a second one to reach this
/// column. `RSSDownloadStore` clears the value when the download leaves `completed` or is
/// re-completed, and deleting the row removes it, so it only describes the current file.
public struct RSSDownloadDurationStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// `nil` when the episode has no completed download.
  public func measuredDuration(episodeId: Int64) async throws -> RSSDownloadMeasuredDuration? {
    try await database.readAsync { db in
      guard
        let download = try RSSDownloadRecord.fetchOne(
          db, sql: "SELECT * FROM rssDownload WHERE episodeId = ?", arguments: [episodeId]),
        download.state == .completed, let downloadId = download.id
      else { return nil }
      return RSSDownloadMeasuredDuration(
        downloadId: downloadId, observedAt: download.updatedAt,
        seconds: download.measuredDurationSeconds)
    }
  }

  /// Stores a measurement only while the row is still the completed download `observed` was read
  /// from, so a measurement that raced a re-download or a deletion cannot label the new file. Any
  /// other write to the row since then also drops it, which only costs a re-measure on the next
  /// play. It leaves `updatedAt` alone, which `RSSEpisodeChapterStore` compares the same way.
  /// Returns whether the value was kept.
  @discardableResult
  public func recordMeasuredDuration(
    episodeId: Int64, observed: RSSDownloadMeasuredDuration, seconds: Double
  ) async throws -> Bool {
    guard seconds.isFinite, seconds > 0 else { return false }
    let downloadId = observed.downloadId
    return try await database.writeAsync { db in
      guard
        let download = try RSSDownloadRecord.fetchOne(db, key: downloadId),
        download.episodeId == episodeId, download.state == .completed,
        download.updatedAt == observed.observedAt
      else { return false }
      try db.execute(
        sql: "UPDATE rssDownload SET measuredDurationSeconds = ? WHERE id = ?",
        arguments: [seconds, downloadId])
      return true
    }
  }

  /// The length an episode's timeline-dependent readers use: the completed download's measured
  /// length, then the feed's declaration, then the enclosure measurement. The state test is inline
  /// rather than in the caller's join because `markAllDeletingAsync` moves rows to `deleting`
  /// without clearing the column, and because Continue Listening's join is unfiltered by design.
  /// The caller must `LEFT JOIN rssDownload AS <download> ON <download>.episodeId = <episode>.id`.
  static func preferredDurationSQL(episode: String, download: String) -> String {
    """
    COALESCE(CASE WHEN \(download).state = 'completed' THEN \(download).measuredDurationSeconds END, \
    \(episode).durationSeconds, \(episode).measuredDurationSeconds)
    """
  }
}
