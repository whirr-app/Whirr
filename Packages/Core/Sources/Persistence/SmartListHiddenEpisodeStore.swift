import Foundation
import GRDB

/// Episodes a list no longer shows. Hiding changes nothing else: no download, no played state.
public struct SmartListHiddenEpisodeStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func hide(listID: Int64, itemID: String, episodeID: String) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO smartListHiddenEpisode (listId, itemID, episodeID) VALUES (?, ?, ?)
          """,
        arguments: [listID, itemID, episodeID])
    }
  }

  public func unhide(listID: Int64, itemID: String, episodeID: String) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          DELETE FROM smartListHiddenEpisode WHERE listId = ? AND itemID = ? AND episodeID = ?
          """,
        arguments: [listID, itemID, episodeID])
    }
  }

  public func hiddenEpisodes(listID: Int64) async throws -> [SmartListHiddenEpisodeRecord] {
    try await database.readAsync { db in
      try SmartListHiddenEpisodeRecord.fetchAll(
        db, sql: "SELECT * FROM smartListHiddenEpisode WHERE listId = ? ORDER BY rowid",
        arguments: [listID])
    }
  }

  /// Drops the given episodes from every list, for a caller that has found them finished or gone.
  /// Returns the number of rows removed.
  @discardableResult
  public func prune(episodes: [(itemID: String, episodeID: String)]) async throws -> Int {
    try await database.writeAsync { db in
      var removed = 0
      for episode in episodes {
        try db.execute(
          sql: "DELETE FROM smartListHiddenEpisode WHERE itemID = ? AND episodeID = ?",
          arguments: [episode.itemID, episode.episodeID])
        removed += db.changesCount
      }
      return removed
    }
  }
}
