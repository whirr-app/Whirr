import Foundation
import GRDB

/// One row per podcast episode. Identity is `(itemId, serverEpisodeId)`.
public struct PodcastEpisodeRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "podcastEpisode"

  public var id: Int64?
  public var accountId: Int64
  public var itemId: Int64
  public var serverEpisodeId: String
  public var title: String
  public var subtitle: String?
  public var episodeDescription: String?
  public var seasonNumber: String?
  public var episodeNumber: String?
  public var episodeType: String?
  public var mimeType: String?
  public var durationSeconds: Double?
  public var sizeBytes: Int?
  public var publishedAt: Date?
  public var storedAudioIno: String?
  public var storedAudioExpectedSize: Int?
  public var storedAudioMimeType: String?
  public var storedAudioDurationSeconds: Double?
  /// Stamped only when the automatic pass creates a download row for this episode, never by a
  /// manual request. Non-nil means "decided, do not reconsider", which stops a manually deleted
  /// automatic download being re-downloaded when it again satisfies every other candidate
  /// condition.
  public var autoDownloadDecidedAt: Date?
  public var lastSeenGeneration: Int
  public var softDeleted: Bool

  public init(
    id: Int64? = nil,
    accountId: Int64,
    itemId: Int64,
    serverEpisodeId: String,
    title: String,
    subtitle: String? = nil,
    episodeDescription: String? = nil,
    seasonNumber: String? = nil,
    episodeNumber: String? = nil,
    episodeType: String? = nil,
    mimeType: String? = nil,
    durationSeconds: Double? = nil,
    sizeBytes: Int? = nil,
    publishedAt: Date? = nil,
    storedAudioIno: String? = nil,
    storedAudioExpectedSize: Int? = nil,
    storedAudioMimeType: String? = nil,
    storedAudioDurationSeconds: Double? = nil,
    autoDownloadDecidedAt: Date? = nil,
    lastSeenGeneration: Int,
    softDeleted: Bool = false
  ) {
    self.id = id
    self.accountId = accountId
    self.itemId = itemId
    self.serverEpisodeId = serverEpisodeId
    self.title = title
    self.subtitle = subtitle
    self.episodeDescription = episodeDescription
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.episodeType = episodeType
    self.mimeType = mimeType
    self.durationSeconds = durationSeconds
    self.sizeBytes = sizeBytes
    self.publishedAt = publishedAt
    self.storedAudioIno = storedAudioIno
    self.storedAudioExpectedSize = storedAudioExpectedSize
    self.storedAudioMimeType = storedAudioMimeType
    self.storedAudioDurationSeconds = storedAudioDurationSeconds
    self.autoDownloadDecidedAt = autoDownloadDecidedAt
    self.lastSeenGeneration = lastSeenGeneration
    self.softDeleted = softDeleted
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
