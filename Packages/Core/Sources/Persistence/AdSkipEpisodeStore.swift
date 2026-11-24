import Foundation
import GRDB

/// Persistence for the ad-skip episode and range tables. It holds no file I/O: methods that remove
/// rows return the transcript and audio print file names the caller must delete.
public struct AdSkipEpisodeStore: Sendable {
  let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  public func episode(for identity: AdSkipEpisodeIdentity) async throws -> AdSkipEpisodeRecord? {
    try await database.readAsync { db in try Self.fetch(identity, in: db) }
  }

  public func allEpisodes() async throws -> [AdSkipEpisodeRecord] {
    try await database.readAsync { db in
      try AdSkipEpisodeRecord.fetchAll(db, sql: "SELECT * FROM adSkipEpisode ORDER BY id")
    }
  }

  /// Stores `record` and replaces all of its episode's ranges, in one transaction. An existing
  /// row for the same identity is updated in place, so its id (and therefore any range lookup
  /// by id) stays stable; the caller's `record.id` is ignored.
  public func save(
    _ record: AdSkipEpisodeRecord, ranges: [AdSkipRange]
  ) async throws -> AdSkipSaveResult {
    try await database.writeAsync { db in
      var stored = record
      let previous = try Self.fetch(record.identity, in: db)
      if let previous {
        stored.id = previous.id
        try stored.update(db)
      } else {
        stored.id = nil
        try stored.insert(db)
      }
      let episodeId = stored.id ?? db.lastInsertedRowID
      try Self.replaceRanges(ranges, episodeId: episodeId, in: db)
      let replaced = previous?.transcriptFileName
      let replacedPrint = previous?.audioPrintFileName
      return AdSkipSaveResult(
        record: stored,
        replacedTranscriptFileName: replaced == stored.transcriptFileName ? nil : replaced,
        replacedAudioPrintFileName: replacedPrint == stored.audioPrintFileName ? nil : replacedPrint)
    }
  }

  /// Replaces the ranges of several episodes in one transaction. Ids with no episode row are
  /// ignored, since a library recompute can race an episode's deletion.
  public func replaceRanges(_ rangesByEpisodeId: [Int64: [AdSkipRange]]) async throws {
    try await database.writeAsync { db in
      for (episodeId, ranges) in rangesByEpisodeId {
        guard try AdSkipEpisodeRecord.exists(db, key: episodeId) else { continue }
        try Self.replaceRanges(ranges, episodeId: episodeId, in: db)
      }
    }
  }

  /// Replaces only the episode's host-read ranges with `ranges`, which are stored as host reads
  /// whatever their mark says; every other range stays. Nothing is written when the episode row
  /// is gone.
  public func replaceHostReadRanges(_ ranges: [AdSkipRange], episodeId: Int64) async throws {
    try await database.writeAsync { db in
      guard try AdSkipEpisodeRecord.exists(db, key: episodeId) else { return }
      try db.execute(
        sql: "DELETE FROM adSkipRange WHERE episodeId = ? AND fromHostRead", arguments: [episodeId])
      for range in ranges {
        var record = range.record(episodeId: episodeId)
        record.fromHostRead = true
        try record.insert(db)
      }
    }
  }

  /// Deletes the episode's ranges that overlap `start..<end`, and returns what it deleted, in start
  /// order. A range the listener marked is never deleted here: only removing its mark does that.
  /// Nothing else changes.
  public func deleteRanges(
    episodeId: Int64, overlapping start: Double, _ end: Double
  ) async throws -> [AdSkipRange] {
    try await database.writeAsync { db in
      let records = try AdSkipRangeRecord.fetchAll(
        db,
        sql: """
          SELECT * FROM adSkipRange
          WHERE episodeId = ? AND startTime < ? AND ? < endTime AND NOT fromListener
          ORDER BY startTime, id
          """,
        arguments: [episodeId, end, start])
      for record in records {
        guard let id = record.id else { continue }
        try db.execute(sql: "DELETE FROM adSkipRange WHERE id = ?", arguments: [id])
      }
      return records.map(AdSkipRange.init)
    }
  }

  // MARK: - Listener marks

  public func listenerMarks(forEpisodeId episodeId: Int64) async throws -> [AdSkipListenerMark] {
    try await database.readAsync { db in try Self.marks(forEpisodeId: episodeId, in: db) }
  }

  /// Stores a mark and replaces the episode's ranges with what `ranges` returns, in one
  /// transaction. `ranges` is given the episode's marks, the new one included, and its ranges as
  /// stored, and runs inside the write so nothing changes between its reading and its saving. A
  /// mark with the same span as one stored is not stored twice, though the ranges are still laid
  /// again. Returns false, writing nothing, when the episode row is gone.
  public func addListenerMark(
    episodeId: Int64, startTime: Double, endTime: Double, creativeId: Int64?, createdAt: Date,
    ranges: @Sendable ([AdSkipListenerMark], [AdSkipRange]) -> [AdSkipRange]
  ) async throws -> Bool {
    try await database.writeAsync { db in
      guard try AdSkipEpisodeRecord.exists(db, key: episodeId) else { return false }
      let held = try Self.marks(forEpisodeId: episodeId, in: db)
      if held.contains(where: { $0.startTime == startTime && $0.endTime == endTime }) == false {
        var record = AdSkipListenerMarkRecord(
          episodeId: episodeId, startTime: startTime, endTime: endTime, creativeId: creativeId,
          createdAt: createdAt)
        try record.insert(db)
      }
      let marks = try Self.marks(forEpisodeId: episodeId, in: db)
      let stored = try AdSkipRangeRecord.fetchAll(
        db, sql: "SELECT * FROM adSkipRange WHERE episodeId = ? ORDER BY startTime, id",
        arguments: [episodeId]
      ).map(AdSkipRange.init)
      try Self.replaceRanges(ranges(marks, stored), episodeId: episodeId, in: db)
      return true
    }
  }

  /// Deletes the episode's marks that overlap `start..<end` and the ranges served for them, and
  /// returns the marks, in start order. Every other range stays, the pieces a mark cut from it
  /// included: the recompute that follows restores them.
  public func removeListenerMarks(
    episodeId: Int64, overlapping start: Double, _ end: Double
  ) async throws -> [AdSkipListenerMark] {
    try await database.writeAsync { db in
      let marks = try Self.marks(forEpisodeId: episodeId, in: db).filter {
        $0.startTime < end && start < $0.endTime
      }
      for mark in marks {
        try db.execute(sql: "DELETE FROM adSkipListenerMark WHERE id = ?", arguments: [mark.id])
        try db.execute(
          sql: """
            DELETE FROM adSkipRange
            WHERE episodeId = ? AND fromListener AND startTime < ? AND ? < endTime
            """,
          arguments: [episodeId, mark.endTime, mark.startTime])
      }
      return marks
    }
  }

  /// Every mark taught under rules older than `AdSkipListenerMark.teachingRevision`, by episode
  /// row then start.
  public func marksAwaitingTeaching() async throws -> [(episodeId: Int64, mark: AdSkipListenerMark)] {
    try await database.readAsync { db in
      try AdSkipListenerMarkRecord.fetchAll(
        db,
        sql: """
          SELECT * FROM adSkipListenerMark WHERE teachingRevision < ?
          ORDER BY episodeId, startTime, id
          """,
        arguments: [AdSkipListenerMark.teachingRevision]
      ).compactMap { record in AdSkipListenerMark(record).map { (record.episodeId, $0) } }
    }
  }

  /// Raises the mark to the current teaching revision, recording the creative it taught, if any;
  /// a creative it taught before is kept. False when the mark is gone.
  public func markTaught(id: Int64, creativeId: Int64?) async throws -> Bool {
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          UPDATE adSkipListenerMark SET teachingRevision = ?, creativeId = COALESCE(?, creativeId)
          WHERE id = ?
          """,
        arguments: [AdSkipListenerMark.teachingRevision, creativeId, id])
      return db.changesCount > 0
    }
  }

  /// Records that the listener undid these confirmed creatives in the episode, so they are not
  /// matched there again. Returns whether anything was recorded: an unknown episode or creative,
  /// or one already suppressed, records nothing.
  public func suppressConfirmed(
    episodeId: Int64, creativeIds: Set<Int64>, createdAt: Date
  ) async throws -> Bool {
    guard creativeIds.isEmpty == false else { return false }
    return try await database.writeAsync { db in
      var recorded = false
      for creativeId in creativeIds.sorted() {
        try db.execute(
          sql: """
            INSERT OR IGNORE INTO adSkipConfirmedSuppression (episodeId, creativeId, createdAt)
            SELECT ?, ?, ?
            WHERE EXISTS (SELECT 1 FROM adSkipEpisode WHERE id = ?)
              AND EXISTS (SELECT 1 FROM adSignatureCreative WHERE id = ?)
            """,
          arguments: [episodeId, creativeId, createdAt, episodeId, creativeId])
        if db.changesCount > 0 { recorded = true }
      }
      return recorded
    }
  }

  /// The confirmed creatives the episode suppresses.
  public func confirmedSuppressions(forEpisodeId episodeId: Int64) async throws -> Set<Int64> {
    try await database.readAsync { db in
      Set(
        try Int64.fetchAll(
          db, sql: "SELECT creativeId FROM adSkipConfirmedSuppression WHERE episodeId = ?",
          arguments: [episodeId]))
    }
  }

  public func ranges(forEpisodeId episodeId: Int64) async throws -> [AdSkipRange] {
    try await database.readAsync { db in
      try AdSkipRangeRecord.fetchAll(
        db,
        sql: "SELECT * FROM adSkipRange WHERE episodeId = ? ORDER BY startTime, id",
        arguments: [episodeId]
      ).map(AdSkipRange.init)
    }
  }

  /// Deletes the rows (their ranges cascade) and returns their transcript and audio print file
  /// names.
  public func deleteEpisodes(_ identities: [AdSkipEpisodeIdentity]) async throws -> [String] {
    try await database.writeAsync { db in
      var names: [String] = []
      for identity in identities {
        guard let row = try Self.fetch(identity, in: db), let id = row.id else { continue }
        try db.execute(sql: "DELETE FROM adSkipEpisode WHERE id = ?", arguments: [id])
        names.append(contentsOf: row.transcriptFileName)
        names.append(contentsOf: row.audioPrintFileName)
      }
      return names
    }
  }

  /// The episode's stored stage-1 plan when it was planned against `libraryKey`; nil when none
  /// was, or when the stored row cannot be read.
  public func stageOnePlan(
    forEpisodeId episodeId: Int64, libraryKey: String
  ) async throws -> StoredStageOnePlan? {
    try await database.readAsync { db in
      guard
        let row = try Row.fetchOne(
          db,
          sql: """
            SELECT libraryKey, windows, audioEdges, crossShowAlignments, sameShowEdges
            FROM adSkipStageOnePlan WHERE episodeId = ?
            """,
          arguments: [episodeId]),
        row["libraryKey"] as String == libraryKey,
        let windows = Self.windows(decoding: row["windows"] as Data),
        let audioEdges = Self.windows(decoding: row["audioEdges"] as Data),
        let crossShow = Self.crossShow(decoding: row["crossShowAlignments"] as Data),
        let sameShowEdges = Self.windows(decoding: row["sameShowEdges"] as Data)
      else { return nil }
      return StoredStageOnePlan(
        windows: windows, audioEdges: audioEdges, crossShow: crossShow, sameShowEdges: sameShowEdges)
    }
  }

  /// Replaces the episode's stored plan. An id with no episode row is ignored, since a plan can
  /// race the episode's deletion.
  public func saveStageOnePlan(
    _ plan: StoredStageOnePlan, forEpisodeId episodeId: Int64, libraryKey: String
  ) async throws {
    try await database.writeAsync { db in
      guard try AdSkipEpisodeRecord.exists(db, key: episodeId) else { return }
      try db.execute(
        sql: """
          INSERT INTO adSkipStageOnePlan
            (episodeId, libraryKey, windows, audioEdges, crossShowAlignments, sameShowEdges)
          VALUES (?, ?, ?, ?, ?, ?)
          ON CONFLICT(episodeId) DO UPDATE SET libraryKey = excluded.libraryKey,
            windows = excluded.windows, audioEdges = excluded.audioEdges,
            crossShowAlignments = excluded.crossShowAlignments,
            sameShowEdges = excluded.sameShowEdges
          """,
        arguments: [
          episodeId, libraryKey, Self.data(encoding: plan.windows),
          Self.data(encoding: plan.audioEdges), Self.data(encoding: plan.crossShow),
          Self.data(encoding: plan.sameShowEdges),
        ])
    }
  }

  /// Every file a row names, transcripts and audio prints alike: what the file sweep keeps.
  public func referencedFileNames() async throws -> Set<String> {
    try await database.readAsync { db in
      Set(
        try String.fetchAll(
          db,
          sql: """
            SELECT transcriptFileName FROM adSkipEpisode WHERE transcriptFileName IS NOT NULL
            UNION
            SELECT audioPrintFileName FROM adSkipEpisode WHERE audioPrintFileName IS NOT NULL
            """))
    }
  }

  // MARK: - Helpers

  private static func fetch(
    _ identity: AdSkipEpisodeIdentity, in db: Database
  ) throws -> AdSkipEpisodeRecord? {
    // `IFNULL` matches the unique index, which is what lets RSS rows (no account) collide.
    try AdSkipEpisodeRecord.fetchOne(
      db,
      sql: """
        SELECT * FROM adSkipEpisode
        WHERE source = ? AND IFNULL(accountId, 0) = ? AND itemID = ? AND episodeID = ?
        """,
      arguments: [identity.source, identity.accountId ?? 0, identity.itemID, identity.episodeID])
  }

  static func data(encoding windows: [StoredTimeSpan]) -> Data {
    var data = Data(capacity: windows.count * 16)
    for value in windows.flatMap({ [$0.start, $0.end] }) {
      withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }

  /// Nil for a blob that is not whole start-and-end pairs.
  static func windows(decoding data: Data) -> [StoredTimeSpan]? {
    guard data.count % 16 == 0 else { return nil }
    let values = data.withUnsafeBytes { bytes in
      stride(from: 0, to: bytes.count, by: 8).map {
        Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt64.self)))
      }
    }
    return stride(from: 0, to: values.count, by: 2).map {
      StoredTimeSpan(start: values[$0], end: values[$0 + 1])
    }
  }

  /// Each alignment as its start and end, little-endian Float64s, then its key's UTF-8 length as
  /// a little-endian UInt32 and the key.
  static func data(encoding alignments: [StoredCrossShowAlignment]) -> Data {
    var data = Data()
    for alignment in alignments {
      let key = Data(alignment.episodeKey.utf8)
      for value in [alignment.start.bitPattern, alignment.end.bitPattern] {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
      }
      withUnsafeBytes(of: UInt32(key.count).littleEndian) { data.append(contentsOf: $0) }
      data.append(key)
    }
    return data
  }

  /// Nil for a blob that does not decode whole.
  static func crossShow(decoding data: Data) -> [StoredCrossShowAlignment]? {
    let bytes = [UInt8](data)
    func integer(at offset: Int, width: Int) -> UInt64 {
      (0..<width).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
    }
    var result: [StoredCrossShowAlignment] = []
    var offset = 0
    while offset < bytes.count {
      guard bytes.count - offset >= 20 else { return nil }
      let start = Double(bitPattern: integer(at: offset, width: 8))
      let end = Double(bitPattern: integer(at: offset + 8, width: 8))
      let length = Int(integer(at: offset + 16, width: 4))
      offset += 20
      guard bytes.count - offset >= length,
        let key = String(bytes: bytes[offset..<offset + length], encoding: .utf8)
      else { return nil }
      offset += length
      result.append(StoredCrossShowAlignment(start: start, end: end, episodeKey: key))
    }
    return result
  }

  private static func marks(forEpisodeId episodeId: Int64, in db: Database) throws
    -> [AdSkipListenerMark]
  {
    try AdSkipListenerMarkRecord.fetchAll(
      db, sql: "SELECT * FROM adSkipListenerMark WHERE episodeId = ? ORDER BY startTime, id",
      arguments: [episodeId]
    ).compactMap(AdSkipListenerMark.init)
  }

  private static func replaceRanges(
    _ ranges: [AdSkipRange], episodeId: Int64, in db: Database
  ) throws {
    try db.execute(sql: "DELETE FROM adSkipRange WHERE episodeId = ?", arguments: [episodeId])
    for range in ranges {
      var record = range.record(episodeId: episodeId)
      try record.insert(db)
    }
  }
}

extension Array {
  fileprivate mutating func append(contentsOf optional: Element?) {
    if let optional { append(optional) }
  }
}
