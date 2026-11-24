import GRDB

/// v101: when the listener removed an Up Next entry's download by hand. It lives
/// on the queue row, so it ends with the entry: playback start, removal, or a Clear not undone.
/// Null means Download Up Next may fetch the entry.
enum UpNextDownloadDeclineMigration {
  static func migrate(_ db: Database) throws {
    for table in ["listeningQueueEntry", "rssListeningQueueEntry"] {
      try db.alter(table: table) { t in
        t.add(column: "downloadDeclinedAt", .datetime)
      }
    }
  }
}
