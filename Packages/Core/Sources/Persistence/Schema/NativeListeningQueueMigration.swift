import GRDB

extension SchemaV1 {
  enum NativeListeningQueueMigrationCheckpoint: Sendable, Equatable {
    case afterCopy, afterDrop, afterSwap
  }

  static func splitRSSListeningQueue(
    _ db: Database,
    checkpoint: @Sendable (NativeListeningQueueMigrationCheckpoint) throws -> Void
  ) throws {
    try db.create(table: "rssListeningQueueEntry") { t in
      t.autoIncrementedPrimaryKey("id")
      t.column("rssEpisodeId", .integer).notNull().references("rssEpisode", onDelete: .cascade)
      t.column("position", .integer).notNull()
      t.uniqueKey(["rssEpisodeId"])
      t.uniqueKey(["position"])
    }
    // Rebuild the ABS table so its source columns are no longer nullable and RSS cannot be
    // accidentally represented as an account-owned row.
    try db.create(table: "listeningQueueEntry_v59") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("itemId", .integer).notNull()
      t.column("podcastEpisodeId", .integer)
      t.column("position", .integer).notNull()
      t.foreignKey(["accountId", "itemId"], references: "item", columns: ["accountId", "id"], onDelete: .cascade)
      t.foreignKey(
        ["accountId", "podcastEpisodeId"], references: "podcastEpisode", columns: ["accountId", "id"],
        onDelete: .cascade)
    }
    let rssCount =
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningQueueEntry WHERE rssEpisodeId IS NOT NULL") ?? 0
    try db.execute(
      sql:
        "INSERT INTO rssListeningQueueEntry (id, rssEpisodeId, position) SELECT id, rssEpisodeId, position FROM listeningQueueEntry WHERE rssEpisodeId IS NOT NULL ORDER BY position, id"
    )
    let copiedRSS = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssListeningQueueEntry") ?? -1
    guard copiedRSS == rssCount else {
      throw RSSListeningQueueMigrationError.copyCountMismatch(expected: rssCount, actual: copiedRSS)
    }
    try db.execute(
      sql:
        "INSERT INTO listeningQueueEntry_v59 (id, accountId, itemId, podcastEpisodeId, position) SELECT id, accountId, itemId, podcastEpisodeId, position FROM listeningQueueEntry WHERE rssEpisodeId IS NULL ORDER BY position, id"
    )
    let absCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningQueueEntry_v59") ?? -1
    let expectedABS = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningQueueEntry") ?? 0) - rssCount
    guard absCount == expectedABS else {
      throw RSSListeningQueueMigrationError.copyCountMismatch(expected: expectedABS, actual: absCount)
    }
    try checkpoint(.afterCopy)
    try db.drop(table: "listeningQueueEntry")
    try checkpoint(.afterDrop)
    try db.rename(table: "listeningQueueEntry_v59", to: "listeningQueueEntry")
    try db.drop(index: "listeningQueueEntry_v59_on_accountId")
    try db.create(index: "listeningQueueEntry_on_accountId", on: "listeningQueueEntry", columns: ["accountId"])
    try db.create(
      index: "index_listeningQueueEntry_on_account_position", on: "listeningQueueEntry",
      columns: ["accountId", "position"], options: .unique)
    try db.create(
      index: "index_listeningQueueEntry_on_account_item", on: "listeningQueueEntry", columns: ["accountId", "itemId"],
      options: .unique, condition: Column("podcastEpisodeId") == nil)
    try db.create(
      index: "index_listeningQueueEntry_on_account_episode", on: "listeningQueueEntry",
      columns: ["accountId", "podcastEpisodeId"], options: .unique, condition: Column("podcastEpisodeId") != nil)
    try db.execute(
      sql: """
        CREATE TABLE nativeListeningQueueRevision (
          id INTEGER PRIMARY KEY CHECK (id = 1), revision INTEGER NOT NULL DEFAULT 0
        );
        INSERT INTO nativeListeningQueueRevision (id) VALUES (1);
        """)
    try compactAsOfSplit(in: db)
    try checkpoint(.afterSwap)
  }

  /// Dense renumber across both queue tables, frozen at this migration's schema. The live writer
  /// reads and writes columns added by later migrations, which do not exist yet when this runs.
  private static func compactAsOfSplit(in db: Database) throws {
    let union = """
      SELECT id AS rowID, position, 0 AS sourceTag FROM listeningQueueEntry
      UNION ALL
      SELECT id AS rowID, position, 1 AS sourceTag FROM rssListeningQueueEntry
      """
    let rows = try Row.fetchAll(db, sql: "SELECT * FROM (\(union)) ORDER BY position, sourceTag, rowID")
    let minimum = try Int.fetchOne(db, sql: "SELECT MIN(position) FROM (\(union))") ?? 0
    let offset = min(minimum, 0) - rows.count - 1
    // Two passes: park every row below the existing positions, then assign the dense order, so
    // the unique position index never sees a collision mid-renumber.
    for base in [offset, 0] {
      for (index, row) in rows.enumerated() {
        let table = (row["sourceTag"] as Int) == 0 ? "listeningQueueEntry" : "rssListeningQueueEntry"
        let position = base == 0 ? index : base - index
        try db.execute(
          sql: "UPDATE \(table) SET position = ? WHERE id = ?", arguments: [position, row["rowID"] as Int64])
      }
    }
  }

}
