import Foundation
import GRDB

public struct NativePodcastSettingsRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "nativePodcastSettings"
  public static let singletonID: Int64 = 1
  public var id: Int64
  public var autoDownloadEnabled: Bool
  public var keepLatestCount: Int
  public var deleteAfterPlayed: Bool
  public var allowCellularAutoDownload: Bool
  public var enabledAt: Date?
  public init(
    id: Int64 = singletonID, autoDownloadEnabled: Bool = false, keepLatestCount: Int = 3,
    deleteAfterPlayed: Bool = false, allowCellularAutoDownload: Bool = false, enabledAt: Date? = nil
  ) {
    self.id = id
    self.autoDownloadEnabled = autoDownloadEnabled
    self.keepLatestCount = keepLatestCount
    self.deleteAfterPlayed = deleteAfterPlayed
    self.allowCellularAutoDownload = allowCellularAutoDownload
    self.enabledAt = enabledAt
  }
  public var settings: PodcastGlobalSettings {
    PodcastGlobalSettings(
      autoDownloadEnabled: autoDownloadEnabled, keepLatestCount: keepLatestCount,
      deleteAfterPlayed: deleteAfterPlayed, allowCellularAutoDownload: allowCellularAutoDownload,
      enabledAt: enabledAt)
  }
}
