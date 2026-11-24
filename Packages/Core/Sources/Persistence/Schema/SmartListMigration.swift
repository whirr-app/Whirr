import GRDB

/// v95: smart lists, their shows, the single active run, hidden episodes and download claims.
/// Every list table is device-owned and keyed by values that survive unfollow and re-login (a
/// feed URL, or `serverUserId|serverItemId`), never by `rssFeed.id` or `item.id`. Only the claim
/// table carries a nullable account foreign key, which is what account removal discovers.
enum SmartListMigration {
  static func migrate(_ db: Database) throws {
    try db.create(table: "smartList") { t in
      t.autoIncrementedPrimaryKey("id")
      t.column("name", .text).notNull()
      t.column("position", .integer).notNull().unique()
      t.column("showScope", .text).notNull().check(sql: "showScope IN ('all', 'allExcept', 'only')")
      t.column("includeUnplayed", .boolean).notNull()
      t.column("includeInProgress", .boolean).notNull()
      t.column("includePlayed", .boolean).notNull()
      t.column("includeDownloaded", .boolean).notNull()
      t.column("includeNotDownloaded", .boolean).notNull()
      t.column("savedOnly", .boolean).notNull().defaults(to: false)
      t.column("publishedWithinHours", .integer)
        .check(sql: "publishedWithinHours IS NULL OR publishedWithinHours IN (24, 72, 168, 336, 744)")
      t.column("durationFilter", .boolean).notNull().defaults(to: false)
      t.column("longerThanMinutes", .integer).notNull()
      t.column("shorterThanMinutes", .integer).notNull()
      t.column("sortOrder", .text).notNull()
        .check(sql: "sortOrder IN ('newest', 'oldest', 'shortest', 'longest')")
      t.column("autoDownload", .boolean).notNull().defaults(to: false)
      t.column("autoDownloadLimit", .integer).notNull().defaults(to: 10)
        .check(sql: "autoDownloadLimit IN (5, 10, 20, 40, 100)")
      t.column("createdAt", .datetime).notNull()
      t.column("updatedAt", .datetime).notNull()
      t.check(sql: "includeUnplayed OR includeInProgress OR includePlayed")
      t.check(sql: "includeDownloaded OR includeNotDownloaded")
    }

    try db.create(table: "smartListShow") { t in
      t.column("listId", .integer).notNull().references("smartList", onDelete: .cascade)
      t.column("source", .text).notNull().check(sql: "source IN ('native', 'server')")
      t.column("showKey", .text).notNull()
      t.column("role", .text).notNull().check(sql: "role IN ('included', 'excluded', 'priority')")
      t.column("titleSnapshot", .text).notNull()
      t.primaryKey(["listId", "source", "showKey"])
    }
    // The reading joins from the show side, by source and key.
    try db.create(
      index: "index_smartListShow_on_source_key", on: "smartListShow", columns: ["source", "showKey"])

    try db.create(table: "smartListRun") { t in
      t.column("id", .integer).primaryKey().check(sql: "id = 1")
      t.column("listId", .integer).notNull().references("smartList", onDelete: .cascade)
      t.column("anchorItemID", .text)
      t.column("anchorEpisodeID", .text)
      t.column("anchorSortKey", .text)
      t.column("startedAt", .datetime).notNull()
    }
    try db.create(index: "index_smartListRun_on_listId", on: "smartListRun", columns: ["listId"])

    try db.create(table: "smartListHiddenEpisode") { t in
      t.column("listId", .integer).notNull().references("smartList", onDelete: .cascade)
      t.column("itemID", .text).notNull()
      t.column("episodeID", .text).notNull()
      t.primaryKey(["listId", "itemID", "episodeID"])
    }

    try db.create(table: "smartListDownloadClaim") { t in
      t.column("listId", .integer).notNull().references("smartList", onDelete: .cascade)
      t.column("itemID", .text).notNull()
      t.column("episodeID", .text).notNull()
      t.belongsTo("account", onDelete: .cascade)
      t.column("claimedAt", .datetime).notNull()
      t.primaryKey(["listId", "itemID", "episodeID"])
    }
    try db.create(
      index: "index_smartListDownloadClaim_on_episode", on: "smartListDownloadClaim",
      columns: ["itemID", "episodeID"])

    try db.alter(table: "podcastRefreshState") { t in
      t.add(column: "lastCompleteEpisodeListAt", .datetime)
    }
  }
}
