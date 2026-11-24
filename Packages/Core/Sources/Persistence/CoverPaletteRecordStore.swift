import GRDB

/// Persists artwork-derived cover palettes. The artwork key is returned with every row so callers
/// can reject a palette after an artwork variant changes.
public struct CoverPaletteRecordStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func fetch(itemId: String) async throws -> CoverPaletteRecord? {
    try await database.readAsync { db in
      try CoverPaletteRecord.fetchOne(db, key: itemId)
    }
  }

  public func fetch(itemIds: [String]) async throws -> [CoverPaletteRecord] {
    guard itemIds.isEmpty == false else { return [] }
    let ids = Set(itemIds)
    return try await database.readAsync { db in
      try CoverPaletteRecord
        .filter(ids.contains(Column("itemId")))
        .fetchAll(db)
    }
  }

  /// The row for `itemId` now, then again after every write to it. Several surfaces write the same
  /// row, each on its own terms, so a surface that missed its own extraction follows this to take
  /// whichever writer's result arrives first.
  public func observe(itemId: String) -> AsyncStream<CoverPaletteRecord?> {
    // The observed region is the whole table, so another item's write re-reads this row unchanged.
    ObservationBridge.stream(
      in: database.dbWriter, deduplication: .unchangedValuesSuppressed
    ) { db in
      try CoverPaletteRecord.fetchOne(db, key: itemId)
    }
  }

  /// The rows present for `itemIds` now, ordered by item id, then again after every write that
  /// changes them. One observation for a screen's worth of cards rather than one per card.
  public func observe(itemIds: [String]) -> AsyncStream<[CoverPaletteRecord]> {
    let ids = Array(Set(itemIds))
    return ObservationBridge.stream(
      in: database.dbWriter, deduplication: .unchangedValuesSuppressed
    ) { db in
      try CoverPaletteRecord
        .filter(ids.contains(Column("itemId")))
        .order(Column("itemId"))
        .fetchAll(db)
    }
  }

  public func upsert(_ record: CoverPaletteRecord) async throws {
    try await database.writeAsync { db in
      try record.save(db)
    }
  }

  public func remove(itemId: String) async throws {
    try await database.writeAsync { db in
      try CoverPaletteRecord.deleteOne(db, key: itemId)
    }
  }

  public func removeAll() async throws {
    try await database.writeAsync { db in
      _ = try CoverPaletteRecord.deleteAll(db)
    }
  }
}
