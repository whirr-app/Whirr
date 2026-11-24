import GRDB

/// v100: episodes the listener removed by hand while an auto-downloading smart list wanted them.
/// One row per episode, not per list, so a list delete does not cascade it. Keyed
/// as claims are: a server item and episode id, or `rss:<feedId>` and the native `identityKey`.
/// Native rows carry no account and survive account removal; server rows cascade with theirs.
enum SmartListDownloadDeclineMigration {
  static func migrate(_ db: Database) throws {
    try db.create(table: "smartListDownloadDecline") { t in
      t.column("itemID", .text).notNull()
      t.column("episodeID", .text).notNull()
      t.belongsTo("account", onDelete: .cascade)
      t.column("declinedAt", .datetime).notNull()
      t.primaryKey(["itemID", "episodeID"])
    }
  }
}
