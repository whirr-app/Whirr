import GRDB

/// The podcast tables that are not queue or search state: episode presentation metadata
/// (`v5`), device auto-download settings (`v13`) and custom show ordering (`v14`).
///
/// Registered by `SchemaV1.registerEra1`; `SchemaV1.migrator()` holds the order. The bodies are
/// frozen: an applied migration is never edited in place.
extension SchemaV1 {

  // MARK: - v5: podcast persistence

  static func addPodcastPersistence(_ db: Database) throws {
    try db.alter(table: "item") { t in
      t.add(column: "podcastAutoDownloadEpisodes", .boolean)
      t.add(column: "podcastLastEpisodeCheck", .datetime)
    }

    try db.alter(table: "podcastEpisode") { t in
      t.add(column: "subtitle", .text)
      t.add(column: "episodeDescription", .text)
      t.add(column: "seasonNumber", .text)
      t.add(column: "episodeType", .text)
      t.add(column: "mimeType", .text)
      t.add(column: "durationSeconds", .double)
      t.add(column: "sizeBytes", .integer)
      t.add(column: "publishedAt", .datetime)
      t.add(column: "storedAudioIno", .text)
      t.add(column: "storedAudioExpectedSize", .integer)
      t.add(column: "storedAudioMimeType", .text)
      t.add(column: "storedAudioDurationSeconds", .double)
    }
    try db.create(
      index: "index_podcastEpisode_browse", on: "podcastEpisode",
      columns: ["itemId", "softDeleted", "publishedAt", "serverEpisodeId"])

    // Conflicts mirror mediaProgress's item-or-episode identity. SQLite treats NULLs as distinct
    // in a plain unique index, so item and episode scopes need separate partial indexes.
    try db.drop(index: "index_progressConflict_on_account_item")
    try db.alter(table: "progressConflict") { t in
      t.add(column: "podcastEpisodeId", .integer)
        .references("podcastEpisode", onDelete: .cascade)
    }
    try db.create(
      index: "index_progressConflict_on_account_item", on: "progressConflict",
      columns: ["accountId", "itemId"], options: .unique,
      condition: Column("podcastEpisodeId") == nil)
    try db.create(
      index: "index_progressConflict_on_account_episode", on: "progressConflict",
      columns: ["accountId", "podcastEpisodeId"], options: .unique,
      condition: Column("podcastEpisodeId") != nil)

    // An outbox progress row keeps the same scope as the local progress it protects. `entityKey`
    // is the server item id the wire endpoint consumes; this FK distinguishes show-level from
    // episode-level operations without encoding a second identity into that string.
    try db.alter(table: "outboxOperation") { t in
      t.add(column: "podcastEpisodeId", .integer)
        .references("podcastEpisode", onDelete: .cascade)
    }
    try db.create(
      index: "index_outboxOperation_on_podcastEpisode", on: "outboxOperation",
      columns: ["podcastEpisodeId"])
  }

  // MARK: - v13: podcast device auto-download settings

  /// `podcastSettings` is one row per account (global defaults); `podcastShowSettings` is one row
  /// per show, overriding those defaults. `podcastShowSettings.itemId` is the primary key (as with
  /// `podcastRefreshState.itemId`) rather than an autoincremented id, since a show has at most one
  /// settings row; the `(accountId, itemId)` unique index exists anyway so a schema-driven query
  /// never has to trust that invariant unchecked.
  static func addPodcastDeviceDownloadSettings(_ db: Database) throws {
    try db.create(table: "podcastSettings") { t in
      t.column("accountId", .integer).primaryKey().references("account", onDelete: .cascade)
      t.column("autoDownloadEnabled", .boolean).notNull().defaults(to: false)
      t.column("keepLatestCount", .integer).notNull().defaults(to: 3)
      t.column("deleteAfterPlayed", .boolean).notNull().defaults(to: false)
      t.column("allowCellularAutoDownload", .boolean).notNull().defaults(to: false)
      // Global activation floor: stamped when effective auto-download flips Off -> On.
      t.column("enabledAt", .datetime)
    }

    try db.create(table: "podcastShowSettings") { t in
      t.column("itemId", .integer).primaryKey().references("item", onDelete: .cascade)
      t.belongsTo("account", onDelete: .cascade).notNull()
      // inherit|enabled|disabled (`PodcastShowAutoDownloadOverride`); an unrecognised stored
      // value is a query-time concern, not the migration's.
      t.column("autoDownloadOverride", .text).notNull().defaults(to: "inherit")
      // NULL = inherit the global count; 0 = keep all.
      t.column("keepLatestOverride", .integer)
      // NULL = inherit the global flag.
      t.column("deleteAfterPlayedOverride", .boolean)
      // Show activation floor.
      t.column("enabledAt", .datetime)
    }
    try db.create(
      index: "index_podcastShowSettings_on_account_item", on: "podcastShowSettings",
      columns: ["accountId", "itemId"], options: .unique)

    try db.alter(table: "podcastEpisode") { t in
      // Stamped only when the automatic pass creates a download row for this episode, never by a
      // manual request. Survives a manual delete, which keeps a manually deleted automatic
      // download from being silently re-downloaded.
      t.add(column: "autoDownloadDecidedAt", .datetime)
    }

    try db.alter(table: "download") { t in
      // manual|automatic (`DownloadOrigin`). Existing rows default to `.manual`. A row only ever
      // moves from automatic to manual (a manual request promotes it), never the reverse.
      t.add(column: "origin", .text).notNull().defaults(to: DownloadOrigin.manual.rawValue)
    }
  }

  // MARK: - v14: custom podcast show ordering

  /// `podcastShowOrder` is one optional row per account recording custom order (`mode`, currently
  /// only `"custom"`); no row means alphabetical, so none is inserted here. `podcastShowOrderEntry`
  /// has v6's `createPodcastQueueEntry` shape with `itemId` for `podcastEpisodeId`: a unique
  /// `(accountId, id)` index on `item` allows a composite `(accountId, itemId)` cascading FK, so a
  /// wrong-account item id cannot be modelled and deleting a show drops only its position row.
  static func createPodcastShowOrder(_ db: Database) throws {
    try db.create(
      index: "index_item_on_account_id", on: "item",
      columns: ["accountId", "id"], options: .unique)

    try db.create(table: "podcastShowOrder") { t in
      t.column("accountId", .integer).primaryKey().references("account", onDelete: .cascade)
      t.column("mode", .text).notNull()
    }

    try db.create(table: "podcastShowOrderEntry") { t in
      t.autoIncrementedPrimaryKey("id")
      t.belongsTo("account", onDelete: .cascade).notNull()
      t.column("itemId", .integer).notNull()
      t.column("position", .integer).notNull()
      t.foreignKey(
        ["accountId", "itemId"], references: "item",
        columns: ["accountId", "id"], onDelete: .cascade)
    }
    try db.create(
      index: "index_podcastShowOrderEntry_on_account_item", on: "podcastShowOrderEntry",
      columns: ["accountId", "itemId"], options: .unique)
    try db.create(
      index: "index_podcastShowOrderEntry_on_account_position", on: "podcastShowOrderEntry",
      columns: ["accountId", "position"], options: .unique)
  }
}
