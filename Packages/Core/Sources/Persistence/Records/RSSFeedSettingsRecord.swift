import Foundation
import GRDB

/// One RSS feed's stored settings overrides. `autoDownload` remains a raw string so readers use
/// `PodcastShowAutoDownloadOverride.parse`; it must never be decoded straight into the enum because
/// unknown stored strings must fail closed to `disabled`, not throw away the row, matching the
/// `podcastShowSettings.autoDownloadOverride` contract documented in `PodcastSettingsValues.swift`.
public struct RSSFeedSettingsRecord: Codable, Equatable, Sendable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "rssFeedSettings"

  public var feedId: Int64
  public var autoDownload: String
  public var keepLatest: Int?
  public var deleteAfterPlayed: Bool?
  public var rateStep: Int?
  public var includeInLatest: Bool
  public var notificationOverride: String

  public init(
    feedId: Int64, autoDownload: String = "inherit", keepLatest: Int? = nil,
    deleteAfterPlayed: Bool? = nil, rateStep: Int? = nil, includeInLatest: Bool = true,
    notificationOverride: String = RSSNotificationOverride.inherit.rawValue
  ) {
    self.feedId = feedId
    self.autoDownload = autoDownload
    self.keepLatest = keepLatest
    self.deleteAfterPlayed = deleteAfterPlayed
    self.rateStep = rateStep
    self.includeInLatest = includeInLatest
    self.notificationOverride = notificationOverride
  }
}
