import GRDB

extension SchemaV1 {
  /// Registers migrations `v21`–`v40`, called in order from `migrator()`.
  ///
  /// Migrations `v21`–`v40`. Every body is verbatim from the original `SchemaV1.swift`.
  static func registerEra2(
    on migrator: inout DatabaseMigrator
  ) {
    // Durable ebook-position payload fields. Ebook operations get their own nullable columns so
    // the drain cannot silently route them through the audio PATCH builder. The shared finish has
    // no payload columns: its kind fixes its body to `{isFinished: true}`.
    migrator.registerMigration("v21") { db in
      try db.alter(table: "outboxOperation") { t in
        t.add(column: "payloadEbookProgress", .double)
        t.add(column: "payloadEbookLocation", .text)
      }
    }

    // Legacy diagnostics rows used a category/status vocabulary that predates ARCHITECTURE.md D16.
    // Normalised in place so record decoding stays closed-enum; safe to repeat on every store.
    migrator.registerMigration("v22") { db in
      try db.execute(
        sql: "UPDATE diagnosticsEvent SET category = ? WHERE category = ?",
        arguments: ["syncRun", "sync"])
      try db.execute(
        sql: "UPDATE diagnosticsEvent SET statusClass = ? WHERE statusClass = ?",
        arguments: ["success", "2xx"])
    }

    // Read-only podcast server settings from the expanded show response. Nullable, so an absent
    // server field stays distinguishable from a supplied zero.
    migrator.registerMigration("v23") { db in
      try db.alter(table: "item") { t in
        t.add(column: "podcastAutoDownloadSchedule", .text)
        t.add(column: "podcastMaxEpisodesToKeep", .integer)
        t.add(column: "podcastMaxNewEpisodesToDownload", .integer)
      }
    }

    // An EPUB's table of contents lives inside the file, so it is kept as a flattened snapshot
    // beside the item. The Contents tab then answers from the database even after the download
    // is deleted, and `startProgression` gives it the same read/unread derivation audiobook
    // chapters get from the playhead.
    migrator.registerMigration("v24") { db in
      try createEbookTOCEntry(db)
    }

    // A library deleted on the server must stop being searched locally, since `SyncEngine.search`
    // fans out over every local row and an orphan 404s on every search. Tombstoned rather than
    // deleted, for the reason `DownloadIntegritySweep` states: `library` cascades to `item` and
    // through it to `download`, so deleting the row would let the next sweep reclaim the reader's
    // downloaded files over an inference that a single server response can reverse.
    migrator.registerMigration("v25") { db in
      try db.alter(table: "library") { t in
        t.add(column: "softDeleted", .boolean).notNull().defaults(to: false)
      }
    }

    // Orders the Home carousels by what was last played or read. `serverUpdatedAt` moves only
    // when a server observation wins a merge (a local tick never touches it), and `localSequence`
    // is a per-row edit counter, so neither answers "when". Existing rows are seeded from
    // `serverUpdatedAt`; that is wrong for the item playing right now, but its next tick
    // re-stamps it.
    migrator.registerMigration("v26") { db in
      try db.alter(table: "mediaProgress") { t in
        t.add(column: "lastActivityAt", .datetime)
      }
      try backfillActivityStamps(db)
    }

    // Cover artwork extraction is expensive and valid only for the artwork variant identified by
    // artworkKey. The accent triplet is nullable so a completed no-accent extraction is distinct
    // from an item that has never been extracted.
    migrator.registerMigration("v27") { db in
      try createCoverPaletteRecord(db)
    }

    // The `/api/session/local-all` upload is the whole session object and the server takes
    // `startTime` from it alone (only online `/play` computes one), so an offline listen without a
    // recorded start uploads null: History shows "Started at 00:00" and resumes from zero.
    // Nullable and unbackfilled: sessions open at upgrade have no recoverable start, and `0`
    // would claim the start of the book.
    migrator.registerMigration("v28") { db in
      try db.alter(table: "playbackSession") { t in
        t.add(column: "startPosition", .double)
      }
    }

    migrator.registerMigration("v29") { db in
      try db.create(table: "itemPlaybackSettings") { t in
        t.column("itemId", .integer).primaryKey()
        // Direct FK so AccountRemover's schema-driven sweep discovers this table at all.
        t.belongsTo("account", onDelete: .cascade).notNull()
        // Composite FK so a wrong-account item id cannot be modelled. `index_item_on_account_id`
        // already exists from v14.
        t.foreignKey(
          ["accountId", "itemId"], references: "item",
          columns: ["accountId", "id"], onDelete: .cascade)
        t.column("rateStep", .integer).notNull()
      }
      try db.create(
        index: "index_itemPlaybackSettings_on_account_item", on: "itemPlaybackSettings",
        columns: ["accountId", "itemId"], options: .unique)
    }

    // `/filterdata` is a complete per-library snapshot. The marker is separate from the entity rows
    // so a successful response with no authors or series stays cached and distinguishable from a
    // library that has never been fetched.
    migrator.registerMigration("v30") { db in
      try db.create(table: "libraryFilterDataSnapshot") { t in
        t.column("libraryId", .integer).primaryKey().references("library", onDelete: .cascade)
        t.column("fetchedAt", .datetime).notNull()
      }
      try db.create(table: "libraryEntityIndex") { t in
        t.autoIncrementedPrimaryKey("id")
        t.belongsTo("library", onDelete: .cascade).notNull()
        t.column("kind", .text).notNull()
        t.column("serverEntityId", .text).notNull()
        t.column("name", .text).notNull()
        t.column("normalizedName", .text).notNull()
        t.column("bookCount", .integer)
      }
      try db.create(
        index: "index_libraryEntityIndex_on_library_kind_entity", on: "libraryEntityIndex",
        columns: ["libraryId", "kind", "serverEntityId"], options: .unique)
      try db.create(
        index: "index_libraryEntityIndex_on_kind_name_library", on: "libraryEntityIndex",
        columns: ["kind", "normalizedName", "libraryId"])
    }

    // A local generated cover has no server bytes to download. The minified response's
    // cover-availability signal lives on the item so Library Cache can exclude an explicit absence
    // without treating older or trimmed payloads (nil) as absent. Nullable and unbackfilled.
    migrator.registerMigration("v31") { db in
      try db.alter(table: "item") { t in
        t.add(column: "hasServerArtwork", .boolean)
      }
    }

    // Library inclusion is device-local. Existing accounts stay in compatibility mode with every
    // library included, so upgrading keeps the all-library behaviour.
    migrator.registerMigration("v32") { db in
      try db.alter(table: "account") { t in
        t.add(column: "librarySelectionMode", .text).notNull().defaults(
          to: LibrarySelectionMode.all.rawValue)
      }
      try db.alter(table: "library") { t in
        t.add(column: "isIncluded", .boolean).notNull().defaults(to: true)
      }
      try db.create(
        index: "index_library_on_account_visibility_media", on: "library",
        columns: ["accountId", "softDeleted", "isIncluded", "mediaType"])
    }

    // `/api/session/{id}/sync` is additive and returns no body, so a request that landed while
    // its response was lost looks unlanded, and replaying it double-counts listening time. This
    // column holds the cumulative seconds the server has been seen to accept, comparable against
    // the session's `timeListening` ledger. Sessions open at upgrade start at `0`, which
    // understates: the first reconciliation reads the server as ahead and treats the attempt as
    // landed.
    migrator.registerMigration("v33") { db in
      try db.alter(table: "playbackSession") { t in
        t.add(column: "acknowledgedListenedSeconds", .double).notNull().defaults(to: 0)
      }
    }

    // Saved for Later is account-owned: the direct account FK is load-bearing because
    // AccountRemover discovers account-owned tables through that FK and verifies their rows by
    // accountId. Two partial unique indexes are required because SQLite treats NULL as distinct
    // in an ordinary unique index, so whole-item and episode saves need separate uniqueness rules.
    migrator.registerMigration("v34") { db in
      try createSavedShelfEntry(db)
    }

    // Saved entries retain the titles they displayed when saved, so a referenced item can be
    // hard-tombstoned without leaving an unlabelled, unmanageable card. Additive to v34; keep
    // createSavedShelfEntry stable for fresh stores, which run v34 followed by this migration.
    migrator.registerMigration("v35") { db in
      try db.alter(table: "savedShelfEntry") { t in
        t.add(column: "subjectTitle", .text).notNull().defaults(to: "")
        t.add(column: "contextTitle", .text)
      }
      try db.execute(
        sql: """
          UPDATE savedShelfEntry
          SET subjectTitle = CASE
            WHEN podcastEpisodeId IS NULL THEN COALESCE(
              (SELECT item.title
               FROM item
               WHERE item.id = savedShelfEntry.itemId
                 AND item.accountId = savedShelfEntry.accountId),
              '')
            ELSE COALESCE(
              (SELECT episode.title
               FROM podcastEpisode AS episode
               WHERE episode.id = savedShelfEntry.podcastEpisodeId
                 AND episode.itemId = savedShelfEntry.itemId
                 AND episode.accountId = savedShelfEntry.accountId),
              '')
          END,
          contextTitle = CASE
            WHEN podcastEpisodeId IS NULL THEN NULL
            ELSE COALESCE(
              (SELECT item.title
               FROM item
               WHERE item.id = savedShelfEntry.itemId
                 AND item.accountId = savedShelfEntry.accountId),
              '')
          END
          """)
    }

    // Saved for Later is the pre-start state: once durable audio or ebook progress is positive the
    // identity belongs in Continue Listening / Continue Reading. An explicit save made after
    // earlier progress is respected until a later position change removes it. Triggers cover
    // every progress writer without coupling them to SavedShelfStore. The migration uses activity
    // chronology to reconcile only entries progressed after saving.
    migrator.registerMigration("v36") { db in
      try db.execute(
        sql: """
          DELETE FROM savedShelfEntry
          WHERE EXISTS (
            SELECT 1
            FROM mediaProgress AS progress
            WHERE progress.accountId = savedShelfEntry.accountId
              AND progress.itemId = savedShelfEntry.itemId
              AND (
                (progress.podcastEpisodeId IS NULL
                  AND savedShelfEntry.podcastEpisodeId IS NULL)
                OR progress.podcastEpisodeId = savedShelfEntry.podcastEpisodeId
              )
              AND (
                COALESCE(progress.currentTime, 0) > 0
                OR COALESCE(progress.ebookProgress, 0) > 0
              )
              AND COALESCE(progress.lastActivityAt, progress.serverUpdatedAt) > savedShelfEntry.savedAt
          )
          """)
      try createSavedShelfProgressTriggers(db)
    }

    // The server's Continue Listening visibility is separate from completion. Kept locally so
    // account refreshes can suppress a manually removed item without rewriting its position or
    // finished state. Any later local audio position write clears the flag, matching the server's
    // "listened again" behaviour.
    migrator.registerMigration("v37") { db in
      try db.alter(table: "mediaProgress") { t in
        t.add(column: "hideFromContinueListening", .boolean).notNull().defaults(to: false)
      }
    }

    // Field-only progress PATCH payload for Continue Listening visibility. Nullable so other
    // operation kinds need no invented default.
    migrator.registerMigration("v38") { db in
      try db.alter(table: "outboxOperation") { t in
        t.add(column: "payloadHideFromContinueListening", .boolean)
      }
    }

    // The page colour is chosen between the selected cluster and the area average by the
    // cluster's share of the cover, so a palette row with only the accent cannot rebuild the page.
    // Nullable: a pre-existing row's evidence cannot be invented, so it reads as stale and is
    // backfilled on the next extraction rather than dropped.
    migrator.registerMigration("v39") { db in
      try db.alter(table: "coverPaletteRecord") { t in
        t.add(column: "clusterWeight", .double)
        t.add(column: "clusterRed", .double)
        t.add(column: "clusterGreen", .double)
        t.add(column: "clusterBlue", .double)
        t.add(column: "averageRed", .double)
        t.add(column: "averageGreen", .double)
        t.add(column: "averageBlue", .double)
      }
    }

    // Continue Series may hide books at or before the highest finished sequence. Existing rows use
    // the server's false default until the next library refresh supplies the setting.
    migrator.registerMigration("v40") { db in
      try db.alter(table: "library") { t in
        t.add(column: "onlyShowLaterBooksInContinueSeries", .boolean).notNull().defaults(to: false)
      }
    }
  }
}
