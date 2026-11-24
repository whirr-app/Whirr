import GRDB

/// v91: device-local pins on collections and playlists. Keyed by server identity, never by
/// `libraryCollection.id`, which every refresh replaces. Every table keys `account` directly, so
/// account removal discovers them.
///
/// `serverEpisodeId` is `''` for a book: SQLite treats NULLs in a primary key as distinct.
enum PinnedListMigration {
  static func addTables(_ db: Database) throws {
    try db.create(table: "pinnedList") { t in
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("serverLibraryId", .text).notNull()
      t.column("kind", .text).notNull()
      t.column("serverId", .text).notNull()
      t.column("pinnedAt", .datetime).notNull()
      t.primaryKey(["accountId", "serverLibraryId", "kind", "serverId"])
    }
    for table in ["pinnedListClaim", "pinnedListDecline"] {
      try db.create(table: table) { t in
        t.belongsTo("account", onDelete: .cascade).notNull()
        t.column("serverLibraryId", .text).notNull()
        t.column("kind", .text).notNull()
        t.column("serverId", .text).notNull()
        t.column("serverItemId", .text).notNull()
        t.column("serverEpisodeId", .text).notNull()
        t.column("recordedAt", .datetime).notNull()
        t.primaryKey(["accountId", "serverLibraryId", "kind", "serverId", "serverItemId", "serverEpisodeId"])
        t.foreignKey(
          ["accountId", "serverLibraryId", "kind", "serverId"], references: "pinnedList",
          columns: ["accountId", "serverLibraryId", "kind", "serverId"], onDelete: .cascade)
      }
    }
  }
}
