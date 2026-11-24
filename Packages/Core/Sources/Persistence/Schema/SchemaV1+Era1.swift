import GRDB

extension SchemaV1 {
  /// Registers migrations `v1`–`v20`, called in order from `migrator()`.
  ///
  /// Migrations `v1`–`v20`. `v1`–`v4` are the released schema and are frozen. Every body is
  /// verbatim from the original `SchemaV1.swift`; see `SchemaV1.migrator()` for the order.
  static func registerEra1(
    on migrator: inout DatabaseMigrator,
    listeningQueueMigrationCheckpoint:
      @escaping @Sendable (ListeningQueueMigrationCheckpoint) throws -> Void
  ) {
    migrator.registerMigration("v1") { db in
      try createAccount(db)
      try createLibrary(db)
      try createItem(db)
      try createPodcastEpisode(db)
      try createMediaProgress(db)
      try createProgressConflict(db)
      // `outboxOperation` has an FK to `playbackSession`, so that table must exist first.
      try createPlaybackSession(db)
      try createOutboxOperation(db)
      try createDownload(db)
      try createSyncRun(db)
      try createSyncPage(db)
      try createDiagnosticsEvent(db)
      try createObservedServerTime(db)
      try createAccountRemovalJournal(db)
      // Cached per-item listening-session history (`GET /api/me/listening-sessions`).
      try createListeningHistoryEntry(db)
      // "What was last played"; needs `item`/`podcastEpisode` to exist first.
      try createPlaybackBookmark(db)
    }

    migrator.registerMigration("v2") { db in
      try healItemHomeColumns(db)
    }

    // The in-place `v1` amendment above reaches only stores that do not exist yet, so the same
    // guarded creation runs again here for stores already in the field.
    // `createPlaybackBookmark` is idempotent, so this is a no-op on a fresh install.
    migrator.registerMigration("v3") { db in
      try createPlaybackBookmark(db)
    }

    // General heal for every other in-place `v1` amendment. Hand-healing one `ALTER` at a time
    // cannot reach all of them: three tables need rebuilding, because a column inserted mid-list,
    // a tightened nullability and a retired column are all things `ALTER TABLE` cannot express.
    migrator.registerMigration("v4") { db in
      try healSchemaDrift(db)
    }

    // Podcast presentation metadata, show diagnostics, and episode-aware progress identity.
    // Additive: the released v1-v4 migrations stay frozen.
    migrator.registerMigration("v5") { db in
      try addPodcastPersistence(db)
    }

    // Durable, account-scoped local Up Next ordering.
    migrator.registerMigration("v6") { db in
      try createPodcastQueueEntry(db)
    }

    migrator.registerMigration("v7") { db in
      try db.alter(table: "item") { t in
        t.add(column: "serverUpdatedAt", .datetime)
        t.add(column: "podcastServerEpisodeCount", .integer)
      }
    }

    migrator.registerMigration("v8") { db in
      try db.create(table: "podcastRefreshState") { t in
        t.column("itemId", .integer).primaryKey().references("item", onDelete: .cascade)
        t.column("lastAttemptAt", .datetime)
        t.column("lastSuccessfulRefreshAt", .datetime)
        t.column("consecutiveFailures", .integer).notNull().defaults(to: 0)
        t.column("nextEligibleAttemptAt", .datetime)
      }
    }

    migrator.registerMigration("v9") { db in
      try db.alter(table: "item") { t in
        t.add(column: "seriesName", .text)
        t.add(column: "narratorName", .text)
        t.add(column: "expandedMetadataFetchedAt", .datetime)
      }
    }

    // The FTS5 search index, maintained by triggers rather than any launch-time sweep
    // (API-CONVENTIONS rule 16).
    migrator.registerMigration("v10") { db in
      try createSearchIndex(db)
    }

    // Per-account recent searches. Stored in the database, not defaults, so they cascade away with
    // the account like every other account-owned table.
    migrator.registerMigration("v11") { db in
      try createRecentSearch(db)
    }

    // The show's own synopsis, for the podcast header. Named `itemDescription` rather than
    // `description` to match `podcastEpisode.episodeDescription` and to keep `ItemRecord`'s Swift
    // property clear of `CustomStringConvertible`.
    migrator.registerMigration("v12") { db in
      try db.alter(table: "item") { t in
        t.add(column: "itemDescription", .text)
      }
    }

    // Device-side auto-download settings tables and the two provenance/decision columns the
    // selection and retention queries need. Additive. An absent
    // `podcastSettings`/`podcastShowSettings` row means "defaults"/"inherit", so there is no
    // backfill or guarded heal: every existing install is correct the moment it migrates.
    migrator.registerMigration("v13") { db in
      try addPodcastDeviceDownloadSettings(db)
    }

    // Durable, account-scoped custom Your-Shows order. Additive. An absent `podcastShowOrder` row
    // means alphabetical.
    migrator.registerMigration("v14") { db in
      try createPodcastShowOrder(db)
    }

    // The universal, media-neutral listening queue that replaces v6's podcast-only
    // `podcastQueueEntry`.
    migrator.registerMigration("v15") { db in
      try createListeningQueueEntry(db, checkpoint: listeningQueueMigrationCheckpoint)
    }

    // Durable per-account revision counter `ListeningQueueStore` bumps on every committed queue
    // mutation, including `clear()` and `restore(token:)` themselves. A restore token records the
    // revision as of its clear, and `restore` compares it against the live value to detect that no
    // queue mutation happened since. The restore's own commit bumps it again, so replaying an
    // already-consumed token fails the same check.
    migrator.registerMigration("v16") { db in
      try createListeningQueueRevision(db)
    }

    // Small chapter snapshot from the expanded item-detail response, kept beside the item so local
    // playback of downloaded audiobooks can rebuild PlayerCore's chapter map without the network.
    migrator.registerMigration("v17") { db in
      try createItemChapter(db)
    }

    // Disjoint ebook position state and the expanded detail's file identity. Nullable so every
    // audio-only row migrates without inventing a reading position or an ebook file.
    migrator.registerMigration("v18") { db in
      try addEbookPersistence(db)
    }

    // An item's downloads may carry one primary EPUB beside its audio files. Existing rows are
    // audio downloads, so the default is explicit rather than an ambiguous NULL medium.
    migrator.registerMigration("v19") { db in
      try db.alter(table: "download") { t in
        t.add(column: "mediaKind", .text).notNull().defaults(to: DownloadMediaKind.audio.rawValue)
      }
    }

    // One opaque, account-scoped reader-preferences payload. ReaderCore owns the Codable value and
    // its defaults; Persistence stores only bounded JSON text so the target graph stays
    // downward-only.
    migrator.registerMigration("v20") { db in
      try createReaderPreferences(db)
    }
  }
}
