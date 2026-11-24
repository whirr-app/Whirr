import Foundation
import GRDB

public struct StoredAdSignatureCreative: Sendable, Equatable {
  public var id: Int64
  public var kind: AdSignatureKind
  public var lastSeen: Date
  public var startTime: Double
  public var endTime: Double
  public var teachers: Set<String>
  public var hashes: Set<UInt64>
  /// Whether the creative keeps an audio print. The print itself is loaded only by
  /// `learnedAudioPrints()`.
  public var hasAudioPrint: Bool
  /// A listener's mark taught it.
  public var confirmed: Bool

  public init(
    id: Int64, kind: AdSignatureKind, lastSeen: Date, startTime: Double, endTime: Double,
    teachers: Set<String>, hashes: Set<UInt64>, hasAudioPrint: Bool = false, confirmed: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.lastSeen = lastSeen
    self.startTime = startTime
    self.endTime = endTime
    self.teachers = teachers
    self.hashes = hashes
    self.hasAudioPrint = hasAudioPrint
    self.confirmed = confirmed
  }
}

/// A learned creative's audio print, for matching.
public struct StoredAdSignatureAudioPrint: Sendable, Equatable {
  public var id: Int64
  public var teachers: Set<String>
  /// Little-endian 32-bit words.
  public var audioPrint: Data
  /// A listener's mark taught it (`NewAdSignatureCreative.confirmed`).
  public var confirmed: Bool

  public init(id: Int64, teachers: Set<String>, audioPrint: Data, confirmed: Bool = false) {
    self.id = id
    self.teachers = teachers
    self.audioPrint = audioPrint
    self.confirmed = confirmed
  }
}

public struct NewAdSignatureCreative: Sendable, Equatable {
  public var kind: AdSignatureKind
  public var lastSeen: Date
  public var startTime: Double
  public var endTime: Double
  public var teachers: Set<String>
  public var hashes: Set<UInt64>
  /// The kept range's audio print, little-endian 32-bit words. Learned creatives only.
  public var audioPrint: Data?
  /// A listener's mark taught it. Learned creatives only.
  public var confirmed: Bool

  public init(
    kind: AdSignatureKind, lastSeen: Date, startTime: Double, endTime: Double,
    teachers: Set<String>, hashes: Set<UInt64>, audioPrint: Data? = nil, confirmed: Bool = false
  ) {
    self.kind = kind
    self.lastSeen = lastSeen
    self.startTime = startTime
    self.endTime = endTime
    self.teachers = teachers
    self.hashes = hashes
    self.audioPrint = audioPrint
    self.confirmed = confirmed
  }
}

/// Teachers and hashes an existing creative gains when a copy of the same ad is merged into it.
public struct AdSignatureAddition: Sendable, Equatable {
  public var teachers: Set<String>
  public var hashes: Set<UInt64>

  public init(teachers: Set<String> = [], hashes: Set<UInt64> = []) {
    self.teachers = teachers
    self.hashes = hashes
  }
}

/// What one policy decision changes in the store, applied as a single transaction.
public struct AdSignatureStoreChange: Sendable, Equatable {
  public var deletions: Set<Int64>
  public var insertions: [NewAdSignatureCreative]
  /// What existing creatives gain, by id. Applied after deletions and insertions; a creative
  /// deleted by the same change, or already gone, gains nothing.
  public var additions: [Int64: AdSignatureAddition]
  /// Creatives a match refreshed, with their new `lastSeen`. Applied after deletions, so an id
  /// deleted by the same change stays gone.
  public var seen: [Int64: Date]

  public init(
    deletions: Set<Int64> = [], insertions: [NewAdSignatureCreative] = [],
    additions: [Int64: AdSignatureAddition] = [:], seen: [Int64: Date] = [:]
  ) {
    self.deletions = deletions
    self.insertions = insertions
    self.additions = additions
    self.seen = seen
  }
}

public enum AdSignatureStoreError: Error, Equatable, Sendable {
  /// A creative without hashes can never match, so it is never stored, unless a listener's mark
  /// confirmed it and it has an audio print, which `ConfirmedReach` matches by.
  case creativeHasNoHashes
}

extension NewAdSignatureCreative {
  /// Whether the store accepts it (`AdSignatureStoreError.creativeHasNoHashes`).
  var canBeStored: Bool {
    hashes.isEmpty == false || (kind == .learned && confirmed && audioPrint?.isEmpty == false)
  }
}

/// The persisted signature store. It holds rows only; expiry, eviction and matching are the
/// policy's, which hands this store the ids to delete and refresh.
public struct AdSignatureStore: Sendable {
  private let database: AppDatabase

  public init(database: AppDatabase) {
    self.database = database
  }

  /// Loads the whole store in three queries, grouped in memory.
  public func allCreatives() async throws -> [StoredAdSignatureCreative] {
    try await database.readAsync { db in
      var teachers: [Int64: Set<String>] = [:]
      let teacherRows = try Row.fetchCursor(
        db, sql: "SELECT creativeId, episodeKey FROM adSignatureTeacher")
      while let row = try teacherRows.next() {
        teachers[row[0] as Int64, default: []].insert(row[1] as String)
      }
      var hashes: [Int64: Set<UInt64>] = [:]
      let shingleRows = try Row.fetchCursor(
        db, sql: "SELECT creativeId, hash FROM adSignatureShingle")
      while let row = try shingleRows.next() {
        hashes[row[0] as Int64, default: []].insert(UInt64(bitPattern: row[1] as Int64))
      }
      // The audio print is left in the database: a recompute loads it once, for matching.
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT id, kind, lastSeen, startTime, endTime, audioPrint IS NOT NULL AS hasAudioPrint,
            confirmed
          FROM adSignatureCreative ORDER BY id
          """)
      return rows.map { row in
        let id: Int64 = row["id"]
        return StoredAdSignatureCreative(
          id: id, kind: row["kind"], lastSeen: row["lastSeen"], startTime: row["startTime"],
          endTime: row["endTime"], teachers: teachers[id] ?? [], hashes: hashes[id] ?? [],
          hasAudioPrint: row["hasAudioPrint"], confirmed: row["confirmed"])
      }
    }
  }

  /// Every learned creative that keeps an audio print, with its teachers.
  public func learnedAudioPrints() async throws -> [StoredAdSignatureAudioPrint] {
    try await database.readAsync { db in
      var teachers: [Int64: Set<String>] = [:]
      let teacherRows = try Row.fetchCursor(
        db, sql: "SELECT creativeId, episodeKey FROM adSignatureTeacher")
      while let row = try teacherRows.next() {
        teachers[row[0] as Int64, default: []].insert(row[1] as String)
      }
      return try Row.fetchAll(
        db,
        sql: """
          SELECT id, audioPrint, confirmed FROM adSignatureCreative
          WHERE kind = 'learned' AND audioPrint IS NOT NULL ORDER BY id
          """
      ).map { row in
        let id: Int64 = row["id"]
        return StoredAdSignatureAudioPrint(
          id: id, teachers: teachers[id] ?? [], audioPrint: row["audioPrint"], confirmed: row["confirmed"])
      }
    }
  }

  /// Applies deletions, then insertions, then additions, then the seen refresh, in one
  /// transaction. Returns the inserted ids in insertion order. Unknown ids are ignored: an
  /// addition carries its own existence test, since `OR IGNORE` forgives a row already there but
  /// not a missing creative. Dates are stored to the millisecond, so a caller holding the store in
  /// memory reloads after applying (sub-millisecond `lastSeen` values would order eviction ties
  /// differently).
  public func apply(_ change: AdSignatureStoreChange) async throws -> [Int64] {
    guard change.insertions.allSatisfy(\.canBeStored) else {
      throw AdSignatureStoreError.creativeHasNoHashes
    }
    return try await database.writeAsync { db in
      let delete = try db.makeStatement(sql: "DELETE FROM adSignatureCreative WHERE id = ?")
      for id in change.deletions { try delete.execute(arguments: [id]) }

      let insertCreative = try db.makeStatement(
        sql: """
          INSERT INTO adSignatureCreative (kind, lastSeen, startTime, endTime, audioPrint, confirmed)
          VALUES (?, ?, ?, ?, ?, ?)
          """)
      let insertTeacher = try db.makeStatement(
        sql: "INSERT INTO adSignatureTeacher (creativeId, episodeKey) VALUES (?, ?)")
      let insertShingle = try db.makeStatement(
        sql: "INSERT INTO adSignatureShingle (creativeId, hash) VALUES (?, ?)")
      var insertedIDs: [Int64] = []
      insertedIDs.reserveCapacity(change.insertions.count)
      for creative in change.insertions {
        try insertCreative.execute(
          arguments: [
            creative.kind, creative.lastSeen, creative.startTime, creative.endTime,
            creative.kind == .learned ? creative.audioPrint : nil,
            creative.kind == .learned && creative.confirmed,
          ])
        let id = db.lastInsertedRowID
        for key in creative.teachers { try insertTeacher.execute(arguments: [id, key]) }
        for hash in creative.hashes {
          try insertShingle.execute(arguments: [id, Int64(bitPattern: hash)])
        }
        insertedIDs.append(id)
      }

      if change.additions.isEmpty == false {
        let exists = "WHERE EXISTS (SELECT 1 FROM adSignatureCreative WHERE id = ?)"
        let addTeacher = try db.makeStatement(
          sql: "INSERT OR IGNORE INTO adSignatureTeacher (creativeId, episodeKey) SELECT ?, ? \(exists)")
        let addShingle = try db.makeStatement(
          sql: "INSERT OR IGNORE INTO adSignatureShingle (creativeId, hash) SELECT ?, ? \(exists)")
        for (id, addition) in change.additions {
          for key in addition.teachers { try addTeacher.execute(arguments: [id, key, id]) }
          for hash in addition.hashes {
            try addShingle.execute(arguments: [id, Int64(bitPattern: hash), id])
          }
        }
      }

      let refresh = try db.makeStatement(
        sql: "UPDATE adSignatureCreative SET lastSeen = ? WHERE id = ?")
      for (id, date) in change.seen { try refresh.execute(arguments: [date, id]) }
      return insertedIDs
    }
  }

  /// Forgets everything learned. Teachers and shingles go with their creatives.
  public func deleteAll() async throws {
    try await database.writeAsync { db in
      _ = try AdSignatureCreativeRecord.deleteAll(db)
    }
  }

  /// Shingle rows across all creatives, which is what the store's size cap counts.
  public func hashCount() async throws -> Int {
    try await database.readAsync { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM adSignatureShingle") ?? 0
    }
  }
}
