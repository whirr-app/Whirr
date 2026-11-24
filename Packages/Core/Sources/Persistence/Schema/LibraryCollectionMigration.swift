import GRDB

/// v90: server collections and playlists, stored as ordered server ids per library.
/// Rows are drawn from the local catalogue at read time, so only ids and the list's own text are
/// kept. Every table cascades from `library`, so none has a direct key to `account` and
/// `AccountRemover.discoverAccountOwnedTables` correctly does not list them.
enum LibraryCollectionMigration {
  static func addTables(_ db: Database) throws {
    // One row per library and kind, so "fetched, none exist" differs from "never fetched".
    // Collections and playlists are fetched, and can fail, separately, hence the per-kind key.
    try db.create(table: "libraryCollectionSnapshot") { t in
      t.column("libraryId", .integer).notNull().references("library", onDelete: .cascade)
      t.column("kind", .text).notNull()
      t.column("fetchedAt", .datetime).notNull()
      t.primaryKey(["libraryId", "kind"])
    }
    try db.create(table: "libraryCollection") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("library", onDelete: .cascade).notNull()
      t.column("kind", .text).notNull()
      t.column("serverId", .text).notNull()
      t.column("name", .text)
      t.column("description", .text)
      t.column("lastUpdate", .datetime)
      t.uniqueKey(["libraryId", "kind", "serverId"])
    }
    try db.create(table: "libraryCollectionMember") { t in
      t.belongsTo("collection", inTable: "libraryCollection", onDelete: .cascade).notNull()
      t.column("position", .integer).notNull()
      t.column("serverItemId", .text).notNull()
      t.column("serverEpisodeId", .text)
      t.column("fallbackTitle", .text)
      t.primaryKey(["collectionId", "position"])
    }
  }
}
