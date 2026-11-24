import Foundation
import GRDB
import Testing

@testable import Persistence

/// v73's ad-skip tables: device-owned, never account-owned, with
/// deletion cascading only within their own tables.
@Suite struct AdSkipSchemaTests {

  private static let tables = [
    "adSkipEpisode", "adSkipRange", "adSignatureCreative", "adSignatureTeacher",
    "adSignatureShingle", "adSkipStageOnePlan",
    "adSkipListenerMark", "adSkipConfirmedSuppression",
  ]

  private func episode(
    source: AdSkipEpisodeSource = .rss, accountId: Int64? = nil, itemID: String = "rss:1",
    episodeID: String = "guid-1", transcriptFileName: String? = nil
  ) -> AdSkipEpisodeRecord {
    AdSkipEpisodeRecord(
      source: source, accountId: accountId, itemID: itemID, episodeID: episodeID,
      fileByteSize: 1_000, fileModificationTime: 1_700_000_000.123_456,
      transcriberRevision: "t1", rulesRevision: 1, state: .analysed,
      transcriptFileName: transcriptFileName, analysedAt: Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test func theTablesExistAndAreNotAccountOwned() throws {
    let database = try AppDatabase.inMemory()
    let owned = try database.read { db in try AccountRemover.discoverAccountOwnedTables(db) }
    for table in Self.tables {
      #expect(try database.read { db in try db.tableExists(table) }, "\(table)")
      #expect(owned.contains(table) == false, "\(table)")
    }
  }

  @Test func anEpisodeRoundTripsWithAnExactFingerprint() throws {
    let database = try AppDatabase.inMemory()
    let stored = try database.write { db in
      var record = episode(transcriptFileName: "a.words")
      try record.insert(db)
      return record
    }
    let fetched = try database.read { db in try AdSkipEpisodeRecord.fetchOne(db, key: stored.id) }
    #expect(fetched == stored)
    #expect(fetched?.fileModificationTime == 1_700_000_000.123_456)
  }

  @Test func oneRowPerEpisodeIdentity() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      var first = episode()
      try first.insert(db)
      var duplicate = episode()
      #expect(throws: DatabaseError.self) { try duplicate.insert(db) }
    }
  }

  @Test func accountsKeepIdenticalServerIDsApart() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      var first = episode(source: .abs, accountId: 1, itemID: "li_1", episodeID: "ep_1")
      try first.insert(db)
      var second = episode(source: .abs, accountId: 2, itemID: "li_1", episodeID: "ep_1")
      try second.insert(db)
      var duplicate = episode(source: .abs, accountId: 1, itemID: "li_1", episodeID: "ep_1")
      #expect(throws: DatabaseError.self) { try duplicate.insert(db) }
    }
  }

  @Test func onlyABSEpisodesCarryAnAccount() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      var absWithout = episode(source: .abs, accountId: nil, itemID: "li_1")
      #expect(throws: DatabaseError.self) { try absWithout.insert(db) }
      var rssWith = episode(source: .rss, accountId: 1)
      #expect(throws: DatabaseError.self) { try rssWith.insert(db) }
    }
  }

  @Test func transcriptFileNamesAreUnique() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      var first = episode(episodeID: "a", transcriptFileName: "same.words")
      try first.insert(db)
      var second = episode(episodeID: "b", transcriptFileName: "same.words")
      #expect(throws: DatabaseError.self) { try second.insert(db) }
    }
  }

  @Test func deletingAnEpisodeDeletesItsRanges() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      var record = episode()
      try record.insert(db)
      var range = AdSkipRangeRecord(
        episodeId: try #require(record.id), startTime: 10, endTime: 40, meanAdProbability: 0.5,
        rulesRevision: 1, fromStore: false, endsItem: false)
      try range.insert(db)
      _ = try record.delete(db)
      #expect(try AdSkipRangeRecord.fetchCount(db) == 0)
    }
  }

  @Test func deletingAnEpisodeDeletesItsStageOnePlan() async throws {
    let database = try AppDatabase.inMemory()
    let id = try database.write { db in
      var record = episode()
      try record.insert(db)
      return try #require(record.id)
    }
    try await AdSkipEpisodeStore(database: database).saveStageOnePlan(
      StoredStageOnePlan(windows: [StoredTimeSpan(start: 1, end: 2)], audioEdges: []),
      forEpisodeId: id, libraryKey: "k")
    try database.write { db in
      _ = try AdSkipEpisodeRecord.deleteOne(db, key: id)
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM adSkipStageOnePlan") == 0)
    }
  }

  /// v82: a plan stored before it reads with no audio edges, and its
  /// windows are kept. The coordinator's plan revision, not the schema, has it planned again.
  @Test func v82GivesAnEarlierPlanNoAudioEdges() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v81")
    let windows = AdSkipEpisodeStore.data(encoding: [StoredTimeSpan(start: 1, end: 2)])
    try queue.write { db in
      var record = episode()
      try record.insert(db)
      let id = try #require(record.id)
      try db.execute(
        sql: "INSERT INTO adSkipStageOnePlan (episodeId, libraryKey, windows) VALUES (?, 'k', ?)",
        arguments: [id, windows])
    }

    try SchemaV1.migrator().migrate(queue)

    let row = try #require(
      try queue.read { db in
        try Row.fetchOne(db, sql: "SELECT windows, audioEdges FROM adSkipStageOnePlan")
      })
    #expect(row["windows"] as Data == windows)
    #expect(row["audioEdges"] as Data == Data())
  }

  /// v84: a plan stored before it reads with no cross-show alignments. The
  /// rules revision changes every library key, so it is planned again before it is used.
  @Test func v84GivesAnEarlierPlanNoCrossShowAlignments() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v83")
    try queue.write { db in
      var record = episode()
      try record.insert(db)
      let id = try #require(record.id)
      try db.execute(
        sql: "INSERT INTO adSkipStageOnePlan (episodeId, libraryKey, windows) VALUES (?, 'k', X'')",
        arguments: [id])
    }

    try SchemaV1.migrator().migrate(queue)

    let row = try #require(
      try queue.read { db in try Row.fetchOne(db, sql: "SELECT crossShowAlignments FROM adSkipStageOnePlan") })
    #expect(row["crossShowAlignments"] as Data == Data())
  }

  /// v85: a plan stored before it reads with no same-show edges. The
  /// plan revision changes every library key, so it is planned again before it is used.
  @Test func v85GivesAnEarlierPlanNoSameShowEdges() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v84")
    try queue.write { db in
      var record = episode()
      try record.insert(db)
      let id = try #require(record.id)
      try db.execute(
        sql: "INSERT INTO adSkipStageOnePlan (episodeId, libraryKey, windows) VALUES (?, 'k', X'')",
        arguments: [id])
    }

    try SchemaV1.migrator().migrate(queue)

    let row = try #require(
      try queue.read { db in try Row.fetchOne(db, sql: "SELECT sameShowEdges FROM adSkipStageOnePlan") })
    #expect(row["sameShowEdges"] as Data == Data())
  }

  /// v86: every range stored before it was made by repetition.
  @Test func v86MarksEarlierRangesAsNotFromTheTail() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v85")
    try queue.write { db in
      var record = episode()
      try record.insert(db)
      let id = try #require(record.id)
      try db.execute(
        sql: """
          INSERT INTO adSkipRange
            (episodeId, startTime, endTime, meanAdProbability, rulesRevision, fromStore, endsItem)
          VALUES (?, 10, 20, 0.9, 12, 0, 1)
          """,
        arguments: [id])
    }

    try SchemaV1.migrator().migrate(queue)

    let ranges = try queue.read { db in try AdSkipRangeRecord.fetchAll(db) }
    #expect(ranges.map(\.fromTail) == [false])
  }

  /// v98: no range stored before it was made by the host-read pass.
  @Test func v98MarksEarlierRangesAsNotFromAHostRead() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v97")
    try queue.write { db in
      var record = episode()
      try record.insert(db)
      let id = try #require(record.id)
      try db.execute(
        sql: """
          INSERT INTO adSkipRange
            (episodeId, startTime, endTime, meanAdProbability, rulesRevision, fromStore, endsItem, fromTail)
          VALUES (?, 10, 20, 0.9, 13, 0, 1, 1)
          """,
        arguments: [id])
    }

    try SchemaV1.migrator().migrate(queue)

    let ranges = try queue.read { db in try AdSkipRangeRecord.fetchAll(db) }
    #expect(ranges.map(\.fromHostRead) == [false])
    #expect(ranges.map(\.fromTail) == [true])
  }

  /// v99: nothing stored before it came from a listener's mark or was confirmed by one.
  @Test func v99MarksEarlierRangesAndCreativesAsNotTheListeners() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v98")
    try queue.write { db in
      var record = episode()
      try record.insert(db)
      let id = try #require(record.id)
      try db.execute(
        sql: """
          INSERT INTO adSkipRange
            (episodeId, startTime, endTime, meanAdProbability, rulesRevision, fromStore, endsItem)
          VALUES (?, 10, 20, 0.9, 13, 0, 1)
          """,
        arguments: [id])
      try db.execute(
        sql: "INSERT INTO adSignatureCreative (kind, lastSeen, startTime, endTime) VALUES ('learned', 0, 1, 31)")
    }

    try SchemaV1.migrator().migrate(queue)

    let (ranges, creatives) = try queue.read { db in
      (try AdSkipRangeRecord.fetchAll(db), try AdSignatureCreativeRecord.fetchAll(db))
    }
    #expect(ranges.map(\.fromListener) == [false])
    #expect(creatives.map(\.confirmed) == [false])
  }

  /// v102: a mark that taught a creative is at teaching revision 2; one that taught none, 1, so
  /// it is taught once more under the shorter floor.
  @Test func v102RecordsWhichMarksTaught() throws {
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA foreign_keys = ON")
      SchemaV1.registerSearchFunctions(db)
    }
    let queue = try DatabaseQueue(configuration: configuration)
    try SchemaV1.migrator().migrate(queue, upTo: "v101")
    try queue.write { db in
      var record = episode()
      try record.insert(db)
      let id = try #require(record.id)
      try db.execute(
        sql:
          "INSERT INTO adSignatureCreative (kind, lastSeen, startTime, endTime, confirmed) VALUES ('learned', 0, 1, 31, 1)"
      )
      let creative = db.lastInsertedRowID
      try db.execute(
        sql: """
          INSERT INTO adSkipListenerMark (episodeId, startTime, endTime, creativeId, createdAt)
          VALUES (?, 1, 31, ?, 0), (?, 40, 44, NULL, 0)
          """,
        arguments: [id, creative, id])
    }

    try SchemaV1.migrator().migrate(queue)

    let marks = try queue.read { db in
      try AdSkipListenerMarkRecord.fetchAll(db, sql: "SELECT * FROM adSkipListenerMark ORDER BY startTime")
    }
    #expect(marks.map(\.teachingRevision) == [2, 1])
  }

  @Test func aSuppressionGoesWithItsEpisodeOrItsCreative() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      var first = episode()
      try first.insert(db)
      var second = episode(episodeID: "guid-2")
      try second.insert(db)
      var creative = AdSignatureCreativeRecord(
        kind: .learned, lastSeen: Date(timeIntervalSince1970: 1_700_000_000), startTime: 10,
        endTime: 40, confirmed: true)
      try creative.insert(db)
      for episodeId in [first.id, second.id] {
        try db.execute(
          sql: "INSERT INTO adSkipConfirmedSuppression (episodeId, creativeId, createdAt) VALUES (?, ?, 0)",
          arguments: [episodeId, creative.id])
      }
      func count() throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM adSkipConfirmedSuppression") ?? -1
      }
      #expect(try count() == 2)
      _ = try first.delete(db)
      #expect(try count() == 1)
      _ = try creative.delete(db)
      #expect(try count() == 0)
    }
  }

  @Test func deletingAnEpisodeDeletesItsListenerMarks() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      var record = episode()
      try record.insert(db)
      var mark = AdSkipListenerMarkRecord(
        episodeId: try #require(record.id), startTime: 10, endTime: 40,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000))
      try mark.insert(db)
      #expect(try AdSkipListenerMarkRecord.fetchCount(db) == 1)
      _ = try record.delete(db)
      #expect(try AdSkipListenerMarkRecord.fetchCount(db) == 0)
    }
  }

  @Test func deletingACreativeLeavesTheMarkItTaughtWithNoCreative() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      var record = episode()
      try record.insert(db)
      var creative = AdSignatureCreativeRecord(
        kind: .learned, lastSeen: Date(timeIntervalSince1970: 1_700_000_000), startTime: 10,
        endTime: 40, confirmed: true)
      try creative.insert(db)
      var mark = AdSkipListenerMarkRecord(
        episodeId: try #require(record.id), startTime: 10, endTime: 40, creativeId: creative.id,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000))
      try mark.insert(db)
      _ = try creative.delete(db)
      let stored = try #require(try AdSkipListenerMarkRecord.fetchOne(db))
      #expect(stored.creativeId == nil)
    }
  }

  @Test func deletingACreativeDeletesItsTeachersAndShingles() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      var creative = AdSignatureCreativeRecord(
        kind: .learned, lastSeen: Date(timeIntervalSince1970: 1_700_000_000), startTime: 1,
        endTime: 31)
      try creative.insert(db)
      let id = try #require(creative.id)
      try AdSignatureTeacherRecord(creativeId: id, episodeKey: "rss:1/guid-1").insert(db)
      try AdSignatureShingleRecord(creativeId: id, hash: .max).insert(db)
      _ = try creative.delete(db)
      #expect(try AdSignatureTeacherRecord.fetchCount(db) == 0)
      #expect(try AdSignatureShingleRecord.fetchCount(db) == 0)
    }
  }

  @Test func deletingACreativeClearsTheRangesItMatched() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      var record = episode()
      try record.insert(db)
      var creative = AdSignatureCreativeRecord(
        kind: .learned, lastSeen: Date(timeIntervalSince1970: 1_700_000_000), startTime: 1,
        endTime: 31)
      try creative.insert(db)
      var range = AdSkipRangeRecord(
        episodeId: try #require(record.id), startTime: 10, endTime: 40, meanAdProbability: 0.5,
        rulesRevision: 1, fromStore: true, endsItem: false, creativeId: creative.id)
      try range.insert(db)
      _ = try creative.delete(db)
      let stored = try #require(try AdSkipRangeRecord.fetchOne(db))
      #expect(stored.creativeId == nil)
      #expect(stored.fromStore)
    }
  }

  @Test func aShingleHashKeepsAll64Bits() throws {
    let database = try AppDatabase.inMemory()
    try database.write { db in
      var creative = AdSignatureCreativeRecord(
        kind: .tombstone, lastSeen: Date(timeIntervalSince1970: 0), startTime: 0, endTime: 1)
      try creative.insert(db)
      let id = try #require(creative.id)
      for hash: UInt64 in [0, 1, UInt64(Int64.max), UInt64(Int64.max) + 1, .max] {
        try AdSignatureShingleRecord(creativeId: id, hash: hash).insert(db)
      }
      let hashes = try AdSignatureShingleRecord.fetchAll(db).map(\.hash)
      #expect(Set(hashes) == [0, 1, UInt64(Int64.max), UInt64(Int64.max) + 1, .max])
    }
  }

  @Test func removingAnAccountLeavesAdSkipRowsIntact() async throws {
    let database = try AppDatabase.inMemory()
    let accountId = try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "client-adskip", serverBaseURL: "https://example.com", serverUserId: "user",
        serverVersion: "2.35.1")
      try account.insert(db)
      let accountId = try #require(account.id)
      var record = episode(source: .abs, accountId: accountId, itemID: "li_1", episodeID: "ep_1")
      try record.insert(db)
      return accountId
    }

    try AccountRemover(database: database).removeAccount(accountId: accountId)

    #expect(try database.read { db in try AdSkipEpisodeRecord.fetchCount(db) } == 1)
  }
}
