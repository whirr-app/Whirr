import GRDB

/// The core tables migration `v1` creates, and the `v2` heal that brings an existing store's
/// `item` row up to the same shape.
///
/// Registered by `SchemaV1.registerEra1`; `SchemaV1.migrator()` holds the order. These bodies are
/// frozen: an applied migration is never edited in place.
extension SchemaV1 {

  // MARK: - v1: account, library and catalogue tables

  static func createAccount(_ db: Database) throws {
    try db.create(table: "account") { t in
      t.autoIncrementedPrimaryKey("id")
      // Generated once at first login and never regenerated on relaunch. It is the origin key
      // for local progress writes.
      t.column("clientUUID", .text).notNull().unique()
      t.column("serverBaseURL", .text).notNull()
      t.column("serverUserId", .text).notNull()
      t.column("serverVersion", .text).notNull()
      // Nullable: some servers/users have no default library configured.
      t.column("defaultLibraryId", .text)
    }
    try db.create(
      index: "index_account_on_serverBaseURL_serverUserId", on: "account",
      columns: ["serverBaseURL", "serverUserId"], options: .unique)
  }

  static func createLibrary(_ db: Database) throws {
    try db.create(table: "library") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("serverLibraryId", .text).notNull()
      t.column("mediaType", .text).notNull()
      t.column("name", .text).notNull()
      t.column("lastSeenGeneration", .integer).notNull().defaults(to: 0)
    }
    try db.create(
      index: "index_library_on_account_serverLibraryId", on: "library",
      columns: ["accountId", "serverLibraryId"], options: .unique)
  }

  static func createItem(_ db: Database) throws {
    try db.create(table: "item") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.belongsTo("library", onDelete: .cascade).notNull()
      t.column("serverItemId", .text).notNull()
      t.column("mediaKind", .text).notNull()
      t.column("title", .text).notNull()
      t.column("sortTitle", .text).notNull()
      t.column("author", .text)
      t.column("durationSeconds", .double)
      // Home's recently-added sort and the audiobook/podcast/ebook category signals
      // (`ItemMediaCategory.derive` consumes the latter two; `mediaKind` already carries the
      // podcast signal). Nullable: a server whose minified shape omits them simply yields nils.
      t.column("addedAt", .datetime)
      t.column("numAudioFiles", .integer)
      t.column("ebookFormat", .text)
      t.column("lastSeenGeneration", .integer).notNull()
      t.column("softDeleted", .boolean).notNull().defaults(to: false)
    }
    // Item identity: unique on (libraryId, serverItemId).
    try db.create(
      index: "index_item_on_library_serverItemId", on: "item",
      columns: ["libraryId", "serverItemId"], options: .unique)
    // Browse projection index: library + softDeleted + sort title.
    try db.create(
      index: "index_item_browse", on: "item",
      columns: ["libraryId", "softDeleted", "sortTitle"])
    // Home's recently-added row (account-scoped and cross-library, unlike the library-scoped
    // browse index above).
    try db.create(
      index: "index_item_recently_added", on: "item",
      columns: ["accountId", "softDeleted", "addedAt"])
  }

  static func createPodcastEpisode(_ db: Database) throws {
    try db.create(table: "podcastEpisode") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.belongsTo("item", onDelete: .cascade).notNull()
      t.column("serverEpisodeId", .text).notNull()
      t.column("title", .text).notNull()
      t.column("episodeNumber", .text)
      t.column("lastSeenGeneration", .integer).notNull()
      t.column("softDeleted", .boolean).notNull().defaults(to: false)
    }
    // Episode identity: unique on (itemId, serverEpisodeId).
    try db.create(
      index: "index_podcastEpisode_on_item_serverEpisodeId", on: "podcastEpisode",
      columns: ["itemId", "serverEpisodeId"], options: .unique)
  }

  static func createMediaProgress(_ db: Database) throws {
    try db.create(table: "mediaProgress") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.belongsTo("item", onDelete: .cascade).notNull()
      t.belongsTo("podcastEpisode", onDelete: .cascade)
      t.column("currentTime", .double).notNull()
      t.column("isFinished", .boolean).notNull()
      t.column("serverUpdatedAt", .datetime)
      // Database-monotonic local ordering; never rely on wall time alone.
      t.column("localSequence", .integer).notNull()
      t.column("origin", .text).notNull()
      // Stable origin key: the account's persisted client UUID for local state, the fixed
      // sentinel "server" for pulled state.
      t.column("originKey", .text).notNull()
    }
    // One progress identity per item (episodeId IS NULL) or per episode (SQLite treats NULLs as
    // distinct in a plain unique index, so the item-level case needs its own partial index).
    try db.create(
      index: "index_mediaProgress_on_account_item", on: "mediaProgress",
      columns: ["accountId", "itemId"], options: .unique,
      condition: Column("podcastEpisodeId") == nil)
    try db.create(
      index: "index_mediaProgress_on_account_episode", on: "mediaProgress",
      columns: ["accountId", "podcastEpisodeId"], options: .unique,
      condition: Column("podcastEpisodeId") != nil)
  }

  /// Durable home for the server observation the zero-position guard rejects (a near-zero server
  /// pull against substantial local progress), so a later "take server" resolution has something
  /// to apply. One open conflict per item identity; a later pull that re-detects the same
  /// conflict refreshes this row rather than stacking a duplicate.
  static func createProgressConflict(_ db: Database) throws {
    try db.create(table: "progressConflict") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.belongsTo("item", onDelete: .cascade).notNull()
      t.column("serverCurrentTime", .double).notNull()
      t.column("serverIsFinished", .boolean).notNull()
      t.column("serverUpdatedAt", .datetime)
      t.column("detectedAt", .datetime).notNull()
    }
    try db.create(
      index: "index_progressConflict_on_account_item", on: "progressConflict",
      columns: ["accountId", "itemId"], options: .unique)
  }

  static func createOutboxOperation(_ db: Database) throws {
    try db.create(table: "outboxOperation") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("clientOperationId", .text).notNull().unique()
      t.column("entityKey", .text).notNull()
      t.column("operationKind", .text).notNull()
      t.column("coalescingKey", .text).notNull()
      t.column("payloadVersion", .integer).notNull()
      t.column("localSequence", .integer).notNull()
      t.column("attempts", .integer).notNull().defaults(to: 0)
      t.column("nextAttemptAt", .datetime)
      t.column("state", .text).notNull()
      // Versioned payload. Coalescing needs somewhere to keep the newest position/flags and the
      // accumulated unacknowledged listening delta for `progress`-kind operations;
      // `payloadVersion` describes this shape when it is 1.
      t.column("payloadCurrentTime", .double)
      t.column("payloadIsFinished", .boolean)
      t.column("payloadAccumulatedDeltaSeconds", .double)
      // `sessionSync`/`sessionClose` reuse `payloadCurrentTime`/`payloadAccumulatedDeltaSeconds`
      // above (same meaning as for `progress`) but need their own optional `/sync` duration field.
      t.column("payloadDurationSeconds", .double)
      // Which local `playbackSession` row a `sessionSync`/`sessionClose` operation belongs to.
      // `entityKey` (a plain string) groups a drain queue but is not safe to join back to a
      // specific session row, so this is an explicit FK. Nil for `progress`-kind rows.
      t.belongsTo("playbackSession", onDelete: .cascade)
      // Privacy-safe reason retained on entering `deadLetter`; cleared when a row leaves
      // `deadLetter` so a later dead-letter never shows a stale reason.
      t.column("deadLetterReason", .text)
    }
    // Outbox drain index: state + nextAttempt.
    try db.create(
      index: "index_outboxOperation_drain", on: "outboxOperation",
      columns: ["state", "nextAttemptAt"])
    // Lookups/cleanup of a session's outbox rows without a full table scan.
    try db.create(
      index: "index_outboxOperation_on_playbackSession", on: "outboxOperation",
      columns: ["playbackSessionId"])
  }

  static func createPlaybackSession(_ db: Database) throws {
    try db.create(table: "playbackSession") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("clientSessionId", .text).notNull().unique()
      t.column("serverSessionId", .text)
      t.belongsTo("item", onDelete: .cascade).notNull()
      t.belongsTo("podcastEpisode", onDelete: .cascade)
      t.column("startedAt", .datetime).notNull()
      t.column("updatedAt", .datetime).notNull()
      t.column("listenedDeltaSeconds", .double).notNull().defaults(to: 0)
      t.column("closePending", .boolean).notNull().defaults(to: false)
      t.column("isOffline", .boolean).notNull().defaults(to: false)
      // Session position, duration, lifecycle state, and the last local sequence applied to this
      // session must survive every crash boundary alongside the columns above.
      t.column("globalPosition", .double).notNull().defaults(to: 0)
      t.column("duration", .double)
      t.column("state", .text).notNull().defaults(to: PlaybackSessionState.active.rawValue)
      t.column("lastLocalSequence", .integer).notNull().defaults(to: 0)
    }
    // One locally-active online session per account/device (v1 has exactly one device per
    // account, so "device" and "account" coincide). Quarantined/offline rows are excluded so
    // quarantining a duplicate or an offline session never blocks a fresh online session.
    try db.create(
      index: "index_playbackSession_one_active_per_account", on: "playbackSession",
      columns: ["accountId"], options: .unique,
      condition: Column("isOffline") == false && Column("state") == PlaybackSessionState.active.rawValue
    )
    // The same one-active-session-per-device invariant for the local (offline) side: a device
    // never has two locally-active offline sessions either, though they never contend with the
    // online index above (disjoint on `isOffline`).
    try db.create(
      index: "index_playbackSession_one_active_offline_per_account", on: "playbackSession",
      columns: ["accountId"], options: .unique,
      condition: Column("isOffline") == true && Column("state") == PlaybackSessionState.active.rawValue
    )
  }

  /// One row per audio file. Carries the server file's own identity, its ordering/MIME/duration
  /// metadata, and the durable hold/error-category bookkeeping `DownloadStore`'s transition matrix
  /// relies on. `errorCategory` is a closed enum, matching `syncRun.errorCategory`'s privacy-safe
  /// shape rather than risking a raw message.
  static func createDownload(_ db: Database) throws {
    try db.create(table: "download") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.belongsTo("item", onDelete: .cascade).notNull()
      t.belongsTo("podcastEpisode", onDelete: .cascade)
      t.column("serverFileIno", .text).notNull()
      t.column("orderIndex", .integer).notNull()
      t.column("destinationRelativePath", .text).notNull()
      t.column("expectedBytes", .integer).notNull()
      t.column("expectedMimeType", .text).notNull()
      t.column("fileDurationSeconds", .double).notNull()
      t.column("receivedBytes", .integer).notNull().defaults(to: 0)
      // Retired: byte-level resume was never implemented and `DownloadRecord` has no such field,
      // so the column is inert and always NULL. Kept because dropping it would cost a migration
      // plus a guarded heal on every store already on a device, for no behavioural gain. Do not
      // write it without reviving the whole feature.
      t.column("resumeData", .blob)
      t.column("state", .text).notNull()
      t.column("holdReason", .text)
      t.column("errorCategory", .text)
    }
    // Identity: one row per (account, item, episode-or-null, server file). A plain unique index
    // would not catch duplicate audiobook (null-episode) downloads, since SQLite compares NULLs as
    // distinct inside a unique index, so this uses the same two-partial-index split as
    // `mediaProgress` above.
    try db.create(
      index: "index_download_on_account_item_fileIno", on: "download",
      columns: ["accountId", "itemId", "serverFileIno"], options: .unique,
      condition: Column("podcastEpisodeId") == nil)
    try db.create(
      index: "index_download_on_account_item_episode_fileIno", on: "download",
      columns: ["accountId", "itemId", "podcastEpisodeId", "serverFileIno"], options: .unique,
      condition: Column("podcastEpisodeId") != nil)
  }

  static func createSyncRun(_ db: Database) throws {
    try db.create(table: "syncRun") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.belongsTo("library", onDelete: .cascade)
      t.column("reason", .text).notNull()
      t.column("generation", .integer).notNull()
      t.column("startedAt", .datetime).notNull()
      t.column("completedAt", .datetime)
      t.column("state", .text).notNull()
      t.column("errorCategory", .text)
      // The sort requested for this run's item traversal (a deterministic sort by stable id where
      // supported). Recorded, not verified: it does not confirm the server honoured it.
      t.column("sortRequested", .text)
    }
  }

  static func createSyncPage(_ db: Database) throws {
    try db.create(table: "syncPage") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.belongsTo("syncRun", onDelete: .cascade).notNull()
      t.column("pageNumber", .integer).notNull()
      t.column("itemCount", .integer).notNull()
      t.column("fetchedAt", .datetime).notNull()
      t.column("resultCategory", .text)
    }
    try db.create(
      index: "index_syncPage_on_syncRun_pageNumber", on: "syncPage",
      columns: ["syncRunId", "pageNumber"], options: .unique)
  }

  /// Bounded, account-scoped diagnostics (ARCHITECTURE.md D16). `category`/`statusClass` are
  /// closed enums and `endpointTemplate` is a validated template string, never a payload, token
  /// or concrete URL. `accountId` cascades like every other account-owned table, so the
  /// schema-driven removal sweep picks this table up automatically.
  static func createDiagnosticsEvent(_ db: Database) throws {
    try db.create(table: "diagnosticsEvent") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("category", .text).notNull()
      t.column("statusClass", .text).notNull()
      t.column("durationMilliseconds", .double).notNull()
      t.column("endpointTemplate", .text)
      t.column("occurredAt", .datetime).notNull()
    }
    // Rolling-cap eviction: oldest-first per account, ordered by insertion (rowid).
    try db.create(
      index: "index_diagnosticsEvent_on_account_id", on: "diagnosticsEvent",
      columns: ["accountId", "id"])
  }

  /// The per-account estimated server-clock offset `OutboxDrainer` needs at `local-all` upload
  /// time. One row per account.
  static func createObservedServerTime(_ db: Database) throws {
    try db.create(table: "observedServerTime") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("offsetSeconds", .double).notNull()
      t.column("observedAt", .datetime).notNull()
    }
    try db.create(
      index: "index_observedServerTime_on_account", on: "observedServerTime",
      columns: ["accountId"], options: .unique)
  }

  /// Cached listening-session history per account + item, populated from
  /// `GET /api/me/listening-sessions` and read offline-first by the item detail screen's History
  /// list. Upsert identity is `(accountId, itemId, sessionId)`, so a refresh re-fetching the same
  /// server session updates the row rather than duplicating it.
  static func createListeningHistoryEntry(_ db: Database) throws {
    try db.create(table: "listeningHistoryEntry") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.belongsTo("item", onDelete: .cascade).notNull()
      t.column("sessionId", .text).notNull()
      t.column("startedAt", .datetime).notNull()
      t.column("startPosition", .double).notNull()
      t.column("endPosition", .double).notNull()
      t.column("listenedSeconds", .double).notNull()
    }
    try db.create(
      index: "index_listeningHistoryEntry_on_account_item_session", on: "listeningHistoryEntry",
      columns: ["accountId", "itemId", "sessionId"], options: .unique)
  }

  /// The account's playback bookmark: the item (and, for a podcast, the episode) this device last
  /// had loaded in the player. At most one row per account, enforced by a unique index on
  /// `accountId`. No stored position: it is joined from `mediaProgress` at read time, so progress
  /// never rewrites this row.
  ///
  /// Idempotent (`.ifNotExists`) because it runs from both `v1` (fresh stores) and the `v3` heal.
  static func createPlaybackBookmark(_ db: Database) throws {
    try db.create(table: "playbackBookmark", options: .ifNotExists) { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.belongsTo("item", onDelete: .cascade).notNull()
      t.belongsTo("podcastEpisode", onDelete: .cascade)
      t.column("updatedAt", .datetime).notNull()
    }
    try db.create(
      index: "index_playbackBookmark_on_account", on: "playbackBookmark",
      columns: ["accountId"], options: [.unique, .ifNotExists])
  }

  /// The durable account-removal journal. Not account-owned: `accountRowId` is a plain copy of the
  /// account row's id via `t.column(...)`, never `t.belongsTo("account", onDelete: .cascade)`, so
  /// the row survives the account row's deletion mid-removal. It is therefore excluded from
  /// `AccountRemover.discoverAccountOwnedTables`, which
  /// `AccountRemovalTests.removalSweepDiscoversExactlyTheSchemasAccountOwnedTables` pins.
  static func createAccountRemovalJournal(_ db: Database) throws {
    try db.create(table: "accountRemovalJournal") { t in
      t.autoIncrementedPrimaryKey("id")
      t.column("serverBaseURL", .text).notNull()
      t.column("serverUserId", .text).notNull()
      t.column("accountRowId", .integer).notNull()
      t.column("downloadsRootRelativePath", .text).notNull()
      t.column("createdAt", .datetime).notNull()
    }
  }

  // MARK: - v2: heal the `item` Home columns

  /// Brings `item` up to the Home column set on a store that already exists.
  ///
  /// An in-place amendment of `v1` never reaches existing stores, so one from before the
  /// `ebookFileFormat` to `ebookFormat` rename would fail every Home query with "no such column:
  /// item.ebookFormat".
  ///
  /// Converges from any of three states: current (no-op), post-amendment-but-pre-rename (rename,
  /// values intact), or pre-amendment (add the columns). Each step is guarded by introspection.
  static func healItemHomeColumns(_ db: Database) throws {
    let columnNames = Set(try db.columns(in: "item").map(\.name))

    if columnNames.contains("ebookFormat") == false {
      if columnNames.contains("ebookFileFormat") {
        // Rename rather than add-and-drop: the values are real synced data.
        try db.alter(table: "item") { t in
          t.rename(column: "ebookFileFormat", to: "ebookFormat")
        }
      } else {
        try db.alter(table: "item") { t in t.add(column: "ebookFormat", .text) }
      }
    }
    if columnNames.contains("addedAt") == false {
      try db.alter(table: "item") { t in t.add(column: "addedAt", .datetime) }
    }
    if columnNames.contains("numAudioFiles") == false {
      try db.alter(table: "item") { t in t.add(column: "numAudioFiles", .integer) }
    }

    // Created by `v1` for fresh stores; missing on any store that predates the amendment.
    try db.create(
      index: "index_item_recently_added", on: "item",
      columns: ["accountId", "softDeleted", "addedAt"], options: .ifNotExists)
  }
}
