import Foundation
import GRDB

public enum EpisodeTranscriptState: String, Codable, Sendable, DatabaseValueConvertible {
  /// Some of the file is transcribed; the file names what is covered.
  case partial
  /// The whole file is transcribed.
  case complete
  /// Transcription gave up on this file. No transcript file. Not retried until the file's
  /// fingerprint or the transcriber revision changes.
  case failed
}

/// Which download a transcript was made from: a different file means a different transcript.
public struct EpisodeTranscriptFingerprint: Equatable, Sendable {
  public var fileByteSize: Int64
  public var fileModificationTime: Double

  public init(fileByteSize: Int64, fileModificationTime: Double) {
    self.fileByteSize = fileByteSize
    self.fileModificationTime = fileModificationTime
  }
}

/// One downloaded file's transcript row. The identity is the ad-skip one, so the coordinators can
/// share the local-episode reader.
public struct EpisodeTranscriptRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "episodeTranscript"

  public var id: Int64?
  public var source: AdSkipEpisodeSource
  public var accountId: Int64?
  public var itemID: String
  public var episodeID: String
  public var fileByteSize: Int64
  public var fileModificationTime: Double
  public var transcriberRevision: String
  public var state: EpisodeTranscriptState
  /// The `.words` file on the transcript root. Nil when `state` is `.failed`.
  public var transcriptFileName: String?
  public var updatedAt: Date

  public init(
    id: Int64? = nil, identity: AdSkipEpisodeIdentity, fingerprint: EpisodeTranscriptFingerprint,
    transcriberRevision: String, state: EpisodeTranscriptState, transcriptFileName: String?,
    updatedAt: Date
  ) {
    self.id = id
    self.source = identity.source
    self.accountId = identity.accountId
    self.itemID = identity.itemID
    self.episodeID = identity.episodeID
    self.fileByteSize = fingerprint.fileByteSize
    self.fileModificationTime = fingerprint.fileModificationTime
    self.transcriberRevision = transcriberRevision
    self.state = state
    self.transcriptFileName = transcriptFileName
    self.updatedAt = updatedAt
  }

  public var identity: AdSkipEpisodeIdentity {
    AdSkipEpisodeIdentity(source: source, accountId: accountId, itemID: itemID, episodeID: episodeID)
  }

  public var fingerprint: EpisodeTranscriptFingerprint {
    EpisodeTranscriptFingerprint(
      fileByteSize: fileByteSize, fileModificationTime: fileModificationTime)
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

/// A row with its words read from its file.
public struct EpisodeTranscriptEntry: Equatable, Sendable {
  public var record: EpisodeTranscriptRecord
  public var transcript: StoredTranscript

  public init(record: EpisodeTranscriptRecord, transcript: StoredTranscript) {
    self.record = record
    self.transcript = transcript
  }
}
