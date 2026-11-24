import Foundation
import GRDB

/// One account's global device-side auto-download defaults. Primary-keyed by `accountId` (at most
/// one row per account), like `PodcastRefreshStateRecord`.
///
/// An absent row means every default applies (auto-download off, keep latest 3, delete-after-
/// played off, no cellular), so no backfill or guarded heal is needed. `enabledAt` is the global
/// activation floor, stamped only by the mutation that flips the effective setting Off to On.
public struct PodcastSettingsRecord: Codable, Equatable, Sendable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "podcastSettings"

  public var accountId: Int64
  public var autoDownloadEnabled: Bool
  public var keepLatestCount: Int
  public var deleteAfterPlayed: Bool
  public var allowCellularAutoDownload: Bool
  public var enabledAt: Date?

  public init(
    accountId: Int64,
    autoDownloadEnabled: Bool = false,
    keepLatestCount: Int = 3,
    deleteAfterPlayed: Bool = false,
    allowCellularAutoDownload: Bool = false,
    enabledAt: Date? = nil
  ) {
    self.accountId = accountId
    self.autoDownloadEnabled = autoDownloadEnabled
    self.keepLatestCount = keepLatestCount
    self.deleteAfterPlayed = deleteAfterPlayed
    self.allowCellularAutoDownload = allowCellularAutoDownload
    self.enabledAt = enabledAt
  }
}
