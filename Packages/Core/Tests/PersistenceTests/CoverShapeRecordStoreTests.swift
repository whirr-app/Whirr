import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite("CoverShapeRecordStore")
struct CoverShapeRecordStoreTests {
  @Test("a shape is stored per item and replaced by a later measurement")
  func upsertReplacesTheRow() async throws {
    let store = CoverShapeRecordStore(database: try AppDatabase.inMemory())
    let measuredAt = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.upsert(
      CoverShapeRecord(
        itemId: "item-1", revision: "100", aspectRatio: 0.667, fitPixelWidth: 660, measuredAt: measuredAt))
    try await store.upsert(
      CoverShapeRecord(itemId: "item-1", revision: "200", aspectRatio: 1, fitPixelWidth: 900, measuredAt: measuredAt))
    try await store.upsert(
      CoverShapeRecord(itemId: "item-2", revision: "100", aspectRatio: 1.5, fitPixelWidth: 990, measuredAt: measuredAt))

    #expect(
      try await store.fetch(itemId: "item-1")
        == CoverShapeRecord(
          itemId: "item-1", revision: "200", aspectRatio: 1, fitPixelWidth: 900, measuredAt: measuredAt))
    #expect(try await store.fetchAll().count == 2)
  }

  @Test("v94 creates the table on a database migrated from v93")
  func v94CreatesTheTable() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v93")
    #expect(try queue.read { try $0.tableExists("coverShape") } == false)

    try SchemaV1.migrator().migrate(queue)

    let columns = try queue.read { try $0.columns(in: "coverShape").map(\.name) }
    #expect(columns == ["itemId", "revision", "aspectRatio", "fitPixelWidth", "measuredAt"])
  }
}
