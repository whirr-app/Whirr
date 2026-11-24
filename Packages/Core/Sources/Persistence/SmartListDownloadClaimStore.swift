import Foundation
import GRDB

/// "This list's request created this episode's download." Native claims carry no account and so
/// survive account removal; server claims cascade with their account.
public struct SmartListDownloadClaimStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Adds the claim unless the list already holds one for the episode.
  public func add(
    listID: Int64, itemID: String, episodeID: String, accountID: Int64?, now: Date = Date()
  ) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO smartListDownloadClaim
            (listId, itemID, episodeID, accountId, claimedAt)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: [listID, itemID, episodeID, accountID, now])
    }
  }

  public func remove(listID: Int64, itemID: String, episodeID: String) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          DELETE FROM smartListDownloadClaim WHERE listId = ? AND itemID = ? AND episodeID = ?
          """,
        arguments: [listID, itemID, episodeID])
    }
  }

  public func claims(listID: Int64) async throws -> [SmartListDownloadClaimRecord] {
    try await database.readAsync { db in
      try SmartListDownloadClaimRecord.fetchAll(
        db,
        sql: "SELECT * FROM smartListDownloadClaim WHERE listId = ? ORDER BY claimedAt, rowid",
        arguments: [listID])
    }
  }

  public func allClaims() async throws -> [SmartListDownloadClaimRecord] {
    try await database.readAsync { db in
      try SmartListDownloadClaimRecord.fetchAll(
        db, sql: "SELECT * FROM smartListDownloadClaim ORDER BY listId, claimedAt, rowid")
    }
  }
}
