import Foundation
import GRDB

/// Persistence for `pauseTrimEpisode`. It holds no file I/O and no
/// knowledge of what the runs mean: the blob is `PauseRuns`' own encoding.
public struct PauseTrimEpisodeStore: Sendable {
  let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func episode(for identity: AdSkipEpisodeIdentity) async throws -> PauseTrimEpisodeRecord? {
    try await database.readAsync { db in try Self.fetch(identity, in: db) }
  }

  /// Every stored analysis without its runs, for reconciling against the local downloads.
  public func allSummaries() async throws -> [PauseTrimEpisodeSummary] {
    try await database.readAsync { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT source, accountId, itemID, episodeID, fileByteSize, fileModificationTime,
                 detectorRevision, state
          FROM pauseTrimEpisode ORDER BY id
          """
      ).map { row in
        PauseTrimEpisodeSummary(
          identity: AdSkipEpisodeIdentity(
            source: row["source"], accountId: row["accountId"], itemID: row["itemID"],
            episodeID: row["episodeID"]),
          fileByteSize: row["fileByteSize"], fileModificationTime: row["fileModificationTime"],
          detectorRevision: row["detectorRevision"], state: row["state"])
      }
    }
  }

  /// Stores `record`, replacing any row for the same identity in place so its id stays stable.
  /// The caller's `record.id` is ignored.
  @discardableResult
  public func save(_ record: PauseTrimEpisodeRecord) async throws -> PauseTrimEpisodeRecord {
    try await database.writeAsync { db in
      var stored = record
      if let previous = try Self.fetch(record.identity, in: db) {
        stored.id = previous.id
        try stored.update(db)
      } else {
        stored.id = nil
        try stored.insert(db)
      }
      return stored
    }
  }

  public func deleteEpisodes(_ identities: [AdSkipEpisodeIdentity]) async throws {
    try await database.writeAsync { db in
      for identity in identities {
        try db.execute(
          sql: """
            DELETE FROM pauseTrimEpisode
            WHERE source = ? AND IFNULL(accountId, 0) = ? AND itemID = ? AND episodeID = ?
            """,
          arguments: Self.arguments(identity))
      }
    }
  }

  private static func fetch(
    _ identity: AdSkipEpisodeIdentity, in db: Database
  ) throws -> PauseTrimEpisodeRecord? {
    // `IFNULL` matches the unique index, which is what lets RSS rows (no account) collide.
    try PauseTrimEpisodeRecord.fetchOne(
      db,
      sql: """
        SELECT * FROM pauseTrimEpisode
        WHERE source = ? AND IFNULL(accountId, 0) = ? AND itemID = ? AND episodeID = ?
        """,
      arguments: arguments(identity))
  }

  private static func arguments(_ identity: AdSkipEpisodeIdentity) -> StatementArguments {
    [identity.source, identity.accountId ?? 0, identity.itemID, identity.episodeID]
  }
}
