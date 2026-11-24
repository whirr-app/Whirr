import Foundation

/// The account-scoped server-owned set of series dismissed from Continue Series. A successful
/// progress pull is authoritative, so replacement removes rows the server no longer reports.
public struct HiddenContinueSeriesStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Replaces every hidden series id for `accountId` in one transaction.
  public func replace(accountId: Int64, serverSeriesIDs: [String]) async throws {
    try await database.writeAsync { db in
      try db.execute(
        sql: "DELETE FROM hiddenContinueSeries WHERE accountId = ?",
        arguments: [accountId])
      for serverSeriesID in Set(serverSeriesIDs) {
        try db.execute(
          sql: "INSERT INTO hiddenContinueSeries (accountId, serverSeriesId) VALUES (?, ?)",
          arguments: [accountId, serverSeriesID])
      }
    }
  }
}
