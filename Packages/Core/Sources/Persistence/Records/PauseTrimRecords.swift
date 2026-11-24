import Foundation
import GRDB

public enum PauseTrimAnalysisState: String, Codable, Sendable, DatabaseValueConvertible {
  /// Decoded, its pause runs stored, and its file's timeline matches the decode.
  case analysed
  /// Decoded, its pause runs stored, but the player's estimated timeline for the file drifts from
  /// the decode, so it is trimmed through a precise-timing composition. Not retried until the
  /// file's fingerprint or the detector revision changes.
  case misaligned
  /// Analysis gave up on this file (for example, it could not be decoded). Not retried until the
  /// file's fingerprint or the detector revision changes.
  case failed
}

/// One downloaded file's pause analysis. The identity is the ad-skip one, so both coordinators
/// can share the local-episode reader.
public struct PauseTrimEpisodeRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "pauseTrimEpisode"

  public var id: Int64?
  public var source: AdSkipEpisodeSource
  public var accountId: Int64?
  public var itemID: String
  public var episodeID: String
  public var fileByteSize: Int64
  public var fileModificationTime: Double
  public var detectorRevision: Int
  public var state: PauseTrimAnalysisState
  /// `PauseRuns`' encoding. Nil unless `state` is `.analysed`.
  public var runs: Data?
  public var analysedAt: Date

  public init(
    id: Int64? = nil, source: AdSkipEpisodeSource, accountId: Int64?, itemID: String,
    episodeID: String, fileByteSize: Int64, fileModificationTime: Double, detectorRevision: Int,
    state: PauseTrimAnalysisState, runs: Data?, analysedAt: Date
  ) {
    self.id = id
    self.source = source
    self.accountId = accountId
    self.itemID = itemID
    self.episodeID = episodeID
    self.fileByteSize = fileByteSize
    self.fileModificationTime = fileModificationTime
    self.detectorRevision = detectorRevision
    self.state = state
    self.runs = runs
    self.analysedAt = analysedAt
  }

  public var identity: AdSkipEpisodeIdentity {
    AdSkipEpisodeIdentity(source: source, accountId: accountId, itemID: itemID, episodeID: episodeID)
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

/// What reconciling needs to know about a stored analysis, without its runs.
public struct PauseTrimEpisodeSummary: Equatable, Sendable {
  public var identity: AdSkipEpisodeIdentity
  public var fileByteSize: Int64
  public var fileModificationTime: Double
  public var detectorRevision: Int
  public var state: PauseTrimAnalysisState

  public init(
    identity: AdSkipEpisodeIdentity, fileByteSize: Int64, fileModificationTime: Double,
    detectorRevision: Int, state: PauseTrimAnalysisState
  ) {
    self.identity = identity
    self.fileByteSize = fileByteSize
    self.fileModificationTime = fileModificationTime
    self.detectorRevision = detectorRevision
    self.state = state
  }
}
