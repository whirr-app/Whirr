import Foundation
import GRDB

/// Durable holds specific to a device-owned RSS enclosure. This is separate from
/// `DownloadHoldReason`: ABS re-authentication must never release a feed-credential hold.
public enum RSSDownloadHoldReason: String, Codable, Sendable, DatabaseValueConvertible {
  case waitingForWiFi
  case feedCredentials
}

/// One device-owned RSS enclosure transfer. This mirrors the state vocabulary of
/// `DownloadRecord`, but lives in its own table: RSS row ids and ABS row ids are independent
/// sequences and must never be used interchangeably by transfer reconciliation.
public struct RSSDownloadRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "rssDownload"

  public var id: Int64?
  public var episodeId: Int64
  public var state: DownloadState
  public var relativePath: String
  public var expectedBytes: Int64?
  public var actualBytes: Int64
  public var origin: DownloadOrigin
  public var decidedStamp: Date
  public var holdReason: RSSDownloadHoldReason?
  public var errorCode: DownloadErrorCategory?
  /// When this download's file was last parsed for embedded chapters; `nil` until then. Owned by
  /// `RSSEpisodeChapterStore`, which clears it with the chapter rows whenever the file changes.
  public var chaptersExtractedAt: Date?
  /// This download's own measured length; `nil` until the file is first played. Owned by
  /// `RSSDownloadDurationStore`, and cleared with the chapter marker whenever the file changes.
  public var measuredDurationSeconds: Double?
  public var createdAt: Date
  public var updatedAt: Date
  /// The automatic-retry count and deadline, under the same rules as
  /// `DownloadRecord.autoRetryCount` and `autoRetryNotBefore`.
  public var autoRetryCount: Int
  public var autoRetryNotBefore: Date?

  public init(
    id: Int64? = nil, episodeId: Int64, state: DownloadState = .pending,
    relativePath: String, expectedBytes: Int64? = nil, actualBytes: Int64 = 0,
    origin: DownloadOrigin = .manual, decidedStamp: Date, holdReason: RSSDownloadHoldReason? = nil,
    errorCode: DownloadErrorCategory? = nil, chaptersExtractedAt: Date? = nil,
    createdAt: Date, updatedAt: Date, autoRetryCount: Int = 0, autoRetryNotBefore: Date? = nil,
    measuredDurationSeconds: Double? = nil
  ) {
    self.id = id
    self.episodeId = episodeId
    self.state = state
    self.relativePath = relativePath
    self.expectedBytes = expectedBytes
    self.actualBytes = actualBytes
    self.origin = origin
    self.decidedStamp = decidedStamp
    self.holdReason = holdReason
    self.errorCode = errorCode
    self.chaptersExtractedAt = chaptersExtractedAt
    self.measuredDurationSeconds = measuredDurationSeconds
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.autoRetryCount = autoRetryCount
    self.autoRetryNotBefore = autoRetryNotBefore
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }

  public var isPlayable: Bool { state == .completed }
  public var isSchedulable: Bool { state == .pending }
}
