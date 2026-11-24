import GRDB

/// Persists one podcast episode's chapters, reusing `StoredItemChapter` so playback maps books and
/// episodes identically. Scoped to a single episode row: replacing one never touches its siblings
/// or the item-level `itemChapter` rows books rely on.
public struct PodcastEpisodeChapterStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Replaces one episode's complete snapshot atomically. An empty list clears older rows, so
  /// chapters the server removed cannot survive a later refresh.
  public func replace(
    accountId: Int64, podcastEpisodeId: Int64, chapters: [StoredItemChapter]
  ) throws {
    try database.write { db in
      try Self.replace(
        db, accountId: accountId, podcastEpisodeId: podcastEpisodeId, chapters: chapters)
    }
  }

  public func fetch(accountId: Int64, podcastEpisodeId: Int64) throws -> [StoredItemChapter] {
    try database.read { db in
      try Self.fetch(db, accountId: accountId, podcastEpisodeId: podcastEpisodeId)
    }
  }

  public func fetchAsync(
    accountId: Int64, podcastEpisodeId: Int64
  ) async throws -> [StoredItemChapter] {
    try await database.readAsync { db in
      try Self.fetch(db, accountId: accountId, podcastEpisodeId: podcastEpisodeId)
    }
  }

  static func replace(
    _ db: Database, accountId: Int64, podcastEpisodeId: Int64, chapters: [StoredItemChapter]
  ) throws {
    try PodcastEpisodeChapterRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("podcastEpisodeId") == podcastEpisodeId)
      .deleteAll(db)

    for chapter in chapters {
      var record = PodcastEpisodeChapterRecord(
        accountId: accountId,
        podcastEpisodeId: podcastEpisodeId,
        position: chapter.position,
        serverChapterId: chapter.serverChapterId,
        start: chapter.start,
        end: chapter.end,
        title: chapter.title)
      try record.insert(db)
    }
  }

  private static func fetch(
    _ db: Database, accountId: Int64, podcastEpisodeId: Int64
  ) throws -> [StoredItemChapter] {
    try PodcastEpisodeChapterRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("podcastEpisodeId") == podcastEpisodeId)
      .order(Column("position"))
      .fetchAll(db)
      .map {
        StoredItemChapter(
          serverChapterId: $0.serverChapterId,
          position: $0.position,
          start: $0.start,
          end: $0.end,
          title: $0.title)
      }
  }
}
