import Foundation
import GRDB

/// What one pulled episode observation says about the server row behind it: the input to reset
/// evidence (ADR 0011). SyncEngine decides; Persistence only carries it through the transaction
/// to the decider and records the row id.
public struct ServerRowObservation: Sendable, Equatable {
  /// The winning row's id, recorded as the identity's `serverProgressId`.
  public let progressId: String?
  /// Every row id the snapshot holds for the identity, duplicates included. Empty means the
  /// identity is absent from the snapshot.
  public let rowIDs: [String?]
  public let startedAt: Date?
  public let snapshotIsComplete: Bool

  public init(progressId: String?, rowIDs: [String?], startedAt: Date?, snapshotIsComplete: Bool) {
    self.progressId = progressId
    self.rowIDs = rowIDs
    self.startedAt = startedAt
    self.snapshotIsComplete = snapshotIsComplete
  }

  /// An identity a complete snapshot omits.
  public static let absent = ServerRowObservation(
    progressId: nil, rowIDs: [], startedAt: nil, snapshotIsComplete: true)
}

extension MediaProgressDAO {
  /// Records the server row a pull observed and its `lastUpdate`, whatever the field decisions
  /// were. A row that does not exist locally is left alone: there is nothing for a later reset to
  /// act on.
  static func recordObservedServerProgressId(
    _ db: Database, accountId: Int64, identity: MediaProgressIdentity, serverProgressId: String?,
    serverUpdatedAt: Date?
  ) throws {
    let updatedAt = serverProgressId == nil ? nil : serverUpdatedAt
    guard var record = try Self.fetchProgress(db, accountId: accountId, identity: identity),
      record.serverProgressId != serverProgressId || record.serverProgressUpdatedAt != updatedAt
    else { return }
    record.serverProgressId = serverProgressId
    record.serverProgressUpdatedAt = updatedAt
    try record.update(db)
  }

  /// Episode rows under `itemIds` whose last pull recorded a server row, keyed by server episode
  /// id: the candidates for "absent from a complete snapshot" reset evidence.
  static func observedEpisodeServerIDs(
    _ db: Database, accountId: Int64, itemIds: [Int64]
  ) throws -> [(itemId: Int64, serverItemId: String, serverEpisodeId: String)] {
    guard itemIds.isEmpty == false else { return [] }
    let placeholders = Array(repeating: "?", count: itemIds.count).joined(separator: ",")
    var arguments: StatementArguments = [accountId]
    arguments += StatementArguments(itemIds)
    // Not a catalogue projection: progress reconciliation reads the rows it was given.
    return try Row.fetchAll(
      db,
      sql: """
        SELECT item.id AS itemId, item.serverItemId, podcastEpisode.serverEpisodeId
        FROM mediaProgress
        JOIN item ON item.id = mediaProgress.itemId
        JOIN podcastEpisode ON podcastEpisode.id = mediaProgress.podcastEpisodeId
        WHERE mediaProgress.accountId = ?
          AND mediaProgress.serverProgressId IS NOT NULL
          AND podcastEpisode.softDeleted = 0
          AND item.softDeleted = 0
          AND item.id IN (\(placeholders))
        ORDER BY item.id, podcastEpisode.serverEpisodeId
        """,
      arguments: arguments
    ).map { row in (row["itemId"], row["serverItemId"], row["serverEpisodeId"]) }
  }
}
