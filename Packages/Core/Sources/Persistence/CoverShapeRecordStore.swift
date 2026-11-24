import GRDB

/// Persists each cover's measured shape.
public struct CoverShapeRecordStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func fetchAll() async throws -> [CoverShapeRecord] {
    try await database.readAsync { db in
      try CoverShapeRecord.fetchAll(db)
    }
  }

  public func fetch(itemId: String) async throws -> CoverShapeRecord? {
    try await database.readAsync { db in
      try CoverShapeRecord.fetchOne(db, key: itemId)
    }
  }

  public func upsert(_ record: CoverShapeRecord) async throws {
    try await database.writeAsync { db in
      try record.save(db)
    }
  }
}
