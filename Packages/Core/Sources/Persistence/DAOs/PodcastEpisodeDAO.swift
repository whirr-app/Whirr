import Foundation
import GRDB

/// Read/write access to podcast episodes keyed by `(itemId, serverEpisodeId)`.
public struct PodcastEpisodeDAO: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func fetchOne(id: Int64) throws -> PodcastEpisodeRecord? {
    try database.read { db in try PodcastEpisodeRecord.fetchOne(db, key: id) }
  }

  public func fetchOne(itemId: Int64, serverEpisodeId: String) throws -> PodcastEpisodeRecord? {
    try database.read { db in
      try Self.fetchOne(db, itemId: itemId, serverEpisodeId: serverEpisodeId)
    }
  }

  public func fetchOneAsync(
    itemId: Int64,
    serverEpisodeId: String
  ) async throws -> PodcastEpisodeRecord? {
    try await database.readAsync { db in
      try Self.fetchOne(db, itemId: itemId, serverEpisodeId: serverEpisodeId)
    }
  }

  public func fetchAll(itemId: Int64) throws -> [PodcastEpisodeRecord] {
    try database.read { db in
      try PodcastEpisodeRecord
        .filter(Column("itemId") == itemId)
        .order(Column("serverEpisodeId"))
        .fetchAll(db)
    }
  }

  @discardableResult
  public func upsert(_ record: PodcastEpisodeRecord) throws -> PodcastEpisodeRecord {
    try database.write { db in try Self.upsert(record, db: db) }
  }

  @discardableResult
  public func upsertAsync(_ record: PodcastEpisodeRecord) async throws -> PodcastEpisodeRecord {
    try await database.writeAsync { db in try Self.upsert(record, db: db) }
  }

  private static func fetchOne(
    _ db: Database,
    itemId: Int64,
    serverEpisodeId: String
  ) throws -> PodcastEpisodeRecord? {
    try PodcastEpisodeRecord
      .filter(Column("itemId") == itemId)
      .filter(Column("serverEpisodeId") == serverEpisodeId)
      .fetchOne(db)
  }

  private static func upsert(
    _ record: PodcastEpisodeRecord,
    db: Database
  ) throws -> PodcastEpisodeRecord {
    var record = record
    if let existing = try fetchOne(
      db,
      itemId: record.itemId,
      serverEpisodeId: record.serverEpisodeId)
    {
      record.id = existing.id
    }
    try record.save(db)
    return record
  }
}
