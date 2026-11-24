import GRDB

/// The Saved for Later shelf and the triggers that resolve an entry once its identity is started,
/// finished or removed: the account-owned table (`v34`), its progress triggers (`v36`), the
/// rebuild that adds device-owned RSS episodes (`v53`), and the resolution triggers `v56` replaces
/// them with (`v60`'s rebuild re-creates the same set).
///
/// Registered by `SchemaV1.registerEra2` and `registerEra3`; `SchemaV1.migrator()` holds the order.
/// The bodies are frozen: an applied migration is never edited in place.
extension SchemaV1 {

  // MARK: - v34: saved shelf entries

  static func createSavedShelfEntry(_ db: Database) throws {
    try db.create(table: "savedShelfEntry") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("itemId", .integer).notNull()
      t.column("podcastEpisodeId", .integer)
      t.column("savedAt", .datetime).notNull()

      t.foreignKey(
        ["accountId", "itemId"], references: "item",
        columns: ["accountId", "id"], onDelete: .cascade)
      t.foreignKey(
        ["accountId", "podcastEpisodeId"], references: "podcastEpisode",
        columns: ["accountId", "id"], onDelete: .cascade)
    }

    try db.create(
      index: "index_savedShelfEntry_on_account_item", on: "savedShelfEntry",
      columns: ["accountId", "itemId"], options: .unique,
      condition: Column("podcastEpisodeId") == nil)
    try db.create(
      index: "index_savedShelfEntry_on_account_episode", on: "savedShelfEntry",
      columns: ["accountId", "podcastEpisodeId"], options: .unique,
      condition: Column("podcastEpisodeId") != nil)
    try db.create(
      index: "index_savedShelfEntry_on_account_savedAt", on: "savedShelfEntry",
      columns: ["accountId", "savedAt"])
  }

  // MARK: - v36: saved-shelf progress triggers

  static func createSavedShelfProgressTriggers(_ db: Database) throws {
    let removal = """
      DELETE FROM savedShelfEntry
      WHERE accountId = NEW.accountId
        AND itemId = NEW.itemId
        AND (
          (NEW.podcastEpisodeId IS NULL AND podcastEpisodeId IS NULL)
          OR podcastEpisodeId = NEW.podcastEpisodeId
        );
      """
    try db.execute(
      sql: """
        CREATE TRIGGER savedShelfProgress_ai
        AFTER INSERT ON mediaProgress
        WHEN COALESCE(NEW.currentTime, 0) > 0 OR COALESCE(NEW.ebookProgress, 0) > 0
        BEGIN
          \(removal)
        END
        """)
    try db.execute(
      sql: """
        CREATE TRIGGER savedShelfProgress_au
        AFTER UPDATE OF currentTime, ebookProgress, readingPositionJSON ON mediaProgress
        WHEN (COALESCE(NEW.currentTime, 0) > 0 OR COALESCE(NEW.ebookProgress, 0) > 0)
          AND (
            NEW.currentTime IS NOT OLD.currentTime
            OR NEW.ebookProgress IS NOT OLD.ebookProgress
            OR NEW.readingPositionJSON IS NOT OLD.readingPositionJSON
          )
        BEGIN
          \(removal)
        END
        """)
  }

  // MARK: - v53: saved shelf with device-owned RSS episodes

  static func rebuildSavedShelfForRSS(_ db: Database) throws {
    try db.create(table: "savedShelfEntry_v53") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("itemId", .integer)
      t.column("podcastEpisodeId", .integer)
      t.column("rssEpisodeId", .integer).references("rssEpisode", onDelete: .cascade)
      t.column("savedAt", .datetime).notNull()
      t.column("subjectTitle", .text).notNull().defaults(to: "")
      t.column("contextTitle", .text)

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

    let sourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM savedShelfEntry") ?? 0
    try db.execute(
      sql: """
        INSERT INTO savedShelfEntry_v53
          (id, accountId, itemId, podcastEpisodeId, rssEpisodeId, savedAt, subjectTitle, contextTitle)
        SELECT id, accountId, itemId, podcastEpisodeId, NULL, savedAt, subjectTitle, contextTitle
        FROM savedShelfEntry
        ORDER BY id
        """)
    let copiedCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM savedShelfEntry_v53") ?? -1
    try validateSavedShelfCopyCount(expected: sourceCount, actual: copiedCount)

    try db.drop(table: "savedShelfEntry")
    try db.rename(table: "savedShelfEntry_v53", to: "savedShelfEntry")

    // `belongsTo` names this implicit index from the temporary table. Restore the released table's
    // canonical index name after the rename so schema inspection does not retain a v53 artifact.
    try db.drop(index: "savedShelfEntry_v53_on_accountId")
    try db.create(
      index: "savedShelfEntry_on_accountId", on: "savedShelfEntry", columns: ["accountId"])
    // The whole-item index states `itemId IS NOT NULL` explicitly. An RSS row leaves both ABS
    // columns null and would otherwise fall inside this partial index, relying on SQLite treating
    // index NULLs as distinct to avoid a false collision.
    try db.create(
      index: "index_savedShelfEntry_on_account_item", on: "savedShelfEntry",
      columns: ["accountId", "itemId"], options: .unique,
      condition: Column("podcastEpisodeId") == nil && Column("itemId") != nil)
    try db.create(
      index: "index_savedShelfEntry_on_account_episode", on: "savedShelfEntry",
      columns: ["accountId", "podcastEpisodeId"], options: .unique,
      condition: Column("podcastEpisodeId") != nil)
    try db.create(
      index: "index_savedShelfEntry_on_account_savedAt", on: "savedShelfEntry",
      columns: ["accountId", "savedAt"])
    try db.create(
      index: "index_savedShelfEntry_on_account_rss_episode", on: "savedShelfEntry",
      columns: ["accountId", "rssEpisodeId"], options: .unique,
      condition: Column("rssEpisodeId") != nil)

    try db.execute(
      sql: """
        CREATE TRIGGER savedShelfRSSProgress_ai
        AFTER INSERT ON rssEpisodeState
        WHEN COALESCE(NEW.position, 0) > 0
        BEGIN
          DELETE FROM savedShelfEntry WHERE rssEpisodeId = NEW.episodeId;
        END
        """)
    try db.execute(
      sql: """
        CREATE TRIGGER savedShelfRSSProgress_au
        AFTER UPDATE OF position ON rssEpisodeState
        WHEN COALESCE(NEW.position, 0) > 0
          AND NEW.position IS NOT OLD.position
        BEGIN
          DELETE FROM savedShelfEntry WHERE rssEpisodeId = NEW.episodeId;
        END
        """)
  }

  // MARK: - v56: saved-shelf resolution triggers, re-created by v60's rebuild

  /// v56's trigger set. Every row-level removal targets the exact saved identity: an item-level
  /// progress row clears only the whole-item save, an episode row clears only that episode, and an
  /// RSS state row clears only that device-owned episode. The finish clauses fire only on an
  /// insert that is already finished or a false to true transition, so a repeated finished write,
  /// hydration of an already-finished row, or a reset never touches a save made after completion.
  static func createSavedShelfResolutionTriggers(_ db: Database) throws {
    let removal = """
      DELETE FROM savedShelfEntry
      WHERE accountId = NEW.accountId
        AND itemId = NEW.itemId
        AND (
          (NEW.podcastEpisodeId IS NULL AND podcastEpisodeId IS NULL)
          OR podcastEpisodeId = NEW.podcastEpisodeId
        );
      """
    try db.execute(
      sql: """
        CREATE TRIGGER savedShelfProgress_ai
        AFTER INSERT ON mediaProgress
        WHEN COALESCE(NEW.currentTime, 0) > 0
          OR COALESCE(NEW.ebookProgress, 0) > 0
          OR NEW.isFinished = 1
        BEGIN
          \(removal)
        END
        """)
    try db.execute(
      sql: """
        CREATE TRIGGER savedShelfProgress_au
        AFTER UPDATE OF currentTime, ebookProgress, readingPositionJSON, isFinished ON mediaProgress
        WHEN (
            (COALESCE(NEW.currentTime, 0) > 0 OR COALESCE(NEW.ebookProgress, 0) > 0)
            AND (
              NEW.currentTime IS NOT OLD.currentTime
              OR NEW.ebookProgress IS NOT OLD.ebookProgress
              OR NEW.readingPositionJSON IS NOT OLD.readingPositionJSON
            )
          )
          OR (NEW.isFinished = 1 AND OLD.isFinished = 0)
        BEGIN
          \(removal)
        END
        """)
    try db.execute(
      sql: """
        CREATE TRIGGER savedShelfRSSProgress_ai
        AFTER INSERT ON rssEpisodeState
        WHEN COALESCE(NEW.position, 0) > 0 OR NEW.finished = 1
        BEGIN
          DELETE FROM savedShelfEntry WHERE rssEpisodeId = NEW.episodeId;
        END
        """)
    try db.execute(
      sql: """
        CREATE TRIGGER savedShelfRSSProgress_au
        AFTER UPDATE OF position, finished ON rssEpisodeState
        WHEN (COALESCE(NEW.position, 0) > 0 AND NEW.position IS NOT OLD.position)
          OR (NEW.finished = 1 AND OLD.finished = 0)
        BEGIN
          DELETE FROM savedShelfEntry WHERE rssEpisodeId = NEW.episodeId;
        END
        """)
  }
}
