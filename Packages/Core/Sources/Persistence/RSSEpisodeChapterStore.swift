import Foundation
import GRDB

/// One chapter read out of a downloaded RSS episode's audio. Positions are implied by order.
public struct RSSStoredChapter: Equatable, Sendable {
  public let start: Double
  public let end: Double
  public let title: String?

  public init(start: Double, end: Double, title: String?) {
    self.start = start
    self.end = end
    self.title = title
  }
}

/// What is cached for an episode's completed download. `chapters` is `nil` while the file has
/// never been parsed, and empty once it has been parsed and holds none.
public struct RSSEpisodeChapterCache: Equatable, Sendable {
  public let downloadId: Int64
  /// The row's `updatedAt` when this was read. A re-download reuses the row id, so the id alone
  /// cannot tell the file that was parsed from the one that replaced it.
  public let completedAt: Date
  public let chapters: [RSSStoredChapter]?
}

/// Caches the chapters embedded in a native RSS episode's downloaded file, per download. Reads
/// answer only for a `completed` download, and `RSSDownloadStore` clears the cache whenever that
/// download leaves `completed`, is re-completed or is deleted, so a replaced file is parsed again.
public struct RSSEpisodeChapterStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// `nil` when the episode has no completed download.
  public func cache(episodeId: Int64) async throws -> RSSEpisodeChapterCache? {
    try await database.readAsync { db in try Self.cache(episodeId: episodeId, in: db) }
  }

  /// Stores one extraction and marks it done, but only while the row is still the completed
  /// download `cache` was read from: a parse that raced a deletion or a re-download must not label
  /// the new file with the old file's chapters. Any other write to the row since then also drops
  /// the parse, which only costs a re-parse. Returns whether the extraction was kept.
  @discardableResult
  public func recordExtraction(
    episodeId: Int64, cache: RSSEpisodeChapterCache, chapters: [RSSStoredChapter],
    now: Date = Date()
  ) async throws -> Bool {
    let downloadId = cache.downloadId
    return try await database.writeAsync { db in
      guard
        let download = try RSSDownloadRecord.fetchOne(db, key: downloadId),
        download.episodeId == episodeId, download.state == .completed,
        download.updatedAt == cache.completedAt
      else { return false }
      try Self.invalidate(episodeId: episodeId, in: db)
      for (position, chapter) in chapters.enumerated() {
        var record = RSSEpisodeChapterRecord(
          episodeId: episodeId, position: position, start: chapter.start, end: chapter.end,
          title: chapter.title)
        try record.insert(db)
      }
      try db.execute(
        sql: "UPDATE rssDownload SET chaptersExtractedAt = ? WHERE id = ?",
        arguments: [now, downloadId])
      return true
    }
  }

  /// Drops an episode's rows. The marker lives on the download row, so callers that keep that row
  /// clear it themselves.
  static func invalidate(episodeId: Int64, in db: Database) throws {
    try RSSEpisodeChapterRecord.filter(Column("episodeId") == episodeId).deleteAll(db)
  }

  private static func cache(episodeId: Int64, in db: Database) throws -> RSSEpisodeChapterCache? {
    guard
      let download = try RSSDownloadRecord.fetchOne(
        db, sql: "SELECT * FROM rssDownload WHERE episodeId = ?", arguments: [episodeId]),
      download.state == .completed, let downloadId = download.id
    else { return nil }
    guard download.chaptersExtractedAt != nil else {
      return RSSEpisodeChapterCache(
        downloadId: downloadId, completedAt: download.updatedAt, chapters: nil)
    }
    let chapters =
      try RSSEpisodeChapterRecord
      .filter(Column("episodeId") == episodeId)
      .order(Column("position"))
      .fetchAll(db)
      .map { RSSStoredChapter(start: $0.start, end: $0.end, title: $0.title) }
    return RSSEpisodeChapterCache(
      downloadId: downloadId, completedAt: download.updatedAt, chapters: chapters)
  }
}
