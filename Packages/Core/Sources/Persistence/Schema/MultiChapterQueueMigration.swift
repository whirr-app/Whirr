import GRDB

/// v107: an audiobook may have several Up Next rows, one per queued chapter, or one whole-book row,
/// never both (the store enforces the "never both"). The whole-book index keeps its released name,
/// which migration tests assert. The 0.5 s "same chapter" tolerance is a store rule; the index
/// only stops two rows with an identical chapter start.
enum MultiChapterQueueMigration {
  static func migrate(_ db: Database) throws {
    try db.drop(index: "index_listeningQueueEntry_on_account_item")
    try db.create(
      index: "index_listeningQueueEntry_on_account_item", on: "listeningQueueEntry",
      columns: ["accountId", "itemId"], options: .unique,
      condition: Column("podcastEpisodeId") == nil && Column("chapterStart") == nil)
    try db.create(
      index: "index_listeningQueueEntry_on_account_item_chapter", on: "listeningQueueEntry",
      columns: ["accountId", "itemId", "chapterStart"], options: .unique,
      condition: Column("podcastEpisodeId") == nil && Column("chapterStart") != nil)
  }
}
