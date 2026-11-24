import GRDB

extension SchemaV1 {
  /// Registers migrations `v81`–`v105`, called in order from `migrator()`.
  ///
  /// Migrations `v81`–`v102` are verbatim from the original `SchemaV1.swift`.
  /// New migrations append here, after `v105`: add a `v106` registration at the end of this
  /// function. Never renumber, reorder or edit an existing body.
  static func registerEra5(
    on migrator: inout DatabaseMigrator
  ) {
    // Persisted stage-1 plans.
    migrator.registerMigration("v81") { db in
      try AdSkipMigration.addStageOnePlans(db)
    }

    // Audio edges stored with each plan.
    migrator.registerMigration("v82") { db in
      try AdSkipMigration.addStageOnePlanAudioEdges(db)
    }

    // The episode index tokenised the stored HTML, so `href`, `div` and every link's URL were
    // searchable words. Index and match the description's plain text instead.
    migrator.registerMigration("v83") { db in
      try reindexEpisodeSearchAsPlainText(db)
    }

    // Cross-show alignments stored with each plan.
    migrator.registerMigration("v84") { db in
      try AdSkipMigration.addStageOnePlanCrossShowAlignments(db)
    }

    // Same-show alignments stored with each plan.
    migrator.registerMigration("v85") { db in
      try AdSkipMigration.addStageOnePlanSameShowEdges(db)
    }

    // Ranges the tail proposer made.
    migrator.registerMigration("v86") { db in
      try AdSkipMigration.addRangeFromTail(db)
    }

    migrator.registerMigration("v87") { db in
      try AudioBookmarkMigration.migrate(db)
    }
    // One cached stats snapshot per account.
    migrator.registerMigration("v88") { db in
      try ListeningStatsMigration.addSnapshot(db)
    }
    // Whether the account signs in through the server's OpenID flow. A token pair cannot tell an
    // OIDC login from a password one, and a migration cannot read the Keychain, so every existing
    // row is correctly false.
    migrator.registerMigration("v89") { db in
      try db.alter(table: "account") { t in
        t.add(column: "signsInWithOpenID", .boolean).notNull().defaults(to: false)
      }
    }
    // Collections and playlists as ordered ids.
    migrator.registerMigration("v90") { db in
      try LibraryCollectionMigration.addTables(db)
    }
    // Pinned lists, their claims and declines.
    migrator.registerMigration("v91") { db in
      try PinnedListMigration.addTables(db)
    }
    // Pause runs per downloaded file, and the per-show Trim Silences and Voice Boost overrides on
    // both show-settings tables.
    migrator.registerMigration("v92") { db in
      try PauseTrimMigration.migrate(db)
    }
    // A downloaded file's own measured length. Nullable and unbackfilled: it fills on the next
    // play of each download.
    migrator.registerMigration("v93") { db in
      try db.alter(table: "rssDownload") { t in
        t.add(column: "measuredDurationSeconds", .double)
      }
    }
    // Each cover's measured shape, so the detail cover can be requested at the width its shape
    // needs. Derived and disposable; its own table because every pull rebuilds the item row.
    migrator.registerMigration("v94") { db in
      try db.create(table: "coverShape") { t in
        t.primaryKey("itemId", .text)
        t.column("revision", .text).notNull()
        t.column("aspectRatio", .double).notNull()
        t.column("fitPixelWidth", .integer).notNull()
        t.column("measuredAt", .datetime).notNull()
      }
    }
    // Smart lists, their shows, run, hidden episodes and download claims.
    migrator.registerMigration("v95") { db in
      try SmartListMigration.migrate(db)
    }
    // The one chapter a queued audiobook row may carry. SQLite cannot add a table CHECK by
    // ALTER, so the store enforces "both bounds or neither" and `end > start`.
    migrator.registerMigration("v96") { db in
      try db.alter(table: "listeningQueueEntry") { t in
        t.add(column: "chapterStart", .double)
        t.add(column: "chapterEnd", .double)
        t.add(column: "chapterTitle", .text)
      }
    }
    // The listener's episode transcripts.
    migrator.registerMigration("v97") { db in
      try EpisodeTranscriptMigration.migrate(db)
    }
    // Ranges the host-read pass made.
    migrator.registerMigration("v98") { db in
      try AdSkipMigration.addRangeFromHostRead(db)
    }
    // The listener's own ad marks, and the flags they leave on ranges and creatives.
    migrator.registerMigration("v99") { db in
      try AdSkipMigration.addListenerMarks(db)
    }
    // Smart-list episodes the listener removed by hand, so auto-download leaves them alone.
    migrator.registerMigration("v100") { db in
      try SmartListDownloadDeclineMigration.migrate(db)
    }
    // Up Next entries whose download the listener removed by hand.
    migrator.registerMigration("v101") { db in
      try UpNextDownloadDeclineMigration.migrate(db)
    }
    // Which teaching rules each listener mark was taught under, and the confirmed creatives an
    // episode's Undo suppresses there.
    migrator.registerMigration("v102") { db in
      try AdSkipMigration.addConfirmedReach(db)
    }
    // An episode's own feed-declared artwork; clearing validators makes every followed feed's next
    // refresh a full fetch, so stored episodes backfill it.
    migrator.registerMigration("v103") { db in
      try RSSEpisodeArtworkMigration.migrate(db)
    }
    // The phone's desired set of native-RSS episodes sent to the active Watch, and its set state.
    migrator.registerMigration("v104") { db in
      try RSSWatchCopyMigration.migrate(db)
    }
    // The Watch downloads the offered enclosure itself, so rows a pre-ADR-0020 build left in the
    // phone-transfer states rejoin the offer.
    migrator.registerMigration("v105") { db in
      try RSSWatchCopyLegacyStateMigration.migrate(db)
    }
    // The phone's desired set of Audiobookshelf books and episodes sent to the active Watch, and the
    // Audiobookshelf half of the shared set row (ADR 0021).
    migrator.registerMigration("v106") { db in
      try ABSWatchCopyMigration.migrate(db)
    }
    // Several chapter rows of one audiobook in Up Next, or its one whole-book row.
    migrator.registerMigration("v107") { db in
      try MultiChapterQueueMigration.migrate(db)
    }
  }
}
