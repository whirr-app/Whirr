import GRDB

/// v104: the phone's desired set of native-RSS episodes sent to the active Watch (ADR 0019)
/// plus the one-row set state an offer and an inventory share.
///
/// Both tables are device-owned: no account foreign key, no cloud dirty-log triggers, absent from
/// iCloud sync (`PodcastCloudProjectingApplier` names its tables) and from `.whirrpodcasts.json`
/// backups (`NativePodcastBackupReader` reads explicit tables). A copy cascades with its episode,
/// so an unfollow or a prune takes it with the row it describes.
enum RSSWatchCopyMigration {
  static func migrate(_ db: Database) throws {
    try db.create(table: "rssWatchCopy") { t in
      t.column("episodeId", .integer).primaryKey().references("rssEpisode", onDelete: .cascade)
      t.column("watchInstallID", .text)
      t.column("revision", .integer).notNull()
      t.check(sql: "revision >= 1")
      t.column("state", .text).notNull()
      // Frozen with the two phone-transfer states v104 shipped with; v105 rewrites any row still
      // holding one, and no current code writes them.
      t.check(
        sql:
          """
          state IN ('wanted', 'waitingForDownload', 'waitingForWatch', 'sending', 'delivering', \
          'delivered', 'removed', 'declined', 'failed')
          """)
      t.column("removedBy", .text)
      t.check(sql: "removedBy IS NULL OR removedBy IN ('phone', 'watch')")
      t.check(sql: "(state = 'removed') = (removedBy IS NOT NULL)")
      t.column("declineReason", .text)
      t.check(
        sql: "declineReason IS NULL OR declineReason IN ('storageFull', 'invalid', 'signedOut')")
      t.check(sql: "(state = 'declined') = (declineReason IS NOT NULL)")
      t.column("sourceBytes", .integer)
      t.column("requestedAt", .datetime).notNull()
      t.column("updatedAt", .datetime).notNull()
      t.column("failedAt", .datetime)
    }
    try db.create(
      index: "index_rssWatchCopy_on_state", on: "rssWatchCopy", columns: ["state"])

    // One row, created here, so a read never has to distinguish "no set yet" from "generation 0".
    try db.create(table: "rssWatchCopySet") { t in
      t.column("id", .integer).primaryKey()
      t.check(sql: "id = 1")
      t.column("watchInstallID", .text)
      t.column("generation", .integer).notNull().defaults(to: 0)
      t.column("acknowledgedGeneration", .integer).notNull().defaults(to: 0)
      t.column("inventorySequence", .integer).notNull().defaults(to: 0)
      t.column("acceptsCopies", .boolean)
      t.column("budgetTotalBytes", .integer)
      t.column("budgetUsedBytes", .integer)
      t.column("lastInventoryAt", .datetime)
    }
    try db.execute(sql: "INSERT INTO rssWatchCopySet (id) VALUES (1)")
  }
}
