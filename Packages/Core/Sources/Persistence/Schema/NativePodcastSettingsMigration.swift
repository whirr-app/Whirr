import GRDB

extension SchemaV1 {
  static func migrateNativePodcastSettings(_ db: Database) throws {
    try db.create(table: NativePodcastSettingsRecord.databaseTableName, ifNotExists: true) { t in
      t.column("id", .integer).primaryKey().check { $0 == 1 }
      t.column("autoDownloadEnabled", .boolean).notNull().defaults(to: false)
      t.column("keepLatestCount", .integer).notNull().defaults(to: 3).check { $0 >= 0 }
      t.column("deleteAfterPlayed", .boolean).notNull().defaults(to: false)
      t.column("allowCellularAutoDownload", .boolean).notNull().defaults(to: false)
      t.column("enabledAt", .datetime)
    }
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO nativePodcastSettings
        (id, autoDownloadEnabled, keepLatestCount, deleteAfterPlayed, allowCellularAutoDownload, enabledAt)
        SELECT 1, autoDownloadEnabled, keepLatestCount, deleteAfterPlayed, allowCellularAutoDownload, enabledAt
        FROM podcastSettings WHERE (SELECT COUNT(*) FROM podcastSettings) = 1
          AND (SELECT COUNT(*) FROM account) = 1
        """)
    try db.execute(
      sql: """
        INSERT OR IGNORE INTO nativePodcastSettings
        (id, autoDownloadEnabled, keepLatestCount, deleteAfterPlayed, allowCellularAutoDownload, enabledAt)
        VALUES (1, 0, 3, 0, 0, NULL)
        """)
  }
}
