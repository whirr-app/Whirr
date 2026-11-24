import Foundation
import GRDB

/// Accountless Saved for Later writes for native RSS episodes.
public struct NativeSavedShelfStore: SavedShelfStoring, SavedShelfDownloadTargetReading, Sendable {
  private let database: AppDatabase
  private let now: @Sendable () -> Date

  public init(database: AppDatabase, now: @escaping @Sendable () -> Date = Date.init) {
    self.database = database
    self.now = now
  }

  @discardableResult
  public func save(_ identity: SavedShelfIdentity) async throws -> SavedShelfSaveOutcome {
    guard case .rssEpisode(let itemID, let episodeID) = identity,
      let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId
    else {
      throw SavedShelfStoreError.episodeNotFound
    }
    return try await database.writeAsync { db in
      guard
        let episode = try Row.fetchOne(
          db,
          sql: """
            SELECT id, title, feedId FROM rssEpisode WHERE feedId = ? AND identityKey = ?
            """, arguments: [feedID, episodeID])
      else { throw SavedShelfStoreError.episodeNotFound }
      let episodeRowID: Int64 = episode["id"]
      if try RSSSavedShelfEntryRecord.filter(Column("rssEpisodeId") == episodeRowID).fetchOne(db) != nil {
        return .alreadySaved
      }
      var row = RSSSavedShelfEntryRecord(
        rssEpisodeId: episodeRowID, savedAt: now(), subjectTitle: (episode["title"] as String?) ?? "",
        contextTitle: try String.fetchOne(db, sql: "SELECT title FROM rssFeed WHERE id = ?", arguments: [feedID]))
      try row.insert(db)
      return .saved
    }
  }

  public func remove(_ identity: SavedShelfIdentity) async throws {
    guard case .rssEpisode(let itemID, let episodeID) = identity,
      let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId
    else { return }
    try await database.writeAsync { db in
      try db.execute(
        sql:
          "DELETE FROM rssSavedShelfEntry WHERE rssEpisodeId IN (SELECT id FROM rssEpisode WHERE feedId = ? AND identityKey = ?)",
        arguments: [feedID, episodeID])
    }
  }

  public func downloadTargets(for identity: SavedShelfIdentity) async throws
    -> [SavedShelfDownloadTarget]
  {
    guard case .rssEpisode(let itemID, let episodeID) = identity,
      let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId
    else { return [] }
    return try await database.readAsync { db in
      let exists =
        try Int.fetchOne(
          db,
          sql: """
            SELECT EXISTS(SELECT 1 FROM rssEpisode WHERE feedId = ? AND identityKey = ?)
            """, arguments: [feedID, episodeID]) == 1
      return exists ? [.episode(itemID: itemID, episodeID: episodeID)] : []
    }
  }
}
