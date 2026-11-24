import GRDB

/// v106: the phone's desired set of Audiobookshelf books and episodes for the active Watch
/// (ADR 0021), and the Audiobookshelf half of the shared set row.
///
/// The copies are account-owned: `accountId` cascades from `account`, so `AccountRemover` deletes
/// them on sign-out with no code of its own. They have no foreign key to `item`, because library
/// sync can prune an item the Watch still holds and plays. Like `rssWatchCopy` they stay out of
/// iCloud sync and backups. Each row keeps the title and subtitle the offer names, since the item
/// may be gone from the library when the next offer is built.
///
/// The set row stays device-owned. Its Audiobookshelf columns sit beside the RSS ones because one
/// Watch install, one budget and one inventory stream serve both, but the two offers
/// travel on separate keys, so each keeps its own generation, acknowledgement, sequence and install.
/// `absInventoryAccountHash` names the account the last applied inventory was stamped with: the
/// phone sends no offer for an account until it matches.
enum ABSWatchCopyMigration {
  static func migrate(_ db: Database) throws {
    try db.create(table: "absWatchCopy") { t in
      t.column("accountId", .integer).notNull().references("account", onDelete: .cascade)
      t.column("itemId", .text).notNull()
      // '' for a book, so the key holds no NULL.
      t.column("episodeId", .text).notNull().defaults(to: "")
      t.primaryKey(["accountId", "itemId", "episodeId"])
      t.column("title", .text).notNull()
      t.column("subtitle", .text)
      t.column("watchInstallID", .text)
      t.column("revision", .integer).notNull()
      t.check(sql: "revision >= 1")
      t.column("state", .text).notNull()
      t.check(
        sql:
          """
          state IN ('wanted', 'waitingForWatch', 'sending', 'delivered', 'removed', 'declined', \
          'failed')
          """)
      t.column("removedBy", .text)
      t.check(sql: "removedBy IS NULL OR removedBy IN ('phone', 'watch')")
      t.check(sql: "(state = 'removed') = (removedBy IS NOT NULL)")
      // The generation that first carried the phone's removal; cleared once an inventory
      // acknowledges it.
      t.column("removalGeneration", .integer)
      t.check(sql: "removalGeneration IS NULL OR removedBy = 'phone'")
      t.column("declineReason", .text)
      t.check(
        sql: "declineReason IS NULL OR declineReason IN ('storageFull', 'invalid', 'signedOut')")
      t.check(sql: "(state = 'declined') = (declineReason IS NOT NULL)")
      t.column("failureReason", .text)
      t.check(
        sql:
          """
          failureReason IS NULL OR failureReason IN ('httpStatus', 'insecureRedirect', 'tooLarge', \
          'invalidResponse', 'network', 'itemMissing', 'noAudio', 'planInvalid')
          """)
      t.check(sql: "failureReason IS NULL OR state = 'failed'")
      t.column("declaredBytes", .integer)
      t.column("sourceBytes", .integer)
      t.column("requestedAt", .datetime).notNull()
      t.column("updatedAt", .datetime).notNull()
      t.column("failedAt", .datetime)
    }

    try db.alter(table: "rssWatchCopySet") { t in
      t.add(column: "absGeneration", .integer).notNull().defaults(to: 0)
      t.add(column: "absAcknowledgedGeneration", .integer).notNull().defaults(to: 0)
      t.add(column: "absInventorySequence", .integer).notNull().defaults(to: 0)
      t.add(column: "absWatchInstallID", .text)
      t.add(column: "absInventoryAccountHash", .text)
    }

    // Deleting an account deletes its rows by cascade. The inventory's account is cleared in the
    // same transaction, so a crash between the two cannot leave a re-signed-in account matching an
    // inventory whose phone-sent titles it no longer lists: its first offer would remove them all
    // by omission.
    try db.execute(
      sql: """
        CREATE TRIGGER absWatchCopySet_accountDeleted AFTER DELETE ON account
        BEGIN
          UPDATE rssWatchCopySet SET absInventoryAccountHash = NULL WHERE id = 1;
        END
        """)
  }
}
