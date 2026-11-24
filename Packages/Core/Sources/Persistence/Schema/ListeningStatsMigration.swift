import GRDB

/// v88: one cached listening-stats snapshot per account. The row holds derived figures, already
/// trimmed by `SyncEngine`, so its three payload columns stay small: JSON text rather than child
/// tables, because the row is only ever replaced and read whole.
enum ListeningStatsMigration {
  static func addSnapshot(_ db: Database) throws {
    try db.create(table: "listeningStatsSnapshot") { t in
      t.primaryKey("accountId", .integer).references("account", onDelete: .cascade)
      t.column("fetchedAt", .datetime).notNull()
      t.column("totalSeconds", .double).notNull()
      t.column("daysJSON", .text).notNull()
      t.column("weekdaysJSON", .text).notNull()
      t.column("titlesJSON", .text).notNull()
    }
  }
}
