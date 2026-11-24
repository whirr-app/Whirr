import Foundation
import GRDB

/// One row per device-owned RSS subscription. The feed has no account ownership by design.
public struct RSSFeedRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "rssFeed"

  public var id: Int64?
  public var feedURL: String
  public var title: String?
  public var author: String?
  public var synopsis: String?
  /// The channel's declared `<language>`, trimmed but otherwise verbatim. Nil when untagged.
  public var language: String?
  public var artworkURL: String?
  public var etag: String?
  public var lastModified: String?
  public var subscribedAt: Date
  public var lastRefreshedAt: Date?
  public var refreshGeneration: Int
  public var customSortIndex: Int?
  /// Opaque identity used to associate this native show with an ABS podcast. It is derived from
  /// `feedURL` at ordinary write boundaries and remains nil for malformed legacy values.
  public var podcastFeedFingerprint: String?

  public init(
    id: Int64? = nil,
    feedURL: String,
    title: String? = nil,
    author: String? = nil,
    synopsis: String? = nil,
    language: String? = nil,
    artworkURL: String? = nil,
    etag: String? = nil,
    lastModified: String? = nil,
    subscribedAt: Date,
    lastRefreshedAt: Date? = nil,
    refreshGeneration: Int = 0,
    customSortIndex: Int? = nil,
    podcastFeedFingerprint: String? = nil
  ) {
    self.id = id
    self.feedURL = feedURL
    self.title = title
    self.author = author
    self.synopsis = synopsis
    self.language = language
    self.artworkURL = artworkURL
    self.etag = etag
    self.lastModified = lastModified
    self.subscribedAt = subscribedAt
    self.lastRefreshedAt = lastRefreshedAt
    self.refreshGeneration = refreshGeneration
    self.customSortIndex = customSortIndex
    self.podcastFeedFingerprint =
      podcastFeedFingerprint ?? PodcastFeedIdentity.fingerprint(feedURL)
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
