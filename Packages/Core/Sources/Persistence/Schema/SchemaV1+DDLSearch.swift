import GRDB

/// The full-text search index: the `v10` FTS5 tables and their triggers, recent searches
/// (`v11`), the guarded `item` update trigger that replaced `v10`'s (`v64`), and the plain-text
/// episode index (`v83`).
///
/// Registered by `SchemaV1.registerEra1`, `registerEra4` and `registerEra5`; `SchemaV1.migrator()`
/// holds the order. `itemSearchUpdateTriggerSQL` is read by `registerEra4`; `registerEra5` calls
/// `reindexEpisodeSearchAsPlainText`, which installs `episodeSearchPlainTextTriggerSQL`.
///
/// The bodies are frozen: an applied migration is never edited in place.
extension SchemaV1 {

  // MARK: - v10: FTS5 index and its item and episode triggers

  /// Creates `itemSearch`/`episodeSearch`, the six triggers that keep them in sync with
  /// `item`/`podcastEpisode`, and populates them once over rows that already existed. This is the
  /// only bulk build of the index; every later write goes through the triggers (rule 16).
  ///
  /// Both tables are external-content (`content_rowid: "id"`); `item.id`/`podcastEpisode.id` are
  /// `INTEGER PRIMARY KEY`, an alias for `rowid` (the server id lives in
  /// `serverItemId`/`serverEpisodeId`).
  ///
  /// FTS5 keeps no copy of the text: whatever a trigger inserts is tokenised, here the
  /// `searchFold`-folded text, not the raw columns. A plain `SELECT` (no `MATCH`) reads through
  /// to `item`/`podcastEpisode` by rowid; nothing queries these tables that way.
  ///
  /// Every insert/delete against the index is guarded by the row's own `softDeleted`, on both
  /// sides of an `UPDATE`: the `'delete'` command for a rowid never indexed (soft-deleted the whole
  /// time) does not no-op but reports corruption (`database disk image is malformed`).
  static func createSearchIndex(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE VIRTUAL TABLE itemSearch USING fts5(
          title, author, seriesName, narratorName,
          content='item', content_rowid='id'
        )
        """)
    try db.execute(
      sql: """
        CREATE VIRTUAL TABLE episodeSearch USING fts5(
          title, subtitle, episodeDescription,
          content='podcastEpisode', content_rowid='id'
        )
        """)

    try createItemSearchTriggers(db)
    try createEpisodeSearchTriggers(db)

    // One-off population over rows that already exist (rule 16).
    try db.execute(
      sql: """
        INSERT INTO itemSearch(rowid, title, author, seriesName, narratorName)
        SELECT id, searchFold(title), searchFold(author), searchFold(seriesName),
          searchFold(narratorName)
        FROM item
        WHERE softDeleted = 0
        """)
    try db.execute(
      sql: """
        INSERT INTO episodeSearch(rowid, title, subtitle, episodeDescription)
        SELECT id, searchFold(title), searchFold(subtitle), searchFold(episodeDescription)
        FROM podcastEpisode
        WHERE softDeleted = 0
        """)
  }

  /// `AFTER INSERT`/`AFTER UPDATE`/`AFTER DELETE` on `item`. Each `SELECT ... WHERE` stops the
  /// statement firing when the row is (or was) soft-deleted, so the trigger never mutates the
  /// index for a rowid that was never indexed (see `createSearchIndex`). `AFTER UPDATE` removes
  /// the old entry before adding the new one, since SQLite has no cheaper way to replace an
  /// external-content FTS5 row's indexed text.
  private static func createItemSearchTriggers(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TRIGGER itemSearch_ai AFTER INSERT ON item BEGIN
          INSERT INTO itemSearch(rowid, title, author, seriesName, narratorName)
          SELECT new.id, searchFold(new.title), searchFold(new.author),
            searchFold(new.seriesName), searchFold(new.narratorName)
          WHERE new.softDeleted = 0;
        END
        """)
    try db.execute(
      sql: """
        CREATE TRIGGER itemSearch_ad AFTER DELETE ON item BEGIN
          INSERT INTO itemSearch(itemSearch, rowid, title, author, seriesName, narratorName)
          SELECT 'delete', old.id, searchFold(old.title), searchFold(old.author),
            searchFold(old.seriesName), searchFold(old.narratorName)
          WHERE old.softDeleted = 0;
        END
        """)
    // The unguarded form. Migration v64 replaces it with `itemSearchUpdateTriggerSQL`; an applied
    // migration is never edited in place.
    try db.execute(
      sql: """
        CREATE TRIGGER itemSearch_au AFTER UPDATE ON item BEGIN
          INSERT INTO itemSearch(itemSearch, rowid, title, author, seriesName, narratorName)
          SELECT 'delete', old.id, searchFold(old.title), searchFold(old.author),
            searchFold(old.seriesName), searchFold(old.narratorName)
          WHERE old.softDeleted = 0;
          INSERT INTO itemSearch(rowid, title, author, seriesName, narratorName)
          SELECT new.id, searchFold(new.title), searchFold(new.author),
            searchFold(new.seriesName), searchFold(new.narratorName)
          WHERE new.softDeleted = 0;
        END
        """)
  }

  /// The `podcastEpisode` counterpart of `createItemSearchTriggers`, over the episode's own
  /// `softDeleted` only. Excluding episodes whose show is soft-deleted is a query-time join, not
  /// this index's concern. This is the `v10` form; `v83` replaces all three with
  /// `episodeSearchPlainTextTriggerSQL`, and an applied migration is never edited in place.
  private static func createEpisodeSearchTriggers(_ db: Database) throws {
    try db.execute(
      sql: """
        CREATE TRIGGER episodeSearch_ai AFTER INSERT ON podcastEpisode BEGIN
          INSERT INTO episodeSearch(rowid, title, subtitle, episodeDescription)
          SELECT new.id, searchFold(new.title), searchFold(new.subtitle),
            searchFold(new.episodeDescription)
          WHERE new.softDeleted = 0;
        END
        """)
    try db.execute(
      sql: """
        CREATE TRIGGER episodeSearch_ad AFTER DELETE ON podcastEpisode BEGIN
          INSERT INTO episodeSearch(episodeSearch, rowid, title, subtitle, episodeDescription)
          SELECT 'delete', old.id, searchFold(old.title), searchFold(old.subtitle),
            searchFold(old.episodeDescription)
          WHERE old.softDeleted = 0;
        END
        """)
    try db.execute(
      sql: """
        CREATE TRIGGER episodeSearch_au AFTER UPDATE ON podcastEpisode BEGIN
          INSERT INTO episodeSearch(episodeSearch, rowid, title, subtitle, episodeDescription)
          SELECT 'delete', old.id, searchFold(old.title), searchFold(old.subtitle),
            searchFold(old.episodeDescription)
          WHERE old.softDeleted = 0;
          INSERT INTO episodeSearch(rowid, title, subtitle, episodeDescription)
          SELECT new.id, searchFold(new.title), searchFold(new.subtitle),
            searchFold(new.episodeDescription)
          WHERE new.softDeleted = 0;
        END
        """)
  }

  // MARK: - v11: recent searches

  /// `normalizedQuery` is unique per account so `RecentSearchStore.record` can upsert
  /// ("Gaiman"/"gaiman " collapse to one row) with a single `INSERT ... ON CONFLICT` instead of a
  /// read-then-write race. `displayQuery` is the as-typed text shown in the recents list;
  /// `lastUsedAt` orders it and drives the store's cap-10 eviction.
  static func createRecentSearch(_ db: Database) throws {
    try db.create(table: "recentSearch") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("normalizedQuery", .text).notNull()
      t.column("displayQuery", .text).notNull()
      t.column("lastUsedAt", .datetime).notNull()
    }
    try db.create(
      index: "index_recentSearch_on_account_normalizedQuery", on: "recentSearch",
      columns: ["accountId", "normalizedQuery"], options: .unique)
    // Eviction/observation order: most-recently-used first, per account.
    try db.create(
      index: "index_recentSearch_on_account_lastUsedAt", on: "recentSearch",
      columns: ["accountId", "lastUsedAt"])
  }

  // MARK: - v64: guarded item update trigger

  /// The `AFTER UPDATE` half of `createItemSearchTriggers`, shared with the migration that
  /// re-creates it.
  ///
  /// The `WHEN` stops a traversal re-indexing unchanged rows, which would cost eight
  /// `searchFold()` calls plus an FTS delete/insert pair per rewrite.
  ///
  /// `softDeleted` must be in the guard with the four indexed columns: this trigger also removes a
  /// soft-deleted row from the index and re-inserts a revived one (the `WHERE ... softDeleted = 0`
  /// clauses), and deletion pass one and `applyPage` revival change only `softDeleted`. A
  /// text-only guard would leave deleted items searchable and revived ones unsearchable.
  static let itemSearchUpdateTriggerSQL = """
    CREATE TRIGGER itemSearch_au AFTER UPDATE ON item
    WHEN old.softDeleted IS NOT new.softDeleted
      OR old.title IS NOT new.title
      OR old.author IS NOT new.author
      OR old.seriesName IS NOT new.seriesName
      OR old.narratorName IS NOT new.narratorName
    BEGIN
      INSERT INTO itemSearch(itemSearch, rowid, title, author, seriesName, narratorName)
      SELECT 'delete', old.id, searchFold(old.title), searchFold(old.author),
        searchFold(old.seriesName), searchFold(old.narratorName)
      WHERE old.softDeleted = 0;
      INSERT INTO itemSearch(rowid, title, author, seriesName, narratorName)
      SELECT new.id, searchFold(new.title), searchFold(new.author),
        searchFold(new.seriesName), searchFold(new.narratorName)
      WHERE new.softDeleted = 0;
    END
    """

  // MARK: - v83: plain-text episode index

  /// The `v83` episode triggers: the `v10` three with the description run through
  /// `searchPlainText` before `searchFold`, so the index holds words, not markup. The delete
  /// trigger and the update trigger's delete half must fold what the insert folded: the
  /// external-content `'delete'` command removes by text and a mismatch is index corruption
  /// (`createSearchIndex`). So all three live here and the `v83` rebuild uses the same expression.
  static let episodeSearchPlainTextTriggerSQL: [String] = [
    """
    CREATE TRIGGER episodeSearch_ai AFTER INSERT ON podcastEpisode BEGIN
      INSERT INTO episodeSearch(rowid, title, subtitle, episodeDescription)
      SELECT new.id, searchFold(new.title), searchFold(new.subtitle),
        searchFold(searchPlainText(new.episodeDescription))
      WHERE new.softDeleted = 0;
    END
    """,
    """
    CREATE TRIGGER episodeSearch_ad AFTER DELETE ON podcastEpisode BEGIN
      INSERT INTO episodeSearch(episodeSearch, rowid, title, subtitle, episodeDescription)
      SELECT 'delete', old.id, searchFold(old.title), searchFold(old.subtitle),
        searchFold(searchPlainText(old.episodeDescription))
      WHERE old.softDeleted = 0;
    END
    """,
    """
    CREATE TRIGGER episodeSearch_au AFTER UPDATE ON podcastEpisode BEGIN
      INSERT INTO episodeSearch(episodeSearch, rowid, title, subtitle, episodeDescription)
      SELECT 'delete', old.id, searchFold(old.title), searchFold(old.subtitle),
        searchFold(searchPlainText(old.episodeDescription))
      WHERE old.softDeleted = 0;
      INSERT INTO episodeSearch(rowid, title, subtitle, episodeDescription)
      SELECT new.id, searchFold(new.title), searchFold(new.subtitle),
        searchFold(searchPlainText(new.episodeDescription))
      WHERE new.softDeleted = 0;
    END
    """,
  ]

  /// Replaces the `v10` episode triggers with `episodeSearchPlainTextTriggerSQL` and rebuilds the
  /// episode index to match. The rebuild is the `createSearchIndex` population again under the new
  /// expression: `'delete-all'` empties an external-content index without needing the old text,
  /// then every live episode is folded afresh. The item index is untouched.
  static func reindexEpisodeSearchAsPlainText(_ db: Database) throws {
    for trigger in ["episodeSearch_ai", "episodeSearch_ad", "episodeSearch_au"] {
      try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
    }
    for sql in episodeSearchPlainTextTriggerSQL {
      try db.execute(sql: sql)
    }
    try db.execute(sql: "INSERT INTO episodeSearch(episodeSearch) VALUES('delete-all')")
    try db.execute(
      sql: """
        INSERT INTO episodeSearch(rowid, title, subtitle, episodeDescription)
        SELECT id, searchFold(title), searchFold(subtitle),
          searchFold(searchPlainText(episodeDescription))
        FROM podcastEpisode
        WHERE softDeleted = 0
        """)
  }
}
