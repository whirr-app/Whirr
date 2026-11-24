import GRDB

/// The listening queue's tables: the podcast-only queue that predates it (`v6`), the universal
/// queue that replaced it (`v15`), its revision counter (`v16`), and the rebuild that adds the
/// device-owned RSS episode source (`v47`).
///
/// Registered by `SchemaV1.registerEra1` and `registerEra3`; `SchemaV1.migrator()` holds the order.
/// The bodies are frozen: an applied migration is never edited in place.
extension SchemaV1 {

  // MARK: - v6: local podcast queue

  static func createPodcastQueueEntry(_ db: Database) throws {
    try db.create(
      index: "index_podcastEpisode_on_account_id", on: "podcastEpisode",
      columns: ["accountId", "id"], options: .unique)
    try db.create(table: "podcastQueueEntry") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("podcastEpisodeId", .integer).notNull()
      t.column("position", .integer).notNull()
      t.foreignKey(
        ["accountId", "podcastEpisodeId"], references: "podcastEpisode",
        columns: ["accountId", "id"], onDelete: .cascade)
    }
    try db.create(
      index: "index_podcastQueueEntry_on_account_position", on: "podcastQueueEntry",
      columns: ["accountId", "position"], options: .unique)
    try db.create(
      index: "index_podcastQueueEntry_on_account_episode", on: "podcastQueueEntry",
      columns: ["accountId", "podcastEpisodeId"], options: .unique)
  }

  // MARK: - v15: universal listening queue

  /// `podcastQueueEntry` (v6) required a non-null episode identity, so audiobooks could never
  /// enter the queue. `listeningQueueEntry` uses an optional `podcastEpisodeId` beside a
  /// mandatory `itemId`, so one row shape carries either a whole audiobook (`itemId` only) or a
  /// podcast episode (`itemId` + `podcastEpisodeId`).
  ///
  /// Constraints:
  ///
  /// - `(accountId, itemId)` composite FK to `item(accountId, id)`. Its unique parent index
  ///   (`index_item_on_account_id`) exists from v14's `createPodcastShowOrder` and must not be
  ///   recreated: `db.create(index:)` on an existing name throws.
  /// - `(accountId, podcastEpisodeId)` composite FK to `podcastEpisode(accountId, id)`, as in v6;
  ///   its parent index (`index_podcastEpisode_on_account_id`) exists from v6.
  /// - No three-column FK: it would need a third unique parent index. The episode FK guarantees
  ///   the episode belongs to this account; belonging to this item is enforced by the resolve join
  ///   in `ListeningQueueStore` (`episode.itemId = item.id`), not by a schema constraint.
  /// - Two partial unique indexes, not one plain one: SQLite treats NULLs as distinct in a unique
  ///   index, so a plain `(accountId, itemId)` index would admit unlimited duplicate audiobook rows
  ///   (`podcastEpisodeId IS NULL`), and a plain `(accountId, podcastEpisodeId)` one ignores them.
  ///
  /// Every existing `podcastQueueEntry` row is copied across, keeping row id and position, taking
  /// `itemId` from its episode's own item. The row count is verified, then the old table is
  /// dropped, all in this migration's transaction (GRDB runs each in its own). Never edit `v6`.
  static func createListeningQueueEntry(
    _ db: Database,
    checkpoint: @Sendable (ListeningQueueMigrationCheckpoint) throws -> Void
  ) throws {
    try db.create(table: "listeningQueueEntry") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("itemId", .integer).notNull()
      t.column("podcastEpisodeId", .integer)
      t.column("position", .integer).notNull()
      t.foreignKey(
        ["accountId", "itemId"], references: "item",
        columns: ["accountId", "id"], onDelete: .cascade)
      t.foreignKey(
        ["accountId", "podcastEpisodeId"], references: "podcastEpisode",
        columns: ["accountId", "id"], onDelete: .cascade)
    }
    try db.create(
      index: "index_listeningQueueEntry_on_account_position", on: "listeningQueueEntry",
      columns: ["accountId", "position"], options: .unique)
    try db.create(
      index: "index_listeningQueueEntry_on_account_item", on: "listeningQueueEntry",
      columns: ["accountId", "itemId"], options: .unique,
      condition: Column("podcastEpisodeId") == nil)
    try db.create(
      index: "index_listeningQueueEntry_on_account_episode", on: "listeningQueueEntry",
      columns: ["accountId", "podcastEpisodeId"], options: .unique,
      condition: Column("podcastEpisodeId") != nil)

    let sourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM podcastQueueEntry") ?? 0
    try db.execute(
      sql: """
        INSERT INTO listeningQueueEntry (id, accountId, itemId, podcastEpisodeId, position)
        SELECT queue.id, queue.accountId, item.id, queue.podcastEpisodeId, queue.position
        FROM podcastQueueEntry AS queue
        JOIN podcastEpisode AS episode ON episode.id = queue.podcastEpisodeId
        JOIN item ON item.id = episode.itemId
        ORDER BY queue.position
        """)
    let copiedCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningQueueEntry") ?? -1
    guard copiedCount == sourceCount else {
      throw ListeningQueueMigrationError.copyCountMismatch(
        expected: sourceCount, actual: copiedCount)
    }
    try checkpoint(.afterCopy)

    try db.drop(table: "podcastQueueEntry")
    try checkpoint(.afterDrop)
  }

  // MARK: - v16: listening queue revision counter

  /// One optional row per account (absent means revision `0`), shaped like `podcastShowOrder`:
  /// `accountId` is the primary key, with a direct FK to `account` rather than `belongsTo`.
  static func createListeningQueueRevision(_ db: Database) throws {
    try db.create(table: "listeningQueueRevision") { t in
      t.column("accountId", .integer).primaryKey().references("account", onDelete: .cascade)
      t.column("revision", .integer).notNull().defaults(to: 0)
    }
  }

  // MARK: - v47: the listening queue's device-owned RSS source

  static func rebuildListeningQueueForRSS(
    _ db: Database,
    checkpoint: @Sendable (RSSListeningQueueMigrationCheckpoint) throws -> Void
  ) throws {
    try db.create(table: "listeningQueueEntry_v47") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("itemId", .integer)
      t.column("podcastEpisodeId", .integer)
      t.column("rssEpisodeId", .integer).references("rssEpisode", onDelete: .cascade)
      t.column("position", .integer).notNull()
      t.check(
        sql: """
          (itemId IS NOT NULL AND rssEpisodeId IS NULL)
          OR (itemId IS NULL AND podcastEpisodeId IS NULL AND rssEpisodeId IS NOT NULL)
          """)
      t.foreignKey(
        ["accountId", "itemId"], references: "item",
        columns: ["accountId", "id"], onDelete: .cascade)
      t.foreignKey(
        ["accountId", "podcastEpisodeId"], references: "podcastEpisode",
        columns: ["accountId", "id"], onDelete: .cascade)
    }

    let sourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningQueueEntry") ?? 0
    try db.execute(
      sql: """
        INSERT INTO listeningQueueEntry_v47
          (id, accountId, itemId, podcastEpisodeId, rssEpisodeId, position)
        SELECT id, accountId, itemId, podcastEpisodeId, NULL, position
        FROM listeningQueueEntry
        ORDER BY position, id
        """)
    let copiedCount =
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM listeningQueueEntry_v47") ?? -1
    guard copiedCount == sourceCount else {
      throw RSSListeningQueueMigrationError.copyCountMismatch(
        expected: sourceCount, actual: copiedCount)
    }
    try checkpoint(.afterCopy)

    try db.drop(table: "listeningQueueEntry")
    try checkpoint(.afterDrop)
    try db.rename(table: "listeningQueueEntry_v47", to: "listeningQueueEntry")

    // `belongsTo` names this implicit index from the temporary table. Restore the released table's
    // canonical index name after the rename so schema inspection does not retain a v47 artifact.
    try db.drop(index: "listeningQueueEntry_v47_on_accountId")
    try db.create(
      index: "listeningQueueEntry_on_accountId", on: "listeningQueueEntry",
      columns: ["accountId"])
    try db.create(
      index: "index_listeningQueueEntry_on_account_position", on: "listeningQueueEntry",
      columns: ["accountId", "position"], options: .unique)
    try db.create(
      index: "index_listeningQueueEntry_on_account_item", on: "listeningQueueEntry",
      columns: ["accountId", "itemId"], options: .unique,
      condition: Column("itemId") != nil && Column("podcastEpisodeId") == nil)
    try db.create(
      index: "index_listeningQueueEntry_on_account_episode", on: "listeningQueueEntry",
      columns: ["accountId", "podcastEpisodeId"], options: .unique,
      condition: Column("podcastEpisodeId") != nil)
    try db.create(
      index: "index_listeningQueueEntry_on_account_rss_episode", on: "listeningQueueEntry",
      columns: ["accountId", "rssEpisodeId"], options: .unique,
      condition: Column("rssEpisodeId") != nil)
    try checkpoint(.afterSwap)
  }
}
