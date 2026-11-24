import Foundation
import GRDB
import Testing

@testable import Persistence

/// `AdSkipEpisodeStore`: one transaction per save, ranges that go with their episode, and
/// deletion that reports the transcript files to remove.
@Suite struct AdSkipEpisodeStoreTests {

  // MARK: - Fixtures

  private func record(
    source: AdSkipEpisodeSource = .rss, accountId: Int64? = nil, itemID: String = "rss:1",
    episodeID: String = "guid-1", transcriptFileName: String? = nil, fileByteSize: Int64 = 1_000
  ) -> AdSkipEpisodeRecord {
    AdSkipEpisodeRecord(
      source: source, accountId: accountId, itemID: itemID, episodeID: episodeID,
      fileByteSize: fileByteSize, fileModificationTime: 1_700_000_000.123_456,
      transcriberRevision: "t1", rulesRevision: 1, state: .analysed,
      transcriptFileName: transcriptFileName,
      analysedAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  private func range(_ start: Double, _ end: Double, endsItem: Bool = false) -> AdSkipRange {
    AdSkipRange(
      startTime: start, endTime: end, meanAdProbability: 0.9, rulesRevision: 1, fromStore: false,
      endsItem: endsItem)
  }

  // MARK: - Stage-1 plans

  @Test func aStageOnePlanRoundTripsExactlyForItsLibraryOnly() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    let id = try #require(try await store.save(record(), ranges: []).record.id)
    let plan = StoredStageOnePlan(
      windows: [
        StoredTimeSpan(start: 0.1 + 0.2, end: 45.123_456_789), StoredTimeSpan(start: 1e-300, end: 3_600),
      ],
      audioEdges: [StoredTimeSpan(start: 1200.603_8, end: 1231.152_4)],
      crossShow: [
        StoredCrossShowAlignment(start: 1200.603_8, end: 1231.152_4, episodeKey: "rss\u{1F}x\u{1F}é"),
        StoredCrossShowAlignment(start: 2, end: 30, episodeKey: ""),
      ],
      sameShowEdges: [StoredTimeSpan(start: 3_062.5, end: 3_068.4)])

    try await store.saveStageOnePlan(plan, forEpisodeId: id, libraryKey: "one")
    #expect(try await store.stageOnePlan(forEpisodeId: id, libraryKey: "one") == plan)
    #expect(try await store.stageOnePlan(forEpisodeId: id, libraryKey: "two") == nil)

    let empty = StoredStageOnePlan(windows: [], audioEdges: [])
    try await store.saveStageOnePlan(empty, forEpisodeId: id, libraryKey: "two")
    #expect(try await store.stageOnePlan(forEpisodeId: id, libraryKey: "two") == empty)
    #expect(try await store.stageOnePlan(forEpisodeId: id, libraryKey: "one") == nil)
  }

  @Test func aStageOnePlanForAMissingEpisodeIsIgnored() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    try await store.saveStageOnePlan(
      StoredStageOnePlan(windows: [], audioEdges: []), forEpisodeId: 42, libraryKey: "k")
    #expect(try await store.stageOnePlan(forEpisodeId: 42, libraryKey: "k") == nil)
  }

  @Test func aStageOnePlanThatIsNotWholePairsReadsAsMissing() async throws {
    let database = try AppDatabase.inMemory()
    let store = AdSkipEpisodeStore(database: database)
    let id = try #require(try await store.save(record(), ranges: []).record.id)
    try await database.writeAsync { db in
      try db.execute(
        sql: "INSERT INTO adSkipStageOnePlan (episodeId, libraryKey, windows) VALUES (?, 'k', ?)",
        arguments: [id, Data(repeating: 1, count: 12)])
    }
    #expect(try await store.stageOnePlan(forEpisodeId: id, libraryKey: "k") == nil)
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE adSkipStageOnePlan SET windows = ?, audioEdges = ? WHERE episodeId = ?",
        arguments: [Data(), Data(repeating: 1, count: 12), id])
    }
    #expect(try await store.stageOnePlan(forEpisodeId: id, libraryKey: "k") == nil)
    // A cross-show alignment whose key runs past the blob's end.
    let truncated = AdSkipEpisodeStore.data(
      encoding: [StoredCrossShowAlignment(start: 1, end: 20, episodeKey: "key")]
    ).dropLast()
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE adSkipStageOnePlan SET audioEdges = ?, crossShowAlignments = ? WHERE episodeId = ?
          """,
        arguments: [Data(), Data(truncated), id])
    }
    #expect(try await store.stageOnePlan(forEpisodeId: id, libraryKey: "k") == nil)
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE adSkipStageOnePlan SET crossShowAlignments = ?, sameShowEdges = ? WHERE episodeId = ?
          """,
        arguments: [Data(), Data(repeating: 1, count: 12), id])
    }
    #expect(try await store.stageOnePlan(forEpisodeId: id, libraryKey: "k") == nil)
  }

  // MARK: - Save and read

  @Test func aStoreRangeKeepsItsCreative() async throws {
    let database = try AppDatabase.inMemory()
    let store = AdSkipEpisodeStore(database: database)
    let creative = try await AdSignatureStore(database: database).apply(
      AdSignatureStoreChange(insertions: [
        NewAdSignatureCreative(
          kind: .learned, lastSeen: Date(timeIntervalSince1970: 1_700_000_000), startTime: 1,
          endTime: 31, teachers: [], hashes: [7])
      ]))[0]
    let matched = AdSkipRange(
      startTime: 5, endTime: 35, meanAdProbability: 0.9, rulesRevision: 1, fromStore: true,
      endsItem: false, creativeId: creative)
    let saved = try await store.save(record(), ranges: [matched, range(100, 130)])
    let ranges = try await store.ranges(forEpisodeId: try #require(saved.record.id))
    #expect(ranges == [matched, range(100, 130)])
  }

  @Test func aTailRangeKeepsItsMark() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    let tail = AdSkipRange(
      startTime: 3_067.36, endTime: 3_099.14, meanAdProbability: 0.92, rulesRevision: 13,
      fromStore: false, endsItem: true, fromTail: true)
    let saved = try await store.save(record(), ranges: [range(100, 130), tail])
    let ranges = try await store.ranges(forEpisodeId: try #require(saved.record.id))
    #expect(ranges == [range(100, 130), tail])
    #expect(ranges.map(\.fromTail) == [false, true])
  }

  @Test func hostReadRangesAreReplacedOnTheirOwn() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    func hostRead(_ start: Double, _ end: Double) -> AdSkipRange {
      AdSkipRange(
        startTime: start, endTime: end, meanAdProbability: 0.4, rulesRevision: 14, fromStore: false,
        endsItem: false, fromHostRead: true)
    }
    let saved = try await store.save(record(), ranges: [range(100, 130), hostRead(300, 340)])
    let id = try #require(saved.record.id)
    #expect(try await store.ranges(forEpisodeId: id) == [range(100, 130), hostRead(300, 340)])

    // The mark is the store's to set: a range passed unmarked is still a host read.
    var unmarked = hostRead(500, 520)
    unmarked.fromHostRead = false
    try await store.replaceHostReadRanges([unmarked, hostRead(700, 730)], episodeId: id)
    #expect(
      try await store.ranges(forEpisodeId: id) == [range(100, 130), hostRead(500, 520), hostRead(700, 730)])

    try await store.replaceHostReadRanges([], episodeId: id)
    #expect(try await store.ranges(forEpisodeId: id) == [range(100, 130)])

    // An episode deleted meanwhile takes nothing.
    try await store.replaceHostReadRanges([hostRead(1, 2)], episodeId: id + 1)
    #expect(try await store.ranges(forEpisodeId: id + 1).isEmpty)
  }

  // MARK: - Listener marks

  private func listenerRange(_ start: Double, _ end: Double) -> AdSkipRange {
    AdSkipRange(
      startTime: start, endTime: end, meanAdProbability: 1, rulesRevision: 14, fromStore: false,
      endsItem: false, fromListener: true)
  }

  @Test func aMarkIsStoredWithItsRangesInOneWriteAndTheClosureSeesBoth() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    let id = try #require(try await store.save(record(), ranges: [range(100, 130)]).record.id)
    let now = Date(timeIntervalSince1970: 1_700_000_500)
    let listener = listenerRange(200, 240)

    let stored = try await store.addListenerMark(
      episodeId: id, startTime: 200, endTime: 240, creativeId: nil, createdAt: now,
      ranges: { marks, ranges in
        #expect(marks.map(\.startTime) == [200])
        #expect(ranges == [range(100, 130)])
        return ranges + [listener]
      })
    #expect(stored)
    #expect(try await store.ranges(forEpisodeId: id) == [range(100, 130), listener])
    let marks = try await store.listenerMarks(forEpisodeId: id)
    #expect(marks.map(\.endTime) == [240])
    #expect(marks.first?.createdAt == now)
  }

  @Test func aMarkWithAStoredSpanIsNotStoredTwice() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    let id = try #require(try await store.save(record(), ranges: []).record.id)
    for _ in 0..<2 {
      _ = try await store.addListenerMark(
        episodeId: id, startTime: 200, endTime: 240, creativeId: nil,
        createdAt: Date(timeIntervalSince1970: 0), ranges: { _, ranges in ranges })
    }
    #expect(try await store.listenerMarks(forEpisodeId: id).count == 1)
  }

  @Test func aMarkForAnEpisodeThatIsGoneWritesNothing() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    let stored = try await store.addListenerMark(
      episodeId: 99, startTime: 200, endTime: 240, creativeId: nil,
      createdAt: Date(timeIntervalSince1970: 0), ranges: { _, ranges in ranges })
    #expect(stored == false)
    #expect(try await store.listenerMarks(forEpisodeId: 99).isEmpty)
  }

  @Test func aNewMarkIsAtTheCurrentTeachingRevision() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    let id = try #require(try await store.save(record(), ranges: []).record.id)
    _ = try await store.addListenerMark(
      episodeId: id, startTime: 200, endTime: 240, creativeId: nil,
      createdAt: Date(timeIntervalSince1970: 0), ranges: { _, ranges in ranges })
    #expect(
      try await store.listenerMarks(forEpisodeId: id).map(\.teachingRevision)
        == [AdSkipListenerMark.teachingRevision])
    #expect(try await store.marksAwaitingTeaching().isEmpty)
  }

  /// A mark that taught nothing under an earlier floor is taught once more, then raised.
  @Test func aMarkBelowTheTeachingRevisionAwaitsTeachingUntilRaised() async throws {
    let database = try AppDatabase.inMemory()
    let store = AdSkipEpisodeStore(database: database)
    let id = try #require(try await store.save(record(), ranges: []).record.id)
    let creative = try #require(
      try await AdSignatureStore(database: database).apply(
        AdSignatureStoreChange(insertions: [
          NewAdSignatureCreative(
            kind: .learned, lastSeen: Date(timeIntervalSince1970: 0), startTime: 3, endTime: 17,
            teachers: [], hashes: [1], confirmed: true)
        ])
      ).first)
    for (start, end) in [(3.0, 17.0), (400.0, 410.0)] {
      _ = try await store.addListenerMark(
        episodeId: id, startTime: start, endTime: end, creativeId: nil,
        createdAt: Date(timeIntervalSince1970: 0), ranges: { _, ranges in ranges })
    }
    try database.write { db in
      try db.execute(sql: "UPDATE adSkipListenerMark SET teachingRevision = 1")
    }
    let awaiting = try await store.marksAwaitingTeaching()
    #expect(awaiting.map(\.episodeId) == [id, id])
    #expect(awaiting.map(\.mark.startTime) == [3, 400])

    #expect(try await store.markTaught(id: awaiting[0].mark.id, creativeId: creative))
    #expect(try await store.markTaught(id: awaiting[1].mark.id, creativeId: nil))
    #expect(try await store.marksAwaitingTeaching().isEmpty)
    #expect(try await store.listenerMarks(forEpisodeId: id).map(\.creativeId) == [creative, nil])
    #expect(try await store.markTaught(id: 9_999, creativeId: nil) == false)
  }

  @Test func anEpisodeSuppressesConfirmedCreativesOnceEach() async throws {
    let database = try AppDatabase.inMemory()
    let store = AdSkipEpisodeStore(database: database)
    let id = try #require(try await store.save(record(), ranges: []).record.id)
    let other = try #require(try await store.save(record(episodeID: "guid-2"), ranges: []).record.id)
    let creatives = try await AdSignatureStore(database: database).apply(
      AdSignatureStoreChange(
        insertions: (0..<2).map { _ in
          NewAdSignatureCreative(
            kind: .learned, lastSeen: Date(timeIntervalSince1970: 0), startTime: 3, endTime: 17,
            teachers: [], hashes: [1], confirmed: true)
        }))
    let now = Date(timeIntervalSince1970: 0)
    #expect(try await store.suppressConfirmed(episodeId: id, creativeIds: Set(creatives), createdAt: now))
    #expect(try await store.suppressConfirmed(episodeId: id, creativeIds: [creatives[0]], createdAt: now) == false)
    #expect(try await store.suppressConfirmed(episodeId: id, creativeIds: [], createdAt: now) == false)
    // An unknown creative or episode writes nothing.
    #expect(try await store.suppressConfirmed(episodeId: id, creativeIds: [9_999], createdAt: now) == false)
    #expect(try await store.suppressConfirmed(episodeId: 9_999, creativeIds: [creatives[0]], createdAt: now) == false)
    #expect(try await store.confirmedSuppressions(forEpisodeId: id) == Set(creatives))
    #expect(try await store.confirmedSuppressions(forEpisodeId: other).isEmpty)
  }

  @Test func removingMarksDeletesTheirRangesAndLeavesTheRest() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    let id = try #require(
      try await store.save(
        record(), ranges: [range(100, 130), listenerRange(200, 240), listenerRange(400, 440)]
      ).record.id)
    for (start, end) in [(200.0, 240.0), (400.0, 440.0)] {
      _ = try await store.addListenerMark(
        episodeId: id, startTime: start, endTime: end, creativeId: nil,
        createdAt: Date(timeIntervalSince1970: 0), ranges: { _, ranges in ranges })
    }

    let removed = try await store.removeListenerMarks(episodeId: id, overlapping: 210, 220)
    #expect(removed.map(\.startTime) == [200])
    #expect(
      try await store.ranges(forEpisodeId: id) == [range(100, 130), listenerRange(400, 440)])
    #expect(try await store.listenerMarks(forEpisodeId: id).map(\.startTime) == [400])
    #expect(try await store.removeListenerMarks(episodeId: id, overlapping: 0, 1).isEmpty)
  }

  /// Undo of a detected or host-read ad is not the listener's mark being taken back.
  @Test func deletingRangesLeavesTheListenersOwn() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    let id = try #require(
      try await store.save(record(), ranges: [range(100, 130), listenerRange(110, 150)]).record.id)
    let removed = try await store.deleteRanges(episodeId: id, overlapping: 0, 1_000)
    #expect(removed == [range(100, 130)])
    #expect(try await store.ranges(forEpisodeId: id) == [listenerRange(110, 150)])
  }

  @Test func rangesOfEveryKindOverlappingASpanAreDeletedAndReturned() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    func hostRead(_ start: Double, _ end: Double) -> AdSkipRange {
      AdSkipRange(
        startTime: start, endTime: end, meanAdProbability: 0.4, rulesRevision: 14, fromStore: false,
        endsItem: false, fromHostRead: true)
    }
    let other = try await store.save(
      record(), ranges: [range(100, 130), range(200, 230), hostRead(120, 150), hostRead(300, 340)])
    let id = try #require(other.record.id)

    // Both kinds inside the span go; a range that merely abuts it stays.
    let removed = try await store.deleteRanges(episodeId: id, overlapping: 110, 200)
    #expect(removed == [range(100, 130), hostRead(120, 150)])
    #expect(try await store.ranges(forEpisodeId: id) == [range(200, 230), hostRead(300, 340)])

    #expect(try await store.deleteRanges(episodeId: id, overlapping: 0, 1).isEmpty)
  }

  @Test func saveInsertsAndRoundTrips() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    let input = record(transcriptFileName: "a.words")
    let result = try await store.save(input, ranges: [range(10, 20, endsItem: true)])

    #expect(result.record.id != nil)
    #expect(result.replacedTranscriptFileName == nil)
    var expected = input
    expected.id = result.record.id
    #expect(result.record == expected)
    #expect(try await store.episode(for: input.identity) == expected)
    #expect(
      try await store.ranges(forEpisodeId: try #require(result.record.id)) == [
        range(10, 20, endsItem: true)
      ])
    #expect(try await store.allEpisodes() == [expected])
  }

  @Test func savingAnExistingIdentityReplacesTheRowAndItsRanges() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    let first = try await store.save(
      record(transcriptFileName: "old.words"), ranges: [range(1, 2), range(3, 4)])

    let second = try await store.save(
      record(transcriptFileName: "new.words", fileByteSize: 2_000), ranges: [range(5, 6)])

    #expect(second.replacedTranscriptFileName == "old.words")
    #expect(second.record.id == first.record.id)
    #expect(second.record.fileByteSize == 2_000)
    let all = try await store.allEpisodes()
    #expect(all.count == 1)
    #expect(all.first?.transcriptFileName == "new.words")
    #expect(try await store.ranges(forEpisodeId: try #require(second.record.id)) == [range(5, 6)])
  }

  @Test func savingWithTheSameTranscriptFileNameReportsNoReplacement() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    _ = try await store.save(record(transcriptFileName: "same.words"), ranges: [])
    let again = try await store.save(record(transcriptFileName: "same.words"), ranges: [])
    #expect(again.replacedTranscriptFileName == nil)

    let dropped = try await store.save(record(transcriptFileName: nil), ranges: [])
    #expect(dropped.replacedTranscriptFileName == "same.words")
  }

  @Test func savingReportsAReplacedAudioPrintAndBothReplacedFiles() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    var first = record(transcriptFileName: "a.words")
    first.audioPrintFileName = "a.aprint"
    first.state = .decoded
    _ = try await store.save(first, ranges: [])
    #expect(try await store.episode(for: first.identity)?.state == .decoded)
    #expect(try await store.episode(for: first.identity)?.audioPrintFileName == "a.aprint")

    var same = first
    same.transcriptFileName = "b.words"
    let kept = try await store.save(same, ranges: [])
    #expect(kept.replacedAudioPrintFileName == nil)
    #expect(kept.replacedFileNames == ["a.words"])

    let failed = try await store.save(record(transcriptFileName: nil), ranges: [])
    #expect(failed.replacedFileNames == ["b.words", "a.aprint"])
  }

  @Test func twoRowsCannotNameOneAudioPrint() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    var a = record(episodeID: "a")
    a.audioPrintFileName = "x.aprint"
    var b = record(episodeID: "b")
    b.audioPrintFileName = "x.aprint"
    _ = try await store.save(a, ranges: [])
    await #expect(throws: (any Error).self) { try await store.save(b, ranges: []) }
  }

  @Test func rangesComeBackOrderedByStartTime() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    let saved = try await store.save(record(), ranges: [range(30, 40), range(5, 9), range(15, 20)])
    let ranges = try await store.ranges(forEpisodeId: try #require(saved.record.id))
    #expect(ranges.map(\.startTime) == [5, 15, 30])
  }

  // MARK: - Replace ranges

  @Test func replaceRangesUpdatesSeveralEpisodesAndIgnoresUnknownIDs() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    let one = try #require(
      try await store.save(record(episodeID: "a"), ranges: [range(1, 2)]).record.id)
    let two = try #require(
      try await store.save(record(episodeID: "b"), ranges: [range(3, 4)]).record.id)

    try await store.replaceRanges([
      one: [range(10, 11), range(12, 13)], two: [], 9_999: [range(1, 2)],
    ])

    #expect(try await store.ranges(forEpisodeId: one) == [range(10, 11), range(12, 13)])
    #expect(try await store.ranges(forEpisodeId: two).isEmpty)
    #expect(try await store.ranges(forEpisodeId: 9_999).isEmpty)
    let count = try await store.database.readAsync { db in try AdSkipRangeRecord.fetchCount(db) }
    #expect(count == 2)
  }

  // MARK: - Delete

  @Test func deleteEpisodesReturnsTranscriptNamesAndCascadesRanges() async throws {
    let store = AdSkipEpisodeStore(database: try AppDatabase.inMemory())
    var doomed = record(episodeID: "a", transcriptFileName: "a.words")
    doomed.audioPrintFileName = "a.aprint"
    let withoutFile = record(episodeID: "b", transcriptFileName: nil)
    let kept = record(episodeID: "c", transcriptFileName: "c.words")
    for input in [doomed, withoutFile, kept] {
      _ = try await store.save(input, ranges: [range(1, 2)])
    }

    let names = try await store.deleteEpisodes([
      doomed.identity, withoutFile.identity, record(episodeID: "missing").identity,
    ])

    #expect(names == ["a.words", "a.aprint"])
    #expect(try await store.allEpisodes().map(\.episodeID) == ["c"])
    let count = try await store.database.readAsync { db in try AdSkipRangeRecord.fetchCount(db) }
    #expect(count == 1)
    #expect(try await store.referencedFileNames() == ["c.words"])
  }
}
