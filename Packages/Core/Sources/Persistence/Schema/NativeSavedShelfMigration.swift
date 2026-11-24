import GRDB

extension SchemaV1 {
  enum RSSSavedShelfMigrationCheckpoint: Sendable, Equatable {
    case afterCopy, afterDrop, afterSwap
  }

  static func rebuildSavedShelfForNativeRSS(
    _ db: Database,
    checkpoint: @Sendable (RSSSavedShelfMigrationCheckpoint) throws -> Void
  ) throws {
    try db.create(table: "rssSavedShelfEntry") { t in
      t.autoIncrementedPrimaryKey("id")
      t.column("rssEpisodeId", .integer).notNull().references("rssEpisode", onDelete: .cascade)
      t.column("savedAt", .datetime).notNull()
      t.column("subjectTitle", .text).notNull().defaults(to: "")
      t.column("contextTitle", .text)
    }
    try db.create(
      index: "index_rssSavedShelfEntry_on_episode", on: "rssSavedShelfEntry",
      columns: ["rssEpisodeId"], options: .unique)

    try db.create(table: "savedShelfEntry_v60") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("itemId", .integer).notNull()
      t.column("podcastEpisodeId", .integer)
      t.column("savedAt", .datetime).notNull()
      t.column("subjectTitle", .text).notNull().defaults(to: "")
      t.column("contextTitle", .text)
      t.check(sql: "itemId IS NOT NULL")
      t.foreignKey(["accountId", "itemId"], references: "item", columns: ["accountId", "id"], onDelete: .cascade)
      t.foreignKey(
        ["accountId", "podcastEpisodeId"], references: "podcastEpisode", columns: ["accountId", "id"],
        onDelete: .cascade)
    }
    let sourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM savedShelfEntry") ?? 0
    let rssCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM savedShelfEntry WHERE rssEpisodeId IS NOT NULL") ?? 0
    try db.execute(
      sql: """
        INSERT INTO rssSavedShelfEntry (id, rssEpisodeId, savedAt, subjectTitle, contextTitle)
        SELECT id, rssEpisodeId, savedAt, subjectTitle, contextTitle
        FROM savedShelfEntry WHERE rssEpisodeId IS NOT NULL ORDER BY id
        """)
    try db.execute(
      sql: """
        INSERT INTO savedShelfEntry_v60 (id, accountId, itemId, podcastEpisodeId, savedAt, subjectTitle, contextTitle)
        SELECT id, accountId, itemId, podcastEpisodeId, savedAt, subjectTitle, contextTitle
        FROM savedShelfEntry WHERE itemId IS NOT NULL ORDER BY id
        """)
    let copiedABS = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM savedShelfEntry_v60") ?? -1
    let copiedRSS = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rssSavedShelfEntry") ?? -1
    try validateSavedShelfCopyCount(expected: sourceCount - rssCount, actual: copiedABS)
    try validateSavedShelfCopyCount(expected: rssCount, actual: copiedRSS)
    try checkpoint(.afterCopy)
    for trigger in [
      "savedShelfProgress_ai", "savedShelfProgress_au", "savedShelfRSSProgress_ai", "savedShelfRSSProgress_au",
    ] {
      try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
    }
    try db.drop(table: "savedShelfEntry")
    try checkpoint(.afterDrop)
    try db.rename(table: "savedShelfEntry_v60", to: "savedShelfEntry")
    try db.drop(index: "savedShelfEntry_v60_on_accountId")
    try db.create(index: "savedShelfEntry_on_accountId", on: "savedShelfEntry", columns: ["accountId"])
    try db.create(
      index: "index_savedShelfEntry_on_account_item", on: "savedShelfEntry", columns: ["accountId", "itemId"],
      options: .unique, condition: Column("podcastEpisodeId") == nil)
    try db.create(
      index: "index_savedShelfEntry_on_account_episode", on: "savedShelfEntry",
      columns: ["accountId", "podcastEpisodeId"], options: .unique, condition: Column("podcastEpisodeId") != nil)
    try db.create(
      index: "index_savedShelfEntry_on_account_savedAt", on: "savedShelfEntry", columns: ["accountId", "savedAt"])
    for trigger in [
      "savedShelfProgress_ai", "savedShelfProgress_au", "savedShelfRSSProgress_ai", "savedShelfRSSProgress_au",
    ] {
      try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
    }
    try createSavedShelfResolutionTriggers(db)
    for trigger in ["savedShelfRSSProgress_ai", "savedShelfRSSProgress_au"] {
      try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
    }
    try db.execute(
      sql: """
        CREATE TRIGGER savedShelfRSSProgress_ai AFTER INSERT ON rssEpisodeState
        WHEN COALESCE(NEW.position, 0) > 0 OR NEW.finished = 1
        BEGIN DELETE FROM rssSavedShelfEntry WHERE rssEpisodeId = NEW.episodeId; END
        """)
    try db.execute(
      sql: """
        CREATE TRIGGER savedShelfRSSProgress_au AFTER UPDATE OF position, finished ON rssEpisodeState
        WHEN (COALESCE(NEW.position, 0) > 0 AND NEW.position IS NOT OLD.position)
          OR (NEW.finished = 1 AND OLD.finished = 0)
        BEGIN DELETE FROM rssSavedShelfEntry WHERE rssEpisodeId = NEW.episodeId; END
        """)
    try checkpoint(.afterSwap)
  }

}
