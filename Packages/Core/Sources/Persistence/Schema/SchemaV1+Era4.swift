import GRDB

extension SchemaV1 {
  /// Registers migrations `v61`–`v80`, called in order from `migrator()`.
  ///
  /// Migrations `v61`–`v80`. Every body is verbatim from the original `SchemaV1.swift`.
  static func registerEra4(
    on migrator: inout DatabaseMigrator
  ) {
    migrator.registerMigration("v61") { db in
      try PodcastCloudTransportMigration.migrate(db)
    }

    // An RSS auto-download decision belongs to the episode, not its replaceable download row, so
    // it survives the user deleting the file.
    migrator.registerMigration("v62") { db in
      try db.alter(table: "rssEpisode") { t in
        t.add(column: "autoDownloadDecidedAt", .datetime)
      }
      try db.execute(
        sql: """
          UPDATE rssEpisode
          SET autoDownloadDecidedAt = (
            SELECT rssDownload.decidedStamp
            FROM rssDownload
            WHERE rssDownload.episodeId = rssEpisode.id
              AND rssDownload.origin = ?
          )
          WHERE EXISTS (
            SELECT 1 FROM rssDownload
            WHERE rssDownload.episodeId = rssEpisode.id
              AND rssDownload.origin = ?
          )
          """,
        arguments: [DownloadOrigin.automatic.rawValue, DownloadOrigin.automatic.rawValue])
    }

    // An account may have several addresses. `account.serverBaseURL` stays the active endpoint;
    // the endpoint table is the complete ordered address set.
    migrator.registerMigration("v63") { db in
      try db.create(table: "accountEndpoint") { t in
        t.autoIncrementedPrimaryKey("id")
        t.belongsTo("account", onDelete: .cascade).notNull()
        t.column("normalizedURL", .text).notNull()
        t.column("isPreferred", .boolean).notNull().defaults(to: false)
        t.column("sortOrder", .integer).notNull()
        t.column("addedAt", .datetime).notNull()
        t.column("lastReachedAt", .datetime)
        t.column("lastFailedAt", .datetime)
      }
      try db.create(
        index: "index_accountEndpoint_on_account_normalizedURL", on: "accountEndpoint",
        columns: ["accountId", "normalizedURL"], options: .unique)
      try db.create(
        index: "index_accountEndpoint_on_account_sortOrder", on: "accountEndpoint",
        columns: ["accountId", "sortOrder"])

      // `serverBaseURL` is the active endpoint; row 0 is the migrated preferred address for each
      // existing account.
      try db.execute(
        sql: """
          INSERT INTO accountEndpoint
            (accountId, normalizedURL, isPreferred, sortOrder, addedAt)
          SELECT id, serverBaseURL, 1, 0, CURRENT_TIMESTAMP
          FROM account
          """)

      try db.alter(table: "account") { t in
        t.add(column: "credentialNamespace", .text).notNull().defaults(to: "")
      }
      try db.execute(
        sql: "UPDATE account SET credentialNamespace = 'account:' || clientUUID")
      try db.drop(index: "index_account_on_serverBaseURL_serverUserId")
      try db.create(
        index: "index_account_on_serverUserId", on: "account", columns: ["serverUserId"],
        options: .unique)

      try db.alter(table: "accountRemovalJournal") { t in
        t.add(column: "credentialNamespace", .text)
        t.add(column: "endpointURLs", .text)
      }
    }

    // Re-creates `itemSearch_au` with a `WHEN` guard. The unguarded trigger re-indexed every row a
    // traversal touched, and a traversal touches every item it sees whether or not it changed.
    // Existing databases carry the unguarded version, so it is dropped rather than assumed absent.
    migrator.registerMigration("v64") { db in
      try db.execute(sql: "DROP TRIGGER IF EXISTS itemSearch_au")
      try db.execute(sql: itemSearchUpdateTriggerSQL)
    }

    // Moves the traversal seen-set off `item` into its own table. On a steady-state catalogue the
    // per-traversal generation stamp was the only change, so every `item` write and observation
    // invalidation only recorded "still there". `itemSeen` keeps that outside the tracked region.
    //
    // The backfill must preserve existing generations: the next traversal's deletion inference
    // compares against them, and an invented value would resurrect deleted rows or delete live
    // ones on the first run after upgrade.
    migrator.registerMigration("v65") { db in
      try db.create(table: "itemSeen") { t in
        t.column("itemId", .integer).primaryKey().references("item", onDelete: .cascade)
        t.column("generation", .integer).notNull()
      }
      try db.execute(
        sql: "INSERT INTO itemSeen (itemId, generation) SELECT id, lastSeenGeneration FROM item")
      try db.alter(table: "item") { t in t.drop(column: "lastSeenGeneration") }
    }

    // The identity, clock and unresolved-state substrate CloudKit podcast sync needs. Outside
    // every existing cascade; see `PodcastCloudRegistryMigration`.
    // `podcastCloudInstallation` is left row-less: an absent row is how a first run is told apart
    // from a database restored from another device's backup, which the Keychain anchor in
    // `PodcastCloudInstallationStore` exists to detect.
    migrator.registerMigration("v66") { db in
      try PodcastCloudRegistryMigration.migrate(db)
    }

    // Retires the device-owned Saved-shelf resolution triggers in favour of
    // `NativeSavedIntentResolving`, called inside the writing transaction by
    // `RSSEpisodeStateStore`.
    //
    // The removal a trigger performs is a user mutation, and once podcast state syncs it must reach
    // the outbox with the causing mutation's stamp. A trigger cannot reach the logical clock or the
    // saved register, and keeping the pair beside the resolver would delete the shelf row twice
    // and record only one as a mutation.
    //
    // The account-owned pair (`savedShelfProgress_ai`/`_au`) stays: ABS progress is server-owned
    // and its shelf resolution stays in SQL.
    migrator.registerMigration("v67") { db in
      for trigger in ["savedShelfRSSProgress_ai", "savedShelfRSSProgress_au"] {
        try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
      }
    }

    // Zone establishment, durable sync status, held records and the quarantined-clock republish
    // debt. See `PodcastCloudSyncStateMigration`.
    migrator.registerMigration("v68") { db in
      try PodcastCloudSyncStateMigration.migrate(db)
    }

    // The last accepted record's encoded fields, so admission can merge against a value rather
    // than compare one stamp. See `PodcastCloudRegistryMigration`.
    migrator.registerMigration("v69") { db in
      try PodcastCloudRegistryMigration.addAcceptedPayload(db)
    }

    // Trigger-fed dirty log that captures every local edit to a synced podcast entity. See
    // `PodcastCloudDirtyLogMigration`.
    migrator.registerMigration("v70") { db in
      try PodcastCloudDirtyLogMigration.migrate(db)
    }

    // Cross-device reset sync: server progress row identity, the ebook conflict slot, and the
    // phased reset operation. See `ProgressResetMigration`.
    migrator.registerMigration("v71") { db in
      try ProgressResetMigration.migrate(db)
    }

    // The show's declared language, as the source states it, which decides whether its episodes
    // are eligible for ad analysis. Nullable on both sources: an untagged show is a real state,
    // not a missing backfill.
    migrator.registerMigration("v72") { db in
      try db.alter(table: "rssFeed") { t in t.add(column: "language", .text) }
      try db.alter(table: "item") { t in t.add(column: "podcastLanguage", .text) }
    }

    // Ad-skip episode, range and signature-store tables. See `AdSkipMigration`.
    migrator.registerMigration("v73") { db in
      try AdSkipMigration.migrate(db)
    }

    // Chapters for downloaded podcast episodes, as a streamed one gets. Kept apart from
    // `itemChapter`, whose replace-all-for-item semantics belong to books. Episode-scoped, so a
    // refresh replaces one episode's rows without touching its siblings.
    migrator.registerMigration("v74") { db in
      try db.create(table: "podcastEpisodeChapter") { t in
        t.autoIncrementedPrimaryKey("id")
        t.belongsTo("account", onDelete: .cascade).notNull()
        t.belongsTo("podcastEpisode", onDelete: .cascade).notNull()
        t.column("position", .integer).notNull()
        t.column("serverChapterId", .integer).notNull()
        t.column("start", .double).notNull()
        t.column("end", .double).notNull()
        t.column("title", .text)
      }
      try db.create(
        index: "index_podcastEpisodeChapter_on_episode_position", on: "podcastEpisodeChapter",
        columns: ["podcastEpisodeId", "position"], options: .unique)
    }

    // Chapters embedded in a downloaded native RSS episode's audio, parsed once per download.
    // `chaptersExtractedAt` is the per-download marker that separates "parsed, none found" from
    // "never parsed"; it and the rows are cleared whenever the file behind the row changes.
    migrator.registerMigration("v75") { db in
      try db.create(table: "rssEpisodeChapter") { t in
        t.autoIncrementedPrimaryKey("id")
        t.belongsTo("episode", inTable: "rssEpisode", onDelete: .cascade).notNull()
        t.column("position", .integer).notNull()
        t.column("start", .double).notNull()
        t.column("end", .double).notNull()
        t.column("title", .text)
      }
      try db.create(
        index: "index_rssEpisodeChapter_on_episode_position", on: "rssEpisodeChapter",
        columns: ["episodeId", "position"], options: .unique)
      try db.alter(table: "rssDownload") { t in t.add(column: "chaptersExtractedAt", .datetime) }
    }

    // PDFs that accompany an audiobook. Replaced as a set from each expanded refresh, like
    // `itemChapter`; `lastViewedPage` is device-local and never reaches the server, whose single
    // ebook position per item belongs to a real ebook edition. The direct account FK is what
    // `AccountRemover` discovers.
    migrator.registerMigration("v76") { db in
      try db.create(table: "itemSupplement") { t in
        t.autoIncrementedPrimaryKey("id")
        t.belongsTo("account", onDelete: .cascade).notNull()
        t.column("itemId", .integer).notNull()
        t.column("position", .integer).notNull()
        t.column("serverFileIno", .text).notNull()
        t.column("filename", .text)
        t.column("sizeBytes", .integer).notNull()
        t.column("lastViewedPage", .integer)
        t.foreignKey(
          ["accountId", "itemId"], references: "item", columns: ["accountId", "id"],
          onDelete: .cascade)
      }
      try db.create(
        index: "index_itemSupplement_on_item_ino", on: "itemSupplement",
        columns: ["itemId", "serverFileIno"], options: .unique)
    }

    // v76's set fills only from a fresh expanded fetch. A separate step so a database that already
    // ran v76 (a pre-release build) still gets it.
    migrator.registerMigration("v77") { db in
      // A book fetched before the table existed is served from its stored copy until the server
      // record moves, so it would never gain its set. Clears only the coverage marker, as v52
      // does, so the ordinary backfill fetches each one once. An unknown audio count is included:
      // a supplement needs audio, but a missing count proves nothing either way.
      try db.execute(
        sql: """
          UPDATE item
          SET expandedMetadataFetchedAt = NULL
          WHERE mediaKind != 'podcast' AND softDeleted = 0
            AND (numAudioFiles IS NULL OR numAudioFiles > 0)
          """)
    }

    // RSS refresh passes take a prefix of the candidate order. Ordering by last success would keep
    // an always-failing feed at the front of every pass; ordering by last attempt rotates it.
    // Seeding from the last success keeps the first pass after upgrade in its existing order.
    migrator.registerMigration("v78") { db in
      try db.alter(table: "rssFeed") { t in t.add(column: "lastRefreshAttemptAt", .datetime) }
      try db.execute(sql: "UPDATE rssFeed SET lastRefreshAttemptAt = lastRefreshedAt")
    }

    // Bounded automatic retry of failed automatic downloads. The count must outlive the process
    // (the overnight wake is a fresh one), so it is stored. Existing failed rows keep a NULL
    // deadline and are not retried retroactively.
    migrator.registerMigration("v79") { db in
      for table in ["download", "rssDownload"] {
        try db.alter(table: table) { t in
          t.add(column: "autoRetryCount", .integer).notNull().defaults(to: 0)
          t.add(column: "autoRetryNotBefore", .datetime)
        }
      }
    }

    // Audio prints for audio-gated transcription. The `.decoded` analysis state needs no change:
    // `state` has no CHECK.
    migrator.registerMigration("v80") { db in
      try AdSkipMigration.addAudioPrints(db)
    }
  }
}
