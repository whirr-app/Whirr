import GRDB

/// Home's projections that need stored state: the progress activity stamp that orders its
/// carousels (`v26`) and the per-cover palette record its cards read (`v27`).
///
/// Registered by `SchemaV1.registerEra2`; `SchemaV1.migrator()` holds the order. The bodies are
/// frozen: an applied migration is never edited in place.
extension SchemaV1 {

  // MARK: - v26: media progress activity stamp

  /// v26's backfill, shared by the migration and its test.
  static func backfillActivityStamps(_ db: Database) throws {
    try db.execute(
      sql: "UPDATE mediaProgress SET lastActivityAt = serverUpdatedAt WHERE lastActivityAt IS NULL")
  }

  // MARK: - v27: cover palette record

  static func createCoverPaletteRecord(_ db: Database) throws {
    try db.create(table: "coverPaletteRecord") { t in
      t.column("itemId", .text).primaryKey()
      t.column("artworkKey", .text).notNull()
      t.column("accentHue", .double)
      t.column("accentSaturation", .double)
      t.column("accentBrightness", .double)
      t.column("extractedAt", .datetime).notNull()
    }
  }
}
