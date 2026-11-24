import GRDB

/// The device-owned RSS tables and the identities built across the two podcast sources: RSS
/// subscriptions, episodes, settings and downloads (`v42`), the durable native episode server-save
/// attempt (`v51`), and the feed-fingerprint backfill that matches a native show to its server twin
/// (`v57`).
///
/// Registered by `SchemaV1.registerEra3`; `SchemaV1.migrator()` holds the order. The bodies are
/// frozen: an applied migration is never edited in place.
extension SchemaV1 {

  // MARK: - v42: device-owned RSS subscriptions, episodes and downloads

  /// RSS subscriptions, episode state, settings, and downloads are device-owned and
  /// carry no `account` foreign key. Like `accountRemovalJournal`, they must survive account
  /// removal, so `AccountRemover`'s schema-driven sweep must not discover these tables.
  static func addRSSPodcastPersistence(_ db: Database) throws {
    try db.create(table: "rssFeed") { t in
      t.autoIncrementedPrimaryKey("id")
      t.column("feedURL", .text).notNull().unique()
      t.column("title", .text)
      t.column("author", .text)
      t.column("synopsis", .text)
      t.column("artworkURL", .text)
      t.column("etag", .text)
      t.column("lastModified", .text)
      t.column("subscribedAt", .datetime).notNull()
      t.column("lastRefreshedAt", .datetime)
      t.column("refreshGeneration", .integer).notNull().defaults(to: 0)
      t.column("customSortIndex", .integer)
    }

    try db.create(table: "rssEpisode") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("feed", inTable: "rssFeed", onDelete: .cascade).notNull()
      t.column("identityKey", .text).notNull()
      t.column("alternateIdentityKey", .text)
      t.column("guid", .text)
      t.column("title", .text)
      t.column("synopsis", .text)
      t.column("enclosureURL", .text).notNull()
      t.column("enclosureType", .text)
      t.column("declaredBytes", .integer)
      t.column("publishedAt", .datetime)
      t.column("durationSeconds", .double)
      t.column("seasonNumber", .integer)
      t.column("episodeNumber", .integer)
      t.column("lastSeenGeneration", .integer).notNull()
      t.column("retained", .boolean).notNull().defaults(to: false)
    }
    try db.create(
      index: "index_rssEpisode_on_feed_identity", on: "rssEpisode",
      columns: ["feedId", "identityKey"], options: .unique)
    try db.create(
      index: "index_rssEpisode_on_feed_alternateIdentity", on: "rssEpisode",
      columns: ["feedId", "alternateIdentityKey"],
      condition: Column("alternateIdentityKey") != nil)
    try db.create(
      index: "index_rssEpisode_on_feed_publishedAt", on: "rssEpisode",
      columns: ["feedId", "publishedAt"])

    try db.create(table: "rssEpisodeState") { t in
      t.column("episodeId", .integer).primaryKey().references("rssEpisode", onDelete: .cascade)
      t.column("position", .double).notNull()
      t.column("finished", .boolean).notNull().defaults(to: false)
      t.column("localSequence", .integer).notNull()
      t.column("updatedAt", .datetime).notNull()
    }

    try db.create(table: "rssFeedSettings") { t in
      t.column("feedId", .integer).primaryKey().references("rssFeed", onDelete: .cascade)
      t.column("autoDownload", .text).notNull().defaults(to: "inherit")
      t.check(sql: "autoDownload IN ('inherit', 'enabled', 'disabled')")
      t.column("keepLatest", .integer)
      t.column("deleteAfterPlayed", .boolean)
      t.column("rateStep", .integer)
      t.column("includeInLatest", .boolean).notNull().defaults(to: true)
    }

    try db.create(table: "rssDownload") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("episode", inTable: "rssEpisode", onDelete: .cascade).notNull().unique()
      t.column("state", .text).notNull()
      t.check(
        sql:
          "state IN ('pending', 'downloading', 'paused', 'pausedAuth', 'interrupted', 'deleting', 'completed', 'failed')"
      )
      t.column("relativePath", .text).notNull()
      t.column("expectedBytes", .integer)
      t.column("actualBytes", .integer).notNull().defaults(to: 0)
      t.column("origin", .text).notNull()
      t.check(sql: "origin IN ('manual', 'automatic')")
      t.column("decidedStamp", .datetime).notNull()
      t.column("holdReason", .text)
      t.column("errorCode", .text)
      t.column("createdAt", .datetime).notNull()
      t.column("updatedAt", .datetime).notNull()
    }
  }

  // MARK: - v51: native RSS episode server-save attempts

  static func createNativeEpisodeServerSaveAttempt(_ db: Database) throws {
    try db.create(table: "nativeEpisodeServerSaveAttempt") { t in
      t.autoIncrementedPrimaryKey("id")
      // The direct FK is the ownership boundary AccountRemover discovers. No FKs to
      // rssFeed/rssEpisode: those tables are device-owned and may be refreshed or pruned without
      // deleting account history for a server operation.
      t.belongsTo("account", onDelete: .cascade).notNull()
      // A raw row id is reusable. These captured values fence every continuation against the
      // account identity that began the operation, while same-account reauthentication preserves
      // them. Server URL and user id are stored only as one fingerprint so the attempt copies
      // neither raw value.
      t.column("accountClientUUID", .text).notNull()
      t.column("accountServerIdentityFingerprint", .text).notNull()
      t.column("feedId", .integer).notNull()
      t.column("episodeId", .integer).notNull()
      t.column("episodeIdentityKey", .text).notNull()
      t.column("serverItemId", .text)
      t.column("serverEpisodeId", .text)
      t.column("preflightPresence", .text)
      t.column("state", .text).notNull()
      t.column("errorCategory", .text)
      t.column("createdAt", .datetime).notNull()
      t.column("updatedAt", .datetime).notNull()

      t.check(sql: "feedId > 0 AND episodeId > 0")
      t.check(sql: "length(CAST(accountClientUUID AS BLOB)) BETWEEN 1 AND 512")
      t.check(
        sql:
          "length(accountServerIdentityFingerprint) = 64 AND accountServerIdentityFingerprint NOT GLOB '*[^0-9a-f]*'"
      )
      t.check(sql: "length(CAST(episodeIdentityKey AS BLOB)) BETWEEN 1 AND 512")
      t.check(
        sql: "serverItemId IS NULL OR length(CAST(serverItemId AS BLOB)) BETWEEN 1 AND 512")
      t.check(
        sql: "serverEpisodeId IS NULL OR length(CAST(serverEpisodeId AS BLOB)) BETWEEN 1 AND 512")
      t.check(
        sql: "preflightPresence IS NULL OR preflightPresence IN ('preExisting', 'absentBeforeRequest')")
      t.check(
        sql: """
          state IN (
            'preparing', 'creatingShow', 'createUncertain', 'requestingDownload', 'accepted', 'confirmed',
            'deleting', 'removed', 'deleteUncertain', 'deleteFailed', 'uncertain', 'failed'
          )
          """)
      t.check(
        sql: """
          errorCategory IS NULL OR errorCategory IN (
            'invalidDestination', 'permissionChanged', 'staleIdentity', 'transport',
            'serverFailure', 'malformedResponse', 'cancelled', 'credentialedFeed',
            'unsubscribed', 'missingEpisode', 'incompleteEpisodeList', 'localPersistence',
            'accountReplaced', 'unknown'
          )
          """)
    }

    try db.create(
      index: "index_nativeEpisodeServerSaveAttempt_on_account_feed_episode",
      on: "nativeEpisodeServerSaveAttempt",
      columns: ["accountId", "feedId", "episodeId"])
    try db.create(
      index: "index_nativeEpisodeServerSaveAttempt_on_account_state_updated",
      on: "nativeEpisodeServerSaveAttempt",
      columns: ["accountId", "state", "updatedAt"])
    try db.create(
      index: "index_nativeEpisodeServerSaveAttempt_on_account_server_identity",
      on: "nativeEpisodeServerSaveAttempt",
      columns: ["accountId", "serverItemId", "serverEpisodeId"])
  }

  // MARK: - v57: podcast feed fingerprints

  /// Backfills only the device-owned RSS source rows. The pre-v57 item schema kept no raw server
  /// feed URL, so inferring server identities here would associate unrelated shows. Invalid or
  /// credentialed URLs stay nil and are not diagnostic failures.
  static func backfillPodcastFeedFingerprints(_ db: Database) throws {
    let rows = try Row.fetchAll(db, sql: "SELECT id, feedURL FROM rssFeed")
    for row in rows {
      let feedID: Int64 = row["id"]
      let feedURL: String = row["feedURL"]
      let fingerprint = PodcastFeedIdentity.fingerprint(feedURL)
      try db.execute(
        sql: "UPDATE rssFeed SET podcastFeedFingerprint = ? WHERE id = ?",
        arguments: [fingerprint, feedID])
    }
  }
}
