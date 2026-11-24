import Foundation
import GRDB

/// The one active list run, if any. The row is single by construction (`id = 1`).
public struct SmartListRunStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func current() async throws -> SmartListRunRecord? {
    try await database.readAsync { db in try SmartListRunRecord.fetchOne(db, key: 1) }
  }

  /// The active run, current value first, then on each change.
  public func observeCurrent() -> AsyncStream<SmartListRunRecord?> {
    ObservationBridge.stream(
      in: database.dbWriter,
      observation: ValueObservation.tracking { db in try SmartListRunRecord.fetchOne(db, key: 1) }
        .removeDuplicates())
  }

  /// Starts a run of `listID`, replacing any run, with no anchor.
  public func begin(listID: Int64, now: Date = Date()) async throws {
    try await database.writeAsync { db in
      guard try SmartListRecord.exists(db, key: listID) else {
        throw SmartListStoreError.listNotFound
      }
      try SmartListRunRecord(listId: listID, startedAt: now).save(db)
    }
  }

  /// Records the last list start. Returns false, writing nothing, when no run is active.
  @discardableResult
  public func setAnchor(itemID: String, episodeID: String, sortKey: String) async throws -> Bool {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE smartListRun
          SET anchorItemID = ?, anchorEpisodeID = ?, anchorSortKey = ? WHERE id = 1
          """,
        arguments: [itemID, episodeID, sortKey])
      return db.changesCount > 0
    }
  }

  public func end() async throws {
    try await database.writeAsync { db in
      try db.execute(sql: "DELETE FROM smartListRun")
    }
  }
}
