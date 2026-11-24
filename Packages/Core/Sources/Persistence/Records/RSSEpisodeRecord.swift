import Foundation
import GRDB

/// One persisted RSS episode. Its identifier is also the parent key for local playback state.
public struct RSSEpisodeRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "rssEpisode"

  public var id: Int64?
  public var feedId: Int64
  public var identityKey: String
  public var alternateIdentityKey: String?
  public var guid: String?
  public var title: String?
  /// The episode's full show notes as feed HTML, for the card: the item's `content:encoded` when
  /// the feed has one, its `description`/`itunes:summary` otherwise. Rows written before the
  /// parser read `content:encoded` hold the description until a refresh rewrites them.
  public var synopsis: String?
  /// The plain-text line the show list draws, derived from `synopsis` at refresh time. `nil` on
  /// rows written before v55, until their next refresh.
  public var synopsisLine: String?
  public var enclosureURL: String
  public var enclosureType: String?
  public var declaredBytes: Int64?
  public var publishedAt: Date?
  public var durationSeconds: Double?
  public var measuredDurationSeconds: Double?
  public var seasonNumber: Int?
  public var episodeNumber: Int?
  public var lastSeenGeneration: Int
  public var retained: Bool
  /// Non-nil means the automatic-download pass or an explicit deletion has decided this episode.
  public var autoDownloadDecidedAt: Date?
  /// The item's own `<itunes:image>`, nil when the feed declares none or declares the show's art.
  /// Rows written before v103 hold nil until the feed's next full fetch.
  public var artworkURL: String?

  public init(
    id: Int64? = nil, feedId: Int64, identityKey: String, alternateIdentityKey: String? = nil,
    guid: String? = nil, title: String? = nil, synopsis: String? = nil,
    synopsisLine: String? = nil, enclosureURL: String,
    enclosureType: String? = nil, declaredBytes: Int64? = nil, publishedAt: Date? = nil,
    durationSeconds: Double? = nil, measuredDurationSeconds: Double? = nil,
    seasonNumber: Int? = nil, episodeNumber: Int? = nil,
    lastSeenGeneration: Int, retained: Bool = false, autoDownloadDecidedAt: Date? = nil,
    artworkURL: String? = nil
  ) {
    self.id = id
    self.feedId = feedId
    self.identityKey = identityKey
    self.alternateIdentityKey = alternateIdentityKey
    self.guid = guid
    self.title = title
    self.synopsis = synopsis
    self.synopsisLine = synopsisLine
    self.enclosureURL = enclosureURL
    self.enclosureType = enclosureType
    self.declaredBytes = declaredBytes
    self.publishedAt = publishedAt
    self.durationSeconds = durationSeconds
    self.measuredDurationSeconds = measuredDurationSeconds
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.lastSeenGeneration = lastSeenGeneration
    self.retained = retained
    self.autoDownloadDecidedAt = autoDownloadDecidedAt
    self.artworkURL = artworkURL
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
