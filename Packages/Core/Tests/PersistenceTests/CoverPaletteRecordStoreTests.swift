import Foundation
import Testing

@testable import Persistence

@Suite("Cover palette store")
struct CoverPaletteStoreTests {
  @Test("round trips a palette")
  func roundTrips() async throws {
    let database = try AppDatabase.inMemory()
    let store = CoverPaletteRecordStore(database: database)
    let expected = CoverPaletteRecord(
      itemId: "item-1", artworkKey: "art-1", accentHue: 0.25, accentSaturation: 0.8,
      accentBrightness: 0.7, extractedAt: Date(timeIntervalSince1970: 1_000))

    try await store.upsert(expected)

    #expect(try await store.fetch(itemId: "item-1") == expected)
  }

  @Test("upsert replaces the artwork and accent")
  func upsertReplaces() async throws {
    let database = try AppDatabase.inMemory()
    let store = CoverPaletteRecordStore(database: database)
    try await store.upsert(
      CoverPaletteRecord(
        itemId: "item-1", artworkKey: "old", accentHue: 0.1, accentSaturation: 0.2,
        accentBrightness: 0.3, extractedAt: Date(timeIntervalSince1970: 1)))
    let replacement = CoverPaletteRecord(
      itemId: "item-1", artworkKey: "new", accentHue: 0.9, accentSaturation: 0.8,
      accentBrightness: 0.7, extractedAt: Date(timeIntervalSince1970: 2))

    try await store.upsert(replacement)

    #expect(try await store.fetch(itemId: "item-1") == replacement)
  }

  @Test("a nil accent is distinct from a missing row")
  func preservesNilAccent() async throws {
    let database = try AppDatabase.inMemory()
    let store = CoverPaletteRecordStore(database: database)
    let noAccent = CoverPaletteRecord(
      itemId: "item-1", artworkKey: "art-1", accentHue: nil, accentSaturation: nil,
      accentBrightness: nil, extractedAt: Date(timeIntervalSince1970: 1))

    try await store.upsert(noAccent)

    #expect(try await store.fetch(itemId: "item-1") == noAccent)
    #expect(try await store.fetch(itemId: "missing") == nil)
  }

  @Test("removeAll empties the table")
  func removeAllEmptiesTheTable() async throws {
    let database = try AppDatabase.inMemory()
    let store = CoverPaletteRecordStore(database: database)
    try await store.upsert(
      CoverPaletteRecord(
        itemId: "item-1", artworkKey: "art-1", accentHue: 0.1, accentSaturation: 0.2,
        accentBrightness: 0.3, extractedAt: Date()))
    try await store.upsert(
      CoverPaletteRecord(
        itemId: "item-2", artworkKey: "art-2", accentHue: 0.4, accentSaturation: 0.5,
        accentBrightness: 0.6, extractedAt: Date()))

    try await store.removeAll()

    #expect(try await store.fetch(itemIds: ["item-1", "item-2"]) == [])
  }

  @Test("batch fetch returns only requested rows and preserves artwork keys")
  func batchFetchReturnsOnlyRequestedRows() async throws {
    let database = try AppDatabase.inMemory()
    let store = CoverPaletteRecordStore(database: database)
    let matching = CoverPaletteRecord(
      itemId: "item-1", artworkKey: "scope|item-1|revision-1", accentHue: 0.25,
      accentSaturation: 0.8, accentBrightness: 0.7,
      extractedAt: Date(timeIntervalSince1970: 1_000))
    let stale = CoverPaletteRecord(
      itemId: "item-2", artworkKey: "scope|item-2|old-revision", accentHue: 0.1,
      accentSaturation: 0.2, accentBrightness: 0.3,
      extractedAt: Date(timeIntervalSince1970: 2_000))
    try await store.upsert(matching)
    try await store.upsert(stale)

    let records = try await store.fetch(itemIds: ["item-1", "item-2", "missing"])

    #expect(Set(records.map(\.itemId)) == Set(["item-1", "item-2"]))
    #expect(records.first(where: { $0.itemId == "item-1" })?.artworkKey == matching.artworkKey)
    #expect(records.first(where: { $0.itemId == "item-2" })?.artworkKey == stale.artworkKey)
    #expect(try await store.fetch(itemIds: ["missing"]) == [])
  }

  @Test("observing a row reports its absence, then each write to it")
  func observeReportsAbsenceThenWrites() async throws {
    let database = try AppDatabase.inMemory()
    let store = CoverPaletteRecordStore(database: database)
    let written = CoverPaletteRecord(
      itemId: "item-1", artworkKey: "art-1", accentHue: 0.25, accentSaturation: 0.8,
      accentBrightness: 0.7, extractedAt: Date(timeIntervalSince1970: 1_000))
    var values = store.observe(itemId: "item-1").makeAsyncIterator()

    #expect(await values.next() == .some(nil))

    try await store.upsert(
      CoverPaletteRecord(
        itemId: "other", artworkKey: "art-2", accentHue: nil, accentSaturation: nil,
        accentBrightness: nil, extractedAt: Date()))
    try await store.upsert(written)

    #expect(await values.next() == .some(written))
  }

  @Test("observing several rows reports those present, then each write to one of them")
  func observeSeveralReportsPresentThenWrites() async throws {
    let database = try AppDatabase.inMemory()
    let store = CoverPaletteRecordStore(database: database)
    let present = CoverPaletteRecord(
      itemId: "item-1", artworkKey: "art-1", accentHue: 0.25, accentSaturation: 0.8,
      accentBrightness: 0.7, extractedAt: Date(timeIntervalSince1970: 1_000))
    let written = CoverPaletteRecord(
      itemId: "item-2", artworkKey: "art-2", accentHue: 0.5, accentSaturation: 0.6,
      accentBrightness: 0.4, extractedAt: Date(timeIntervalSince1970: 2_000))
    try await store.upsert(present)
    var values = store.observe(itemIds: ["item-1", "item-2"]).makeAsyncIterator()

    #expect(await values.next() == [present])

    try await store.upsert(
      CoverPaletteRecord(
        itemId: "other", artworkKey: "art-3", accentHue: nil, accentSaturation: nil,
        accentBrightness: nil, extractedAt: Date()))
    try await store.upsert(written)

    #expect(await values.next() == [present, written])
  }

  @Test("v27 applies to fresh and previous-latest stores")
  func migrationAppliesToFreshAndPreviousLatestStores() throws {
    let fresh = try AppDatabase.inMemory()
    let freshHasTable = try fresh.read { db in try db.tableExists("coverPaletteRecord") }
    #expect(freshHasTable)

    let previousLatest = try AppDatabase.inMemory()
    try previousLatest.write { db in
      try db.execute(sql: "DROP TABLE coverPaletteRecord")
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: ["v27"])
    }
    try SchemaV1.migrator().migrate(previousLatest.dbWriter)
    let previousHasTable = try previousLatest.read { db in try db.tableExists("coverPaletteRecord") }
    #expect(previousHasTable)
  }
}
