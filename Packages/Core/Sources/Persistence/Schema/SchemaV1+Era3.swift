import GRDB

extension SchemaV1 {
  /// Registers migrations `v41`–`v60`, called in order from `migrator()`.
  ///
  /// Migrations `v41`–`v60`. Every body is verbatim from the original `SchemaV1.swift`.
  static func registerEra3(
    on migrator: inout DatabaseMigrator,
    rssListeningQueueMigrationCheckpoint:
      @escaping @Sendable (RSSListeningQueueMigrationCheckpoint) throws -> Void,
    nativeListeningQueueMigrationCheckpoint:
      @escaping @Sendable (NativeListeningQueueMigrationCheckpoint) throws -> Void,
    rssSavedShelfMigrationCheckpoint:
      @escaping @Sendable (RSSSavedShelfMigrationCheckpoint) throws -> Void
  ) {
    // The server's account-wide Continue Series dismissals are keyed by series id. The full
    // replacement set is kept locally so the Home shelf can resolve ids through its entity index.
    migrator.registerMigration("v41") { db in
      try db.create(table: "hiddenContinueSeries") { t in
        t.column("accountId", .integer).notNull().references("account", onDelete: .cascade)
        t.column("serverSeriesId", .text).notNull()
        t.primaryKey(["accountId", "serverSeriesId"])
      }
    }

    migrator.registerMigration("v42") { db in
      try addRSSPodcastPersistence(db)
    }

    // Native RSS identifiers are device-owned and reserve the `rss:` namespace. Quarantine any
    // legacy server row that already occupies it so ABS pulls cannot surface or orchestrate it.
    migrator.registerMigration("v43") { db in
      try db.execute(sql: "UPDATE item SET softDeleted = 1 WHERE serverItemId LIKE 'rss:%'")
    }

    // Native show ordering is device-owned, so it has no account foreign key. A singleton row
    // records the active ordering mode; feed rows keep custom positions.
    migrator.registerMigration("v44") { db in
      try db.create(table: "rssShowOrder") { t in
        t.column("id", .integer).primaryKey().check { $0 == 0 }
        t.column("mode", .text).notNull()
      }
    }

    // Feed documents may omit duration. The device-measured value is kept separate from the
    // declared field so a later refresh that still omits duration does not erase it.
    migrator.registerMigration("v45") { db in
      try db.alter(table: "rssEpisode") { t in
        t.add(column: "measuredDurationSeconds", .double)
      }
    }

    // Device-owned counterpart of `playbackBookmark`: which native episode was last played. No
    // account foreign key, so it survives account removal with the rest of the RSS data. Position
    // is joined from `rssEpisodeState` rather than duplicated.
    migrator.registerMigration("v46") { db in
      try db.create(table: "rssPlaybackBookmark") { t in
        t.column("id", .integer).primaryKey().check { $0 == 0 }
        t.column("episodeId", .integer).notNull().references("rssEpisode", onDelete: .cascade)
        t.column("updatedAt", .datetime).notNull()
      }
    }

    // The account-owned queue stays one ordering while gaining a device-owned RSS episode source.
    // Rebuilt because SQLite cannot relax itemId nullability or add the exactly-one-source
    // invariant in place. The migration transaction makes every checkpoint rollback-safe.
    migrator.registerMigration("v47") { db in
      try rebuildListeningQueueForRSS(
        db, checkpoint: rssListeningQueueMigrationCheckpoint)
    }

    // Notification policy and discovery state are device-owned. The ledger references the
    // subscription, never an episode row, so a feed dropping and re-presenting an episode cannot
    // turn a swept row into a second first sighting. Unsubscribing cascades both tables and
    // re-baselines.
    migrator.registerMigration("v48") { db in
      try db.execute(
        sql: """
          ALTER TABLE rssFeedSettings
          ADD COLUMN notificationOverride TEXT NOT NULL DEFAULT 'inherit'
          CHECK (notificationOverride IN ('inherit', 'enabled', 'disabled'))
          """)
      try db.create(table: "rssNotificationFeedBaseline") { t in
        t.column("feedId", .integer).primaryKey().references("rssFeed", onDelete: .cascade)
        t.column("establishedAt", .datetime).notNull()
      }
      try db.create(table: "rssEpisodeNotificationLedger") { t in
        t.column("feedId", .integer).notNull().references("rssFeed", onDelete: .cascade)
        t.column("identityKey", .text).notNull()
        t.column("disposition", .text).notNull()
        t.check(
          sql: """
            disposition IN (
              'silentBaseline', 'pending', 'suppressedForeground', 'suppressedDisabled',
              'suppressedIneligible', 'suppressedLifecycle', 'scheduled', 'alias'
            )
            """)
        t.column("firstSeenAt", .datetime).notNull()
        t.column("scheduledRequestID", .text)
        t.primaryKey(["feedId", "identityKey"])
      }
      try db.create(
        index: "index_rssEpisodeNotificationLedger_on_disposition_firstSeen",
        on: "rssEpisodeNotificationLedger", columns: ["disposition", "firstSeenAt"])
    }

    // Reserved podcast-source identities are not ordinary server tombstones. Records which legacy
    // rows v43 withheld, then makes their queued mutations terminal before any item can be reaped.
    // The marker is detached from `item` so the audit survives that reaping; account removal still
    // cascades it. Ordinary soft deletion stays reversible and does not quarantine runnable work.
    migrator.registerMigration("v49") { db in
      try db.create(table: "itemQuarantine") { t in
        t.column("itemId", .integer).primaryKey()
        t.column("accountId", .integer).notNull().references("account", onDelete: .cascade)
        t.column("serverItemId", .text).notNull()
        t.column("reason", .text).notNull()
          .check { $0 == "reservedPodcastSourceIdentity" }
        t.column("quarantinedAt", .datetime).notNull()
        t.column("terminalizedOperationCount", .integer).notNull()
          .check { $0 >= 0 }
      }
      try db.create(
        index: "index_itemQuarantine_on_account_serverItemId", on: "itemQuarantine",
        columns: ["accountId", "serverItemId"])
      try db.execute(
        sql: """
          INSERT INTO itemQuarantine (
            itemId, accountId, serverItemId, reason, quarantinedAt,
            terminalizedOperationCount
          )
          SELECT
            item.id,
            item.accountId,
            item.serverItemId,
            'reservedPodcastSourceIdentity',
            CURRENT_TIMESTAMP,
            (
              SELECT COUNT(*)
              FROM outboxOperation
              WHERE outboxOperation.accountId = item.accountId
                AND (
                  outboxOperation.entityKey = item.serverItemId
                  OR EXISTS (
                    SELECT 1
                    FROM playbackSession
                    WHERE playbackSession.id = outboxOperation.playbackSessionId
                      AND playbackSession.accountId = item.accountId
                      AND playbackSession.itemId = item.id
                  )
                )
            )
          FROM item
          WHERE item.serverItemId LIKE 'rss:%'
          """)
      try db.execute(
        sql: """
          UPDATE outboxOperation
          SET state = 'deadLetter',
              nextAttemptAt = NULL,
              deadLetterReason = ?
          WHERE EXISTS (
            SELECT 1
            FROM itemQuarantine
            WHERE itemQuarantine.accountId = outboxOperation.accountId
              AND (
                itemQuarantine.serverItemId = outboxOperation.entityKey
                OR EXISTS (
                  SELECT 1
                  FROM playbackSession
                  WHERE playbackSession.id = outboxOperation.playbackSessionId
                    AND playbackSession.accountId = itemQuarantine.accountId
                    AND playbackSession.itemId = itemQuarantine.itemId
                )
              )
          )
          """,
        arguments: [OutboxStore.quarantinedItemDeadLetterReason])
    }

    // A credentialed native follow stays visible when Keychain storage does not complete. This
    // device-owned marker holds no credential, URL or error detail; it only blocks refresh until
    // the credential form repairs the feed.
    migrator.registerMigration("v50") { db in
      try db.create(table: "rssFeedRecovery") { t in
        t.column("feedId", .integer).primaryKey().references("rssFeed", onDelete: .cascade)
        t.column("reason", .text).notNull()
          .check { $0 == "credentialStorageFailed" }
        t.column("createdAt", .datetime).notNull()
      }
    }

    // A server-side copy of one device-owned RSS episode is an account-owned operation. The local
    // RSS identities are value references, not foreign keys: feed refresh may prune an episode
    // while a save is in flight, and the durable attempt must stay available for reconciliation
    // instead of cascading away with the device-owned row.
    migrator.registerMigration("v51") { db in
      try createNativeEpisodeServerSaveAttempt(db)
    }

    // Existing expanded book rows have no expected sizes. Clears only their coverage marker so the
    // ordinary metadata backfill repopulates the new nullable columns.
    migrator.registerMigration("v52") { db in
      try db.alter(table: "item") { t in
        t.add(column: "audioDownloadExpectedBytes", .integer)
        t.add(column: "ebookDownloadExpectedBytes", .integer)
      }
      try db.execute(
        sql: """
          UPDATE item
          SET expandedMetadataFetchedAt = NULL
          WHERE mediaKind != 'podcast' AND softDeleted = 0
          """)
    }

    // Saved for Later can carry either an account-owned ABS identity or a device-owned RSS
    // episode. Rebuilt because SQLite cannot relax itemId nullability or add the source check in
    // place. The account FK stays authoritative for ownership; the RSS FK only supplies
    // episode-row cascade semantics.
    migrator.registerMigration("v53") { db in
      try rebuildSavedShelfForRSS(db)
    }

    // A device-owned episode can be dismissed from Continue Listening. The flag lives on the state
    // row, not the episode row, because it belongs to this device's listening history and a feed
    // refresh rewrites episode rows.
    migrator.registerMigration("v54") { db in
      try db.alter(table: "rssEpisodeState") { t in
        t.add(column: "hideFromContinueListening", .boolean).notNull().defaults(to: false)
      }
    }

    // The show list draws one truncated plain line per episode while the card draws the whole
    // description as paragraphs. Storing the line at refresh time keeps the list query, and the
    // duplicate comparison behind it, free of the feed's HTML. NULL means the row has not been
    // refreshed yet; the presentation then strips the description at row time.
    migrator.registerMigration("v55") { db in
      try db.alter(table: "rssEpisode") { t in t.add(column: "synopsisLine", .text) }
    }

    // A genuine finish resolves Saved for Later like a genuine start, whichever source owns the
    // episode. The released triggers watched position only, so an account-owned "Mark as
    // Finished" at position zero (unknown duration) and a device-owned finish (position
    // untouched) left the entry behind. Both trigger pairs are recreated so an already-finished
    // insert or a false to true finish removes the identity, while a repeated finished write
    // leaves a later re-save alone. Reconciliation follows v36's chronology: only an entry whose
    // finish is stamped after its save goes.
    migrator.registerMigration("v56") { db in
      for trigger in [
        "savedShelfProgress_ai", "savedShelfProgress_au",
        "savedShelfRSSProgress_ai", "savedShelfRSSProgress_au",
      ] {
        try db.execute(sql: "DROP TRIGGER IF EXISTS \(trigger)")
      }
      try db.execute(
        sql: """
          DELETE FROM savedShelfEntry
          WHERE savedShelfEntry.itemId IS NOT NULL
            AND EXISTS (
              SELECT 1
              FROM mediaProgress AS progress
              WHERE progress.accountId = savedShelfEntry.accountId
                AND progress.itemId = savedShelfEntry.itemId
                AND (
                  (progress.podcastEpisodeId IS NULL
                    AND savedShelfEntry.podcastEpisodeId IS NULL)
                  OR progress.podcastEpisodeId = savedShelfEntry.podcastEpisodeId
                )
                AND progress.isFinished = 1
                AND COALESCE(progress.lastActivityAt, progress.serverUpdatedAt) > savedShelfEntry.savedAt
            )
          """)
      try db.execute(
        sql: """
          DELETE FROM savedShelfEntry
          WHERE savedShelfEntry.rssEpisodeId IS NOT NULL
            AND EXISTS (
              SELECT 1
              FROM rssEpisodeState AS state
              WHERE state.episodeId = savedShelfEntry.rssEpisodeId
                AND state.finished = 1
                AND state.updatedAt > savedShelfEntry.savedAt
            )
          """)
      try createSavedShelfResolutionTriggers(db)
    }

    // Feed identity is stored as an opaque fingerprint so native RSS shows can be matched with
    // their server-owned twins without keeping a server feed URL on an item row. The RSS table
    // still owns its raw URL for fetching; only valid legacy URLs are backfilled. Server item rows
    // stay nil until the next library traversal because their raw feed URL was never stored, so no
    // identity can be reconstructed safely.
    migrator.registerMigration("v57") { db in
      try db.alter(table: "rssFeed") { t in
        t.add(column: "podcastFeedFingerprint", .text)
      }
      try db.alter(table: "item") { t in
        t.add(column: "podcastFeedFingerprint", .text)
      }
      try db.create(
        index: "index_rssFeed_on_podcastFeedFingerprint",
        on: "rssFeed",
        columns: ["podcastFeedFingerprint"])
      try db.create(
        index: "index_item_on_account_podcastFeedFingerprint",
        on: "item",
        columns: ["accountId", "podcastFeedFingerprint"])
      try backfillPodcastFeedFingerprints(db)
    }

    migrator.registerMigration("v58") { db in
      try migrateNativePodcastSettings(db)
    }
    migrator.registerMigration("v59") { db in
      try splitRSSListeningQueue(db, checkpoint: nativeListeningQueueMigrationCheckpoint)
    }
    migrator.registerMigration("v60") { db in
      try rebuildSavedShelfForNativeRSS(db, checkpoint: rssSavedShelfMigrationCheckpoint)
    }
  }
}
