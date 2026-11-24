import GRDB

/// v73: the ad-skip tables.
///
/// Device-owned and never synced. None has a foreign key to `account`, so `AccountRemover`'s
/// discovery skips them (ABS and RSS episodes live in different tables, and the signature store
/// outlives accounts). The coordinator deletes an episode once it leaves the local-episode set
/// (derived from the download tables), which is how account removal reaches these rows. Foreign
/// keys exist only inside the set: an episode owns its ranges, a creative its teachers and
/// shingles.
///
/// Transcripts are files (`transcriptFileName`), so the backed-up database never holds their text.
enum AdSkipMigration {
  static func migrate(_ db: Database) throws {
    try db.create(table: "adSkipEpisode") { t in
      t.autoIncrementedPrimaryKey("id")
      t.column("source", .text).notNull().check { ["abs", "rss"].contains($0) }
      // The ABS account row id keeps two accounts' identical server ids apart. Not a foreign key:
      // see the type comment.
      t.column("accountId", .integer)
      t.column("itemID", .text).notNull()
      t.column("episodeID", .text).notNull()
      t.column("fileByteSize", .integer).notNull()
      // Seconds since 1970 as a REAL, so the fingerprint compares exactly; GRDB's date text keeps
      // only milliseconds.
      t.column("fileModificationTime", .double).notNull()
      t.column("transcriberRevision", .text).notNull()
      t.column("rulesRevision", .integer).notNull()
      // No CHECK: SQLite cannot relax one, and the analysis states may grow.
      t.column("state", .text).notNull()
      t.column("transcriptFileName", .text).unique()
      t.column("analysedAt", .datetime).notNull()
      t.check(sql: "(source = 'abs') = (accountId IS NOT NULL)")
    }
    // SQLite treats NULLs as distinct in a UNIQUE constraint, so RSS rows (no account) need the
    // expression to collide.
    try db.execute(
      sql: """
        CREATE UNIQUE INDEX adSkipEpisode_identity
        ON adSkipEpisode(source, IFNULL(accountId, 0), itemID, episodeID)
        """)

    try db.create(table: "adSignatureCreative") { t in
      t.autoIncrementedPrimaryKey("id")
      t.column("kind", .text).notNull().check { ["learned", "tombstone"].contains($0) }
      t.column("lastSeen", .datetime).notNull()
      // The range in the teaching episode, so a re-analysis can replace what it taught.
      t.column("startTime", .double).notNull()
      t.column("endTime", .double).notNull()
    }

    try db.create(table: "adSkipRange") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("episode", inTable: "adSkipEpisode", onDelete: .cascade).notNull()
      t.column("startTime", .double).notNull()
      t.column("endTime", .double).notNull()
      t.column("meanAdProbability", .double).notNull()
      t.column("rulesRevision", .integer).notNull()
      t.column("fromStore", .boolean).notNull()
      t.column("endsItem", .boolean).notNull()
      // The learned creative a store range matched, so Undo can forget exactly that one.
      t.belongsTo("creative", inTable: "adSignatureCreative", onDelete: .setNull)
    }

    try db.create(table: "adSignatureTeacher", options: .withoutRowID) { t in
      t.belongsTo("creative", inTable: "adSignatureCreative", onDelete: .cascade).notNull()
      // The coordinator's opaque episode key. Text, not a reference: a teacher outlives its
      // episode's row.
      t.column("episodeKey", .text).notNull()
      t.primaryKey(["creativeId", "episodeKey"])
    }

    try db.create(table: "adSignatureShingle", options: .withoutRowID) { t in
      t.belongsTo("creative", inTable: "adSignatureCreative", onDelete: .cascade).notNull()
      // The 64-bit FNV-1a hash's bit pattern as a signed INTEGER.
      t.column("hash", .integer).notNull()
      t.primaryKey(["creativeId", "hash"])
    }
  }

  /// The audio-gated columns: each episode's audio print file, beside its transcript and swept with
  /// it, and a learned creative's audio print. The creative's print is in the database, so it is
  /// backed up with it: 32-bit words that identify a recording but cannot be turned back into audio
  /// or words (SECURITY rule 20).
  static func addAudioPrints(_ db: Database) throws {
    try db.alter(table: "adSkipEpisode") { t in t.add(column: "audioPrintFileName", .text) }
    // SQLite cannot add a UNIQUE column; the index is the constraint.
    try db.execute(
      sql: "CREATE UNIQUE INDEX adSkipEpisode_audioPrintFileName ON adSkipEpisode(audioPrintFileName)")
    try db.alter(table: "adSignatureCreative") { t in t.add(column: "audioPrint", .blob) }
  }

  /// Each episode's last stage-1 plan, so a relaunch with an unchanged library does not match every
  /// print again. A cache only: `libraryKey` names the library the plan was made against, a row for
  /// another library is ignored, and any row may be deleted. A table rather than a file, because
  /// the transcript store's sweep removes every file in its root that no row names. Times only,
  /// never words or audio.
  static func addStageOnePlans(_ db: Database) throws {
    try db.create(table: "adSkipStageOnePlan") { t in
      t.belongsTo("episode", inTable: "adSkipEpisode", onDelete: .cascade).notNull().unique()
      t.column("libraryKey", .text).notNull()
      // Start and end of each window as little-endian Float64 pairs.
      t.column("windows", .blob).notNull()
    }
  }

  /// Where each episode's audio aligns with another show's, found by the query that made its
  /// stage-1 plan and kept with it, so a recompute moves range edges without matching audio. Times
  /// only, as the windows are. A plan stored before this column has none until it is planned
  /// again.
  static func addStageOnePlanAudioEdges(_ db: Database) throws {
    try db.alter(table: "adSkipStageOnePlan") { t in
      // Start and end of each alignment as little-endian Float64 pairs.
      t.add(column: "audioEdges", .blob).notNull().defaults(sql: "X''")
    }
  }

  /// The plan's alignments with episodes of another show, each with the episode it aligns with, so
  /// the recompute can tell another show's audio from a rerun's. Times and the coordinator's
  /// episode keys only, as a teacher row holds. A plan stored before this column has none until it
  /// is planned again.
  static func addStageOnePlanCrossShowAlignments(_ db: Database) throws {
    try db.alter(table: "adSkipStageOnePlan") { t in
      t.add(column: "crossShowAlignments", .blob).notNull().defaults(sql: "X''")
    }
  }

  /// Where each episode's audio aligns with other episodes of its own show, found by the same
  /// query, so the tail trigger tells the show's outro from an inserted post-roll without matching
  /// audio. Times only, as the windows are. A plan stored before this column has none until it is
  /// planned again.
  static func addStageOnePlanSameShowEdges(_ db: Database) throws {
    try db.alter(table: "adSkipStageOnePlan") { t in
      // Start and end of each alignment as little-endian Float64 pairs.
      t.add(column: "sameShowEdges", .blob).notNull().defaults(sql: "X''")
    }
  }

  /// Marks a range the tail proposer made, so Undo and diagnostics can tell it from a repetition
  /// range. Ranges stored without it were made by repetition.
  static func addRangeFromTail(_ db: Database) throws {
    try db.alter(table: "adSkipRange") { t in
      t.add(column: "fromTail", .boolean).notNull().defaults(to: false)
    }
  }

  /// Marks a range the host-read pass made from the listener's own transcript, so it can be
  /// replaced or removed on its own when that transcript changes, and so Undo and diagnostics can
  /// tell it apart. Ranges stored without it were not.
  static func addRangeFromHostRead(_ db: Database) throws {
    try db.alter(table: "adSkipRange") { t in
      t.add(column: "fromHostRead", .boolean).notNull().defaults(to: false)
    }
  }

  /// The listener's own marks: a stretch they said is an ad, kept apart from the ranges because
  /// every recompute replaces those. A mark is cut from nothing and served whole, so it is laid
  /// over what the recompute finds. The row goes with its episode, so a changed file drops it. The
  /// creative is what the mark taught the signature store, which keeps it only while it exists.
  /// `fromListener` marks the range a mark is served as, and `confirmed` a creative that a mark
  /// taught: the store never expires, merges or replaces it. Times, hashes and a print only
  /// (SECURITY rule 20).
  static func addListenerMarks(_ db: Database) throws {
    try db.create(table: "adSkipListenerMark") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("episode", inTable: "adSkipEpisode", onDelete: .cascade).notNull()
      t.column("startTime", .double).notNull()
      t.column("endTime", .double).notNull()
      t.belongsTo("creative", inTable: "adSignatureCreative", onDelete: .setNull)
      t.column("createdAt", .datetime).notNull()
    }
    try db.alter(table: "adSkipRange") { t in
      t.add(column: "fromListener", .boolean).notNull().defaults(to: false)
    }
    try db.alter(table: "adSignatureCreative") { t in
      t.add(column: "confirmed", .boolean).notNull().defaults(to: false)
    }
  }

  /// v102: confirmed reach. Each mark records the teaching rules it was last taught
  /// under, so a mark that taught nothing under the 15 s floor is taught once more under the
  /// 4 s one; and an episode records the confirmed creatives the listener undid there, which are
  /// not matched there again. A suppression goes with its episode row or its creative.
  static func addConfirmedReach(_ db: Database) throws {
    try db.alter(table: "adSkipListenerMark") { t in
      t.add(column: "teachingRevision", .integer).notNull().defaults(to: 1)
    }
    try db.execute(sql: "UPDATE adSkipListenerMark SET teachingRevision = 2 WHERE creativeId IS NOT NULL")
    try db.create(table: "adSkipConfirmedSuppression") { t in
      t.belongsTo("episode", inTable: "adSkipEpisode", onDelete: .cascade).notNull()
      t.belongsTo("creative", inTable: "adSignatureCreative", onDelete: .cascade).notNull()
      t.column("createdAt", .datetime).notNull()
      t.primaryKey(["episodeId", "creativeId"])
    }
  }
}
