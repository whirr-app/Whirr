import GRDB

/// One writer owns ordering across both source tables. Signed transfer IDs distinguish rows whose
/// physical IDs coincide; RSS IDs are negated only in memory and in UI projections.
enum NativeListeningQueueWriter {
  static let unionSQL = """
    SELECT id, accountId, itemId, podcastEpisodeId, NULL AS rssEpisodeId,
           position, 0 AS sourceTag, id AS rowID, chapterStart, chapterEnd, chapterTitle
    FROM listeningQueueEntry
    UNION ALL
    SELECT -id AS id, 0 AS accountId, NULL AS itemId, NULL AS podcastEpisodeId,
           rssEpisodeId, position, 1 AS sourceTag, id AS rowID,
           NULL AS chapterStart, NULL AS chapterEnd, NULL AS chapterTitle
    FROM rssListeningQueueEntry
    """

  static func records(in db: Database) throws -> [ListeningQueueEntryRecord] {
    try ListeningQueueEntryRecord.fetchAll(
      db,
      sql: """
        SELECT * FROM (\(unionSQL)) ORDER BY position, sourceTag, rowID
        """)
  }

  static func compact(in db: Database) throws {
    try persist(records(in: db), in: db)
  }

  static func persist(
    _ source: [ListeningQueueEntryRecord], in db: Database,
    checkpoint: @Sendable (ListeningQueueMutationCheckpoint) throws -> Void = { _ in }
  ) throws {
    var rows = source
    // Start below every existing position. This also repairs a preexisting negative position
    // without colliding with an index while the remaining rows have yet to move.
    let minimum = try Int.fetchOne(db, sql: "SELECT MIN(position) FROM (\(unionSQL))") ?? 0
    let offset = min(minimum, 0) - rows.count - 1
    for index in rows.indices {
      rows[index].position = offset - index
      try save(&rows[index], in: db)
    }
    try checkpoint(.afterTemporaryRenumber)
    for index in rows.indices {
      rows[index].position = index
      try save(&rows[index], in: db)
    }
    try checkpoint(.afterFinalRenumber)
  }

  private static func save(_ row: inout ListeningQueueEntryRecord, in db: Database) throws {
    if let episode = row.rssEpisodeId {
      if let id = row.id {
        try db.execute(
          sql: "UPDATE rssListeningQueueEntry SET position = ? WHERE id = ?",
          arguments: [row.position, -id])
      } else {
        try db.execute(
          sql: "INSERT INTO rssListeningQueueEntry (rssEpisodeId, position) VALUES (?, ?)",
          arguments: [episode, row.position])
        row.id = -db.lastInsertedRowID
      }
    } else {
      if row.id == nil { try row.insert(db) } else { try row.update(db) }
    }
  }

  static func delete(_ row: ListeningQueueEntryRecord, in db: Database) throws {
    guard let id = row.id else { return }
    if row.rssEpisodeId != nil {
      try db.execute(sql: "DELETE FROM rssListeningQueueEntry WHERE id = ?", arguments: [-id])
    } else {
      _ = try row.delete(db)
    }
  }

  static func revision(in db: Database) throws -> Int64 {
    try Int64.fetchOne(db, sql: "SELECT revision FROM nativeListeningQueueRevision WHERE id = 1") ?? 0
  }

  @discardableResult
  static func bumpRevision(in db: Database) throws -> Int64 {
    let current = try revision(in: db)
    guard current < Int64.max else { throw ListeningQueueStoreError.restoreTokenStale }
    try db.execute(
      sql: "UPDATE nativeListeningQueueRevision SET revision = ? WHERE id = 1",
      arguments: [current + 1])
    return current + 1
  }
}
