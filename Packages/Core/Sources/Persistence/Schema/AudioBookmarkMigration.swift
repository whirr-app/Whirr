import GRDB

/// v87: Audiobookshelf audio bookmarks.
///
/// - `audioBookmark` mirrors the server's per-user list. A bookmark has no server id: it is
///   identified by `(serverItemId, time)` and the server matches `time` by numeric equality, so
///   `time` is a `REAL` holding the exact value sent or created. `serverItemId` is not a foreign
///   key to `item`: the list names items in libraries the device may not have pulled, and a
///   dropped row would come back as a deletion the listener never made. The account cascade
///   removes the rows.
/// - `outboxOperation.payloadBookmarkTime` and `payloadBookmarkTitle` carry a bookmark
///   operation's key and title, not reusing another kind's columns (the v21 ebook precedent).
enum AudioBookmarkMigration {
  static func migrate(_ db: Database) throws {
    try db.create(table: "audioBookmark") { t in
      t.column("accountId", .integer).notNull().references("account", onDelete: .cascade)
      t.column("serverItemId", .text).notNull()
      t.column("time", .double).notNull()
      t.column("title", .text).notNull()
      t.column("createdAt", .datetime)
      t.primaryKey(["accountId", "serverItemId", "time"])
    }
    try db.alter(table: "outboxOperation") { t in
      t.add(column: "payloadBookmarkTime", .double)
      t.add(column: "payloadBookmarkTitle", .text)
    }
  }
}
