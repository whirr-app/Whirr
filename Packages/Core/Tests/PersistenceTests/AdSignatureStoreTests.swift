import Foundation
import GRDB
import Testing

@testable import Persistence

/// The signature store's persistence contract: one transaction per change, full-range hashes,
/// and an efficient full load.
@Suite struct AdSignatureStoreTests {

  /// Whole milliseconds, which is all the `.datetime` column keeps.
  private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private func creative(
    kind: AdSignatureKind = .learned, lastSeen: Date = AdSignatureStoreTests.t0,
    start: Double = 10, end: Double = 40, teachers: Set<String> = ["ep-a", "ep-b"],
    hashes: Set<UInt64> = [1, 2, 3], confirmed: Bool = false
  ) -> NewAdSignatureCreative {
    NewAdSignatureCreative(
      kind: kind, lastSeen: lastSeen, startTime: start, endTime: end, teachers: teachers,
      hashes: hashes, confirmed: confirmed)
  }

  private func makeStore() throws -> (AdSignatureStore, AppDatabase) {
    let database = try AppDatabase.inMemory()
    return (AdSignatureStore(database: database), database)
  }

  @Test func learnedAndTombstoneCreativesRoundTrip() async throws {
    let (store, _) = try makeStore()
    let extremes: Set<UInt64> = [0, UInt64(Int64.max) + 1, UInt64.max, UInt64(Int64.max)]
    let learned = creative(teachers: ["a", "b"], hashes: extremes)
    let tombstone = creative(
      kind: .tombstone, lastSeen: Self.t0.addingTimeInterval(5.25), start: 1.5, end: 2.5,
      teachers: ["c"], hashes: [42])
    let ids = try await store.apply(AdSignatureStoreChange(insertions: [learned, tombstone]))
    #expect(ids.count == 2)
    let all = try await store.allCreatives()
    #expect(all.map(\.id) == ids)
    #expect(all[0].kind == .learned)
    #expect(all[0].teachers == ["a", "b"])
    #expect(all[0].hashes == extremes)
    #expect(all[0].lastSeen == Self.t0)
    #expect(all[1].kind == .tombstone)
    #expect(all[1].startTime == 1.5)
    #expect(all[1].endTime == 2.5)
    #expect(all[1].lastSeen == Self.t0.addingTimeInterval(5.25))
    #expect(all[1].teachers == ["c"])
    #expect(all[1].hashes == [42])
  }

  @Test func aLearnedCreativeKeepsItsAudioPrintAndATombstoneNever() async throws {
    let (store, _) = try makeStore()
    var learned = creative(teachers: ["a"])
    learned.audioPrint = Data([1, 0, 0, 0, 2, 0, 0, 0])
    var tombstone = creative(kind: .tombstone, teachers: ["b"])
    tombstone.audioPrint = Data([9, 9, 9, 9])
    let plain = creative(teachers: ["c"])
    let ids = try await store.apply(AdSignatureStoreChange(insertions: [learned, tombstone, plain]))

    #expect(try await store.allCreatives().map(\.hasAudioPrint) == [true, false, false])
    #expect(
      try await store.learnedAudioPrints() == [
        StoredAdSignatureAudioPrint(id: ids[0], teachers: ["a"], audioPrint: learned.audioPrint ?? Data())
      ])

    _ = try await store.apply(AdSignatureStoreChange(deletions: [ids[0]]))
    #expect(try await store.learnedAudioPrints().isEmpty)
  }

  @Test func aLearnedCreativeKeepsConfirmedAndATombstoneNever() async throws {
    let (store, _) = try makeStore()
    _ = try await store.apply(
      AdSignatureStoreChange(insertions: [
        creative(confirmed: true), creative(), creative(kind: .tombstone, confirmed: true),
      ]))
    #expect(try await store.allCreatives().map(\.confirmed) == [true, false, false])
  }

  /// A listener's short mark may hold no shingle: its print is what reaches other episodes.
  @Test func onlyAConfirmedCreativeWithAPrintMayHaveNoHashes() async throws {
    let (store, _) = try makeStore()
    let print = Data([1, 0, 0, 0, 2, 0, 0, 0])
    var confirmed = creative(hashes: [], confirmed: true)
    confirmed.audioPrint = print
    let ids = try await store.apply(AdSignatureStoreChange(insertions: [confirmed]))
    let stored = try #require(try await store.allCreatives().first { $0.id == ids.first })
    #expect(stored.hashes.isEmpty)
    #expect(stored.confirmed)
    #expect(try await store.learnedAudioPrints().map { [$0.id: $0.confirmed] } == ids.map { [$0: true] })

    var unconfirmed = creative(hashes: [])
    unconfirmed.audioPrint = print
    var noPrint = creative(hashes: [], confirmed: true)
    noPrint.audioPrint = Data()
    for refused in [
      unconfirmed, noPrint, creative(hashes: [], confirmed: true), creative(kind: .tombstone, hashes: []),
    ] {
      await #expect(throws: AdSignatureStoreError.creativeHasNoHashes) {
        try await store.apply(AdSignatureStoreChange(insertions: [refused]))
      }
    }
  }

  @Test func aCreativeMayHaveNoTeachers() async throws {
    let (store, _) = try makeStore()
    _ = try await store.apply(AdSignatureStoreChange(insertions: [creative(teachers: [])]))
    #expect(try await store.allCreatives().first?.teachers == [])
  }

  @Test func applyDeletesThenInsertsThenRefreshes() async throws {
    let (store, _) = try makeStore()
    let ids = try await store.apply(
      AdSignatureStoreChange(insertions: [creative(hashes: [1]), creative(hashes: [2])]))
    let later = Self.t0.addingTimeInterval(100)
    let inserted = try await store.apply(
      AdSignatureStoreChange(
        deletions: [ids[0]], insertions: [creative(hashes: [3])], seen: [ids[0]: later, ids[1]: later]))
    #expect(inserted.count == 1)
    #expect(inserted[0] > ids[1])
    let all = try await store.allCreatives()
    #expect(all.map(\.id) == [ids[1], inserted[0]])
    #expect(all[0].lastSeen == later)
    // The insertion keeps its own lastSeen: only the named ids are refreshed.
    #expect(all[1].lastSeen == Self.t0)
  }

  @Test func insertedIDsFollowInsertionOrder() async throws {
    let (store, _) = try makeStore()
    let ids = try await store.apply(
      AdSignatureStoreChange(insertions: (1...5).map { creative(hashes: [UInt64($0)]) }))
    #expect(ids == ids.sorted())
    #expect(Set(ids).count == 5)
    #expect(try await store.allCreatives().map { $0.hashes.first } == (1...5).map { UInt64($0) })
  }

  @Test func seenChangesOnlyLastSeenOfTheNamedIDs() async throws {
    let (store, _) = try makeStore()
    let ids = try await store.apply(
      AdSignatureStoreChange(insertions: [
        creative(kind: .tombstone, start: 5, end: 6, hashes: [1]), creative(hashes: [2]),
      ]))
    let before = try await store.allCreatives()
    let later = Self.t0.addingTimeInterval(60.5)
    _ = try await store.apply(AdSignatureStoreChange(seen: [ids[0]: later]))
    let after = try await store.allCreatives()
    var expected = before
    expected[0].lastSeen = later
    #expect(after == expected)
  }

  @Test func unknownIDsAreIgnored() async throws {
    let (store, _) = try makeStore()
    let ids = try await store.apply(AdSignatureStoreChange(insertions: [creative()]))
    let before = try await store.allCreatives()
    let inserted = try await store.apply(
      AdSignatureStoreChange(deletions: [999], seen: [998: Self.t0.addingTimeInterval(9)]))
    #expect(inserted.isEmpty)
    #expect(try await store.allCreatives() == before)
    #expect(ids.count == 1)
  }

  @Test func refreshingADeletedIDIsANoOp() async throws {
    let (store, _) = try makeStore()
    let ids = try await store.apply(AdSignatureStoreChange(insertions: [creative()]))
    _ = try await store.apply(
      AdSignatureStoreChange(deletions: [ids[0]], seen: [ids[0]: Self.t0]))
    #expect(try await store.allCreatives().isEmpty)
    #expect(try await store.hashCount() == 0)
  }

  @Test func additionsGiveAnExistingCreativeTeachersAndHashesOnce() async throws {
    let (store, _) = try makeStore()
    let ids = try await store.apply(AdSignatureStoreChange(insertions: [creative(), creative(hashes: [9])]))
    let before = try await store.allCreatives()
    _ = try await store.apply(
      AdSignatureStoreChange(additions: [
        ids[0]: AdSignatureAddition(teachers: ["ep-b", "ep-c"], hashes: [3, 4, UInt64.max])
      ]))
    var expected = before
    expected[0].teachers = ["ep-a", "ep-b", "ep-c"]
    expected[0].hashes = [1, 2, 3, 4, UInt64.max]
    #expect(try await store.allCreatives() == expected)
    #expect(try await store.hashCount() == 6)
  }

  /// `OR IGNORE` does not forgive a foreign key, so an addition tests for its creative itself.
  @Test func anAdditionToACreativeThatIsGoneOrDeletedByTheSameChangeIsANoOp() async throws {
    let (store, database) = try makeStore()
    let ids = try await store.apply(AdSignatureStoreChange(insertions: [creative(), creative(hashes: [9])]))
    let addition = AdSignatureAddition(teachers: ["ep-z"], hashes: [77])
    _ = try await store.apply(
      AdSignatureStoreChange(deletions: [ids[0]], additions: [ids[0]: addition, 999: addition]))
    let stored = try await store.allCreatives()
    #expect(stored.map(\.id) == [ids[1]])
    #expect(stored[0].hashes == [9] && stored[0].teachers == ["ep-a", "ep-b"])
    let teachers = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM adSignatureTeacher") ?? -1
    }
    #expect(teachers == 2)
  }

  @Test func anInsertedCreativeIsThereForAnAdditionInTheSameChange() async throws {
    let (store, _) = try makeStore()
    let ids = try await store.apply(AdSignatureStoreChange(insertions: [creative()]))
    let next = ids[0] + 1
    _ = try await store.apply(
      AdSignatureStoreChange(
        deletions: [ids[0]], insertions: [creative(hashes: [5])],
        additions: [next: AdSignatureAddition(teachers: ["ep-c"], hashes: [6])],
        seen: [next: Self.t0.addingTimeInterval(30)]))
    let stored = try await store.allCreatives()
    #expect(stored.count == 1)
    #expect(stored[0].hashes == [5, 6] && stored[0].teachers == ["ep-a", "ep-b", "ep-c"])
    #expect(stored[0].lastSeen == Self.t0.addingTimeInterval(30))
  }

  @Test func deletingACreativeRemovesItsTeachersAndHashes() async throws {
    let (store, database) = try makeStore()
    let ids = try await store.apply(AdSignatureStoreChange(insertions: [creative()]))
    _ = try await store.apply(AdSignatureStoreChange(deletions: Set(ids)))
    let counts = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM adSignatureTeacher") ?? -1
    }
    #expect(counts == 0)
    #expect(try await store.hashCount() == 0)
  }

  @Test func anEmptyHashInsertionThrowsAndRollsBackTheWholeChange() async throws {
    let (store, _) = try makeStore()
    let ids = try await store.apply(AdSignatureStoreChange(insertions: [creative(hashes: [1])]))
    let before = try await store.allCreatives()
    await #expect(throws: AdSignatureStoreError.self) {
      _ = try await store.apply(
        AdSignatureStoreChange(
          deletions: Set(ids), insertions: [creative(hashes: [7]), creative(hashes: [])],
          seen: [ids[0]: Self.t0.addingTimeInterval(1)]))
    }
    #expect(try await store.allCreatives() == before)
  }

  @Test func deleteAllEmptiesTheStore() async throws {
    let (store, database) = try makeStore()
    _ = try await store.apply(
      AdSignatureStoreChange(insertions: [creative(), creative(hashes: [9])]))
    try await store.deleteAll()
    #expect(try await store.allCreatives().isEmpty)
    #expect(try await store.hashCount() == 0)
    let teachers = try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM adSignatureTeacher") ?? -1
    }
    #expect(teachers == 0)
  }

  @Test func hashCountCountsEveryShingleRow() async throws {
    let (store, _) = try makeStore()
    #expect(try await store.hashCount() == 0)
    // The same hash in two creatives is two rows: the cap counts rows.
    _ = try await store.apply(
      AdSignatureStoreChange(insertions: [creative(hashes: [1, 2, 3]), creative(hashes: [3, 4])]))
    #expect(try await store.hashCount() == 5)
  }

  @Test func aFullCapStoreAppliesAndLoadsInOneGo() async throws {
    let (store, _) = try makeStore()
    let insertions = (0..<2_500).map { index in
      creative(
        teachers: ["e\(index)"],
        hashes: Set((0..<80).map { UInt64(index) &* 80 &+ UInt64($0) &* 0x9E37_79B9_7F4A_7C15 }))
    }
    let ids = try await store.apply(AdSignatureStoreChange(insertions: insertions))
    #expect(ids.count == 2_500)
    #expect(try await store.hashCount() == 200_000)
    let all = try await store.allCreatives()
    #expect(all.count == 2_500)
    #expect(all.allSatisfy { $0.hashes.count == 80 && $0.teachers.count == 1 })
    #expect(all.map(\.hashes) == insertions.map(\.hashes))
  }
}
