import GRDB

/// One durable chapter boundary from an audiobook's expanded item metadata.
///
/// Downloads keep this small metadata snapshot separately from their audio-file rows so local
/// playback can rebuild the same chapter map without opening a server playback session.
public struct StoredItemChapter: Sendable, Equatable {
  public let serverChapterId: Int
  public let position: Int
  public let start: Double
  public let end: Double
  public let title: String?

  public init(
    serverChapterId: Int, position: Int, start: Double, end: Double, title: String?
  ) {
    self.serverChapterId = serverChapterId
    self.position = position
    self.start = start
    self.end = end
    self.title = title
  }
}

/// Persists the authoritative chapter snapshot returned by an expanded item-detail request.
public struct ItemChapterStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Replaces one item's complete snapshot atomically. An empty authoritative list clears any
  /// older rows, so removed server chapters cannot survive a later detail refresh.
  public func replace(
    accountId: Int64, itemId: Int64, chapters: [StoredItemChapter]
  ) throws {
    try database.write { db in
      try Self.replace(db, accountId: accountId, itemId: itemId, chapters: chapters)
    }
  }

  public func replaceAsync(
    accountId: Int64, itemId: Int64, chapters: [StoredItemChapter]
  ) async throws {
    try await database.writeAsync { db in
      try Self.replace(db, accountId: accountId, itemId: itemId, chapters: chapters)
    }
  }

  public func fetch(accountId: Int64, itemId: Int64) throws -> [StoredItemChapter] {
    try database.read { db in
      try Self.fetch(db, accountId: accountId, itemId: itemId)
    }
  }

  public func fetchAsync(accountId: Int64, itemId: Int64) async throws -> [StoredItemChapter] {
    try await database.readAsync { db in
      try Self.fetch(db, accountId: accountId, itemId: itemId)
    }
  }

  static func replace(
    _ db: Database, accountId: Int64, itemId: Int64, chapters: [StoredItemChapter]
  ) throws {
    try ItemChapterRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("itemId") == itemId)
      .deleteAll(db)

    for chapter in chapters {
      var record = ItemChapterRecord(
        accountId: accountId,
        itemId: itemId,
        position: chapter.position,
        serverChapterId: chapter.serverChapterId,
        start: chapter.start,
        end: chapter.end,
        title: chapter.title)
      try record.insert(db)
    }
  }

  private static func fetch(
    _ db: Database, accountId: Int64, itemId: Int64
  ) throws -> [StoredItemChapter] {
    try ItemChapterRecord
      .filter(Column("accountId") == accountId)
      .filter(Column("itemId") == itemId)
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
