import Foundation
import GRDB
import Testing

@testable import Persistence

/// `PauseTrimEpisodeStore`: one row per downloaded file, replaced in
/// place when the file or the detector changes, with the ad-skip identity rules.
@Suite struct PauseTrimEpisodeStoreTests {
  private func record(
    source: AdSkipEpisodeSource = .rss, accountId: Int64? = nil, itemID: String = "rss:1",
    episodeID: String = "guid-1", fileByteSize: Int64 = 1_000, detectorRevision: Int = 1,
    state: PauseTrimAnalysisState = .analysed, runs: Data? = Data([1, 2, 3])
  ) -> PauseTrimEpisodeRecord {
    PauseTrimEpisodeRecord(
      source: source, accountId: accountId, itemID: itemID, episodeID: episodeID,
      fileByteSize: fileByteSize, fileModificationTime: 1_700_000_000.123_456,
      detectorRevision: detectorRevision, state: state, runs: runs,
      analysedAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test func aSavedAnalysisReadsBackExactly() async throws {
    let store = PauseTrimEpisodeStore(database: try AppDatabase.inMemory())
    let saved = try await store.save(record())

    let read = try #require(try await store.episode(for: saved.identity))
    #expect(read == saved)
    #expect(read.fileModificationTime == 1_700_000_000.123_456)
    #expect(read.runs == Data([1, 2, 3]))
  }

  @Test func aMisalignedRowKeepsItsRuns() async throws {
    let store = PauseTrimEpisodeStore(database: try AppDatabase.inMemory())
    let saved = try await store.save(record(state: .misaligned, runs: Data([4, 5, 6])))

    let read = try #require(try await store.episode(for: saved.identity))
    #expect(read.state == .misaligned)
    #expect(read.runs == Data([4, 5, 6]))
  }

  @Test func aNewFingerprintOrRevisionReplacesTheRowInPlace() async throws {
    let store = PauseTrimEpisodeStore(database: try AppDatabase.inMemory())
    let first = try await store.save(record())

    let second = try await store.save(
      record(fileByteSize: 2_000, detectorRevision: 2, state: .misaligned, runs: nil))

    #expect(second.id == first.id)
    let read = try #require(try await store.episode(for: first.identity))
    #expect(read.fileByteSize == 2_000)
    #expect(read.detectorRevision == 2)
    #expect(read.state == .misaligned)
    #expect(read.runs == nil)
    #expect(try await store.allSummaries().count == 1)
  }

  @Test func rssRowsWithoutAnAccountCollideOnTheIdentityIndex() async throws {
    let database = try AppDatabase.inMemory()
    _ = try await PauseTrimEpisodeStore(database: database).save(record())

    await #expect(throws: DatabaseError.self) {
      try await database.writeAsync { db in
        var duplicate = record()
        try duplicate.insert(db)
      }
    }
  }

  @Test func theSameServerIdsUnderTwoAccountsAreTwoRows() async throws {
    let store = PauseTrimEpisodeStore(database: try AppDatabase.inMemory())
    _ = try await store.save(record(source: .abs, accountId: 1, itemID: "li", episodeID: "ep"))
    _ = try await store.save(record(source: .abs, accountId: 2, itemID: "li", episodeID: "ep"))

    #expect(try await store.allSummaries().map(\.identity.accountId) == [1, 2])
  }

  @Test func theSourceAndAccountMustAgree() async throws {
    let database = try AppDatabase.inMemory()
    await #expect(throws: DatabaseError.self) {
      try await database.writeAsync { db in
        var row = record(source: .abs, accountId: nil)
        try row.insert(db)
      }
    }
    await #expect(throws: DatabaseError.self) {
      try await database.writeAsync { db in
        var row = record(source: .rss, accountId: 3)
        try row.insert(db)
      }
    }
  }

  @Test func summariesCarryTheFingerprintRevisionAndState() async throws {
    let store = PauseTrimEpisodeStore(database: try AppDatabase.inMemory())
    let saved = try await store.save(record(state: .failed, runs: nil))

    #expect(
      try await store.allSummaries() == [
        PauseTrimEpisodeSummary(
          identity: saved.identity, fileByteSize: 1_000, fileModificationTime: 1_700_000_000.123_456,
          detectorRevision: 1, state: .failed)
      ])
  }

  @Test func deletingRemovesOnlyTheNamedRows() async throws {
    let store = PauseTrimEpisodeStore(database: try AppDatabase.inMemory())
    let kept = try await store.save(record(episodeID: "kept"))
    let gone = try await store.save(record(episodeID: "gone"))

    try await store.deleteEpisodes([gone.identity])

    #expect(try await store.episode(for: gone.identity) == nil)
    #expect(try await store.episode(for: kept.identity) != nil)
  }
}
