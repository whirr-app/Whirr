import Foundation
import GRDB

extension MediaProgressDAO {
  /// An item-level row whose last applied pull recorded the server row it came from.
  public struct ObservedItemProgress: Sendable, Equatable {
    public let itemRowId: Int64
    public let serverItemId: String
    public let durationSeconds: Double?
    public let hasEbookPosition: Bool

    public init(itemRowId: Int64, serverItemId: String, durationSeconds: Double?, hasEbookPosition: Bool) {
      self.itemRowId = itemRowId
      self.serverItemId = serverItemId
      self.durationSeconds = durationSeconds
      self.hasEbookPosition = hasEbookPosition
    }
  }

  /// The candidates for "absent from a complete snapshot" reset evidence: live items in
  /// `libraryIds` whose progress row names an observed server row.
  public func observedItemProgressAsync(
    accountId: Int64, libraryIds: [Int64]
  ) async throws -> [ObservedItemProgress] {
    guard libraryIds.isEmpty == false else { return [] }
    return try await database.readAsync { db in
      let placeholders = Array(repeating: "?", count: libraryIds.count).joined(separator: ",")
      var arguments: StatementArguments = [accountId]
      arguments += StatementArguments(libraryIds)
      return try Row.fetchAll(
        db,
        sql: """
          SELECT item.id AS itemRowId, item.serverItemId, item.durationSeconds,
            (mediaProgress.ebookProgress IS NOT NULL OR mediaProgress.ebookLocation IS NOT NULL)
              AS hasEbookPosition
          FROM mediaProgress
          JOIN item ON item.id = mediaProgress.itemId
          WHERE mediaProgress.accountId = ?
            AND mediaProgress.podcastEpisodeId IS NULL
            AND mediaProgress.serverProgressId IS NOT NULL
            -- Not a catalogue projection: the caller named these libraries.
            AND item.softDeleted = 0
            AND item.libraryId IN (\(placeholders))
          ORDER BY item.id
          """,
        arguments: arguments
      ).map { row in
        ObservedItemProgress(
          itemRowId: row["itemRowId"], serverItemId: row["serverItemId"],
          durationSeconds: row["durationSeconds"], hasEbookPosition: row["hasEbookPosition"])
      }
    }
  }

  /// Completes an acknowledged `progressReset` in the same transaction as its outbox deletion.
  ///
  /// The server row this device last observed is gone, so its id is cleared unconditionally: a
  /// later pull must not read the restore's new row as another device's reset. `serverUpdatedAt`
  /// is cleared too (no server observation remains), so the restored row or any later one wins an
  /// ordinary comparison on the next pull. No local clock is recorded.
  ///
  /// A local write that landed while the reset was in flight has the higher sequence and stays
  /// authoritative, as with the other acknowledgements.
  public func acknowledgeProgressResetAsync(operationId: Int64) async throws {
    try await database.writeAsync { db in
      guard let operation = try OutboxOperationRecord.fetchOne(db, key: operationId) else {
        throw OutboxStoreError.operationNotFound(operationId)
      }
      if let item =
        try ItemRecord
        .filter(Column("accountId") == operation.accountId)
        .filter(Column("serverItemId") == operation.entityKey)
        .fetchOne(db),
        let itemID = item.id
      {
        let identity: MediaProgressIdentity =
          if let episodeID = operation.podcastEpisodeId {
            .episode(itemId: itemID, podcastEpisodeId: episodeID)
          } else {
            .item(itemId: itemID)
          }
        if var record = try Self.fetchProgress(
          db, accountId: operation.accountId, identity: identity)
        {
          record.serverProgressId = nil
          record.serverProgressUpdatedAt = nil
          record.serverUpdatedAt = nil
          if record.localSequence <= operation.localSequence {
            switch operation.progressResetMedium {
            case .ebook:
              record.ebookProgress = 0
              record.ebookLocation = nil
              record.readingPositionJSON = nil
            case .audio, nil:
              record.currentTime = 0
              record.hideFromContinueListening = false
            }
            record.isFinished = false
          }
          try record.update(db)
        }
      }
      _ = try operation.delete(db)
    }
  }
}
