import GRDB

/// The reading tables: durable audiobook chapters (`v17`), ebook position and file identity
/// (`v18`), reader preferences (`v20`) and the flattened ebook table of contents (`v24`).
///
/// Registered by `SchemaV1.registerEra1` and `registerEra2`; `SchemaV1.migrator()` holds the order.
/// The bodies are frozen: an applied migration is never edited in place.
extension SchemaV1 {

  // MARK: - v17: durable audiobook chapters

  static func createItemChapter(_ db: Database) throws {
    try db.create(table: "itemChapter") { t in
      t.autoIncrementedPrimaryKey("id")
      t.column("accountId", .integer).notNull()
      t.column("itemId", .integer).notNull()
      t.column("position", .integer).notNull()
      t.column("serverChapterId", .integer).notNull()
      t.column("start", .double).notNull()
      t.column("end", .double).notNull()
      t.column("title", .text)
      t.foreignKey(
        ["accountId", "itemId"], references: "item", columns: ["accountId", "id"],
        onDelete: .cascade)
    }
    try db.create(
      index: "index_itemChapter_on_account_item_position", on: "itemChapter",
      columns: ["accountId", "itemId", "position"], options: .unique)
  }

  // MARK: - v18: ebook progress and file identity

  static func addEbookPersistence(_ db: Database) throws {
    try db.alter(table: "mediaProgress") { t in
      t.add(column: "readingPositionJSON", .text)
      t.add(column: "ebookProgress", .double)
      t.add(column: "ebookLocation", .text)
    }
    try db.alter(table: "item") { t in
      t.add(column: "ebookFileIno", .text)
      t.add(column: "ebookFileExt", .text)
    }
  }

  // MARK: - v20: reader preferences

  static func createReaderPreferences(_ db: Database) throws {
    try db.create(table: "readerPreferences") { t in
      t.column("accountId", .integer).primaryKey().references("account", onDelete: .cascade)
      t.column("preferencesJSON", .text).notNull()
    }
  }

  // MARK: - v24: durable ebook table of contents

  static func createEbookTOCEntry(_ db: Database) throws {
    try db.create(table: "ebookTOCEntry") { t in
      t.autoIncrementedPrimaryKey("id")
      t.column("accountId", .integer).notNull()
      t.column("itemId", .integer).notNull()
      t.column("position", .integer).notNull()
      t.column("title", .text).notNull()
      t.column("href", .text)
      t.column("depth", .integer).notNull()
      t.column("startProgression", .double)
      t.foreignKey(
        ["accountId", "itemId"], references: "item", columns: ["accountId", "id"],
        onDelete: .cascade)
    }
    try db.create(
      index: "index_ebookTOCEntry_on_account_item_position", on: "ebookTOCEntry",
      columns: ["accountId", "itemId", "position"], options: .unique)
  }
}
