import GRDB

/// v97: the listener's episode transcripts.
///
/// `episodeTranscript` holds one downloaded file's transcript state; the words live in a `.words`
/// file on the transcript root, which is separate from ad skip's so neither sweep deletes the
/// other's files. Like `pauseTrimEpisode` it is device-owned, never synced and has no foreign key
/// to `account`, so `AccountRemover`'s discovery skips it; the coordinator deletes a row once its
/// episode leaves the local-episode set.
enum EpisodeTranscriptMigration {
  static func migrate(_ db: Database) throws {
    try db.create(table: "episodeTranscript") { t in
      t.autoIncrementedPrimaryKey("id")
      t.column("source", .text).notNull().check { ["abs", "rss"].contains($0) }
      // Not a foreign key: see the type comment.
      t.column("accountId", .integer)
      t.column("itemID", .text).notNull()
      t.column("episodeID", .text).notNull()
      t.column("fileByteSize", .integer).notNull()
      // Seconds since 1970 as a REAL, so the fingerprint compares exactly.
      t.column("fileModificationTime", .double).notNull()
      t.column("transcriberRevision", .text).notNull()
      // No CHECK: SQLite cannot relax one, and the states may grow.
      t.column("state", .text).notNull()
      // Nil for a failed row. NULLs are distinct, so many failed rows can coexist.
      t.column("transcriptFileName", .text).unique()
      t.column("updatedAt", .datetime).notNull()
      t.check(sql: "(source = 'abs') = (accountId IS NOT NULL)")
    }
    // SQLite treats NULLs as distinct in a UNIQUE constraint, so RSS rows (no account) need the
    // expression to collide.
    try db.execute(
      sql: """
        CREATE UNIQUE INDEX episodeTranscript_identity
        ON episodeTranscript(source, IFNULL(accountId, 0), itemID, episodeID)
        """)
  }
}
