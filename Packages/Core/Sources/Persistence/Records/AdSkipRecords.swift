import Foundation
import GRDB

public enum AdSkipEpisodeSource: String, Codable, Sendable, DatabaseValueConvertible {
  case abs
  case rss
}

public enum AdSkipAnalysisState: String, Codable, Sendable, DatabaseValueConvertible {
  /// Decoded once for its silences and audio print; its first planned windows are not yet all
  /// transcribed. Playback does not use it yet.
  case decoded
  /// Its first planned windows, stage 2 included, are transcribed, even when there were none. A
  /// later arrival can grow its windows without leaving this state.
  case analysed
  /// Analysis gave up on this file (for example, it could not be decoded). Not retried until the
  /// file's fingerprint or the transcriber revision changes.
  case failed
}

/// One analysed downloaded file. The identity mirrors `EpisodeDownloadKey`, plus the account row
/// id for ABS episodes.
public struct AdSkipEpisodeRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "adSkipEpisode"
  static let ranges = hasMany(AdSkipRangeRecord.self, using: ForeignKey(["episodeId"]))

  public var id: Int64?
  public var source: AdSkipEpisodeSource
  public var accountId: Int64?
  public var itemID: String
  public var episodeID: String
  public var fileByteSize: Int64
  public var fileModificationTime: Double
  public var transcriberRevision: String
  public var rulesRevision: Int
  public var state: AdSkipAnalysisState
  public var transcriptFileName: String?
  public var analysedAt: Date
  /// The episode's audio print file, in the transcript root. Nil for an episode analysed before
  /// audio gating and not yet decoded again, and for a failed one.
  public var audioPrintFileName: String?

  public init(
    id: Int64? = nil, source: AdSkipEpisodeSource, accountId: Int64?, itemID: String,
    episodeID: String, fileByteSize: Int64, fileModificationTime: Double,
    transcriberRevision: String, rulesRevision: Int, state: AdSkipAnalysisState,
    transcriptFileName: String?, analysedAt: Date, audioPrintFileName: String? = nil
  ) {
    self.id = id
    self.source = source
    self.accountId = accountId
    self.itemID = itemID
    self.episodeID = episodeID
    self.fileByteSize = fileByteSize
    self.fileModificationTime = fileModificationTime
    self.transcriberRevision = transcriberRevision
    self.rulesRevision = rulesRevision
    self.state = state
    self.transcriptFileName = transcriptFileName
    self.analysedAt = analysedAt
    self.audioPrintFileName = audioPrintFileName
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

/// A range playback skips in its episode's file.
public struct AdSkipRangeRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "adSkipRange"

  public var id: Int64?
  public var episodeId: Int64
  public var startTime: Double
  public var endTime: Double
  public var meanAdProbability: Double
  public var rulesRevision: Int
  /// The range came from a learned creative rather than the library alone.
  public var fromStore: Bool
  /// Skipping it finishes the item.
  public var endsItem: Bool
  /// The learned creative a store range matched; nil for library ranges and once that creative
  /// is deleted.
  public var creativeId: Int64?
  /// The post-roll tail proposer made it, not repetition.
  public var fromTail: Bool
  /// The host-read pass made it, from the listener's transcript.
  public var fromHostRead: Bool
  /// The listener marked it (`AdSkipListenerMarkRecord`).
  public var fromListener: Bool

  public init(
    id: Int64? = nil, episodeId: Int64, startTime: Double, endTime: Double,
    meanAdProbability: Double, rulesRevision: Int, fromStore: Bool, endsItem: Bool,
    creativeId: Int64? = nil, fromTail: Bool = false, fromHostRead: Bool = false,
    fromListener: Bool = false
  ) {
    self.id = id
    self.episodeId = episodeId
    self.startTime = startTime
    self.endTime = endTime
    self.meanAdProbability = meanAdProbability
    self.rulesRevision = rulesRevision
    self.fromStore = fromStore
    self.endsItem = endsItem
    self.creativeId = creativeId
    self.fromTail = fromTail
    self.fromHostRead = fromHostRead
    self.fromListener = fromListener
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

/// A stretch of an episode the listener said is an ad. Served whole as a range with
/// `fromListener`, and kept here so a recompute can lay it over again.
public struct AdSkipListenerMarkRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "adSkipListenerMark"

  public var id: Int64?
  public var episodeId: Int64
  public var startTime: Double
  public var endTime: Double
  /// The confirmed creative the mark taught; nil when it taught none, and once that is deleted.
  public var creativeId: Int64?
  public var createdAt: Date
  /// The teaching rules the mark was last taught under (`AdSkipListenerMark.teachingRevision`).
  public var teachingRevision: Int

  public init(
    id: Int64? = nil, episodeId: Int64, startTime: Double, endTime: Double, creativeId: Int64? = nil,
    createdAt: Date, teachingRevision: Int = AdSkipListenerMark.teachingRevision
  ) {
    self.id = id
    self.episodeId = episodeId
    self.startTime = startTime
    self.endTime = endTime
    self.creativeId = creativeId
    self.createdAt = createdAt
    self.teachingRevision = teachingRevision
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

public enum AdSignatureKind: String, Codable, Sendable, DatabaseValueConvertible {
  case learned
  case tombstone
}

/// A learned ad or an undone range in the signature store.
public struct AdSignatureCreativeRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "adSignatureCreative"

  public var id: Int64?
  public var kind: AdSignatureKind
  public var lastSeen: Date
  public var startTime: Double
  public var endTime: Double
  /// A listener's mark taught it: never expired, merged or replaced by the store's own rules.
  public var confirmed: Bool

  public init(
    id: Int64? = nil, kind: AdSignatureKind, lastSeen: Date, startTime: Double, endTime: Double,
    confirmed: Bool = false
  ) {
    self.id = id
    self.kind = kind
    self.lastSeen = lastSeen
    self.startTime = startTime
    self.endTime = endTime
    self.confirmed = confirmed
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

/// One episode of the group that taught a creative.
public struct AdSignatureTeacherRecord: Codable, Equatable, Sendable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "adSignatureTeacher"

  public var creativeId: Int64
  public var episodeKey: String

  public init(creativeId: Int64, episodeKey: String) {
    self.creativeId = creativeId
    self.episodeKey = episodeKey
  }
}

/// One shingle hash of a creative.
public struct AdSignatureShingleRecord: Equatable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "adSignatureShingle"

  public var creativeId: Int64
  public var hash: UInt64

  public init(creativeId: Int64, hash: UInt64) {
    self.creativeId = creativeId
    self.hash = hash
  }

  public init(row: Row) throws {
    creativeId = row["creativeId"]
    hash = UInt64(bitPattern: row["hash"] as Int64)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["creativeId"] = creativeId
    container["hash"] = Int64(bitPattern: hash)
  }
}
