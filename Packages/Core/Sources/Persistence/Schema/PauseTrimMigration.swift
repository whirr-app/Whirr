import GRDB

/// v92: Trim Silences.
///
/// `pauseTrimEpisode` holds one downloaded file's pause runs. Like `adSkipEpisode` it is
/// device-owned, never synced and has no foreign key to `account`, so `AccountRemover`'s
/// discovery skips it. The coordinator deletes a row once its episode leaves the local-episode
/// set (derived from the download tables), which is how account removal reaches it.
///
/// The two per-show overrides sit on both show-settings tables. Existing rows inherit.
enum PauseTrimMigration {
  static func migrate(_ db: Database) throws {
    try db.create(table: "pauseTrimEpisode") { t in
      t.autoIncrementedPrimaryKey("id")
      t.column("source", .text).notNull().check { ["abs", "rss"].contains($0) }
      // The ABS account row id keeps two accounts' identical server ids apart. Not a foreign key:
      // see the type comment.
      t.column("accountId", .integer)
      t.column("itemID", .text).notNull()
      t.column("episodeID", .text).notNull()
      t.column("fileByteSize", .integer).notNull()
      // Seconds since 1970 as a REAL, so the fingerprint compares exactly.
      t.column("fileModificationTime", .double).notNull()
      t.column("detectorRevision", .integer).notNull()
      // No CHECK: SQLite cannot relax one, and the analysis states may grow.
      t.column("state", .text).notNull()
      // `PauseRuns`' own encoding; nil unless the file was analysed.
      t.column("runs", .blob)
      t.column("analysedAt", .datetime).notNull()
      t.check(sql: "(source = 'abs') = (accountId IS NOT NULL)")
    }
    // SQLite treats NULLs as distinct in a UNIQUE constraint, so RSS rows (no account) need the
    // expression to collide.
    try db.execute(
      sql: """
        CREATE UNIQUE INDEX pauseTrimEpisode_identity
        ON pauseTrimEpisode(source, IFNULL(accountId, 0), itemID, episodeID)
        """)

    for table in ["rssFeedSettings", "podcastShowSettings"] {
      try db.execute(
        sql: """
          ALTER TABLE \(table)
          ADD COLUMN trimSilencesOverride TEXT NOT NULL DEFAULT 'inherit'
          CHECK (trimSilencesOverride IN ('inherit', 'off', 'moderate', 'maximum'))
          """)
      try db.execute(
        sql: """
          ALTER TABLE \(table)
          ADD COLUMN voiceBoostOverride TEXT NOT NULL DEFAULT 'inherit'
          CHECK (voiceBoostOverride IN ('inherit', 'on', 'off'))
          """)
    }
  }
}
