import Foundation
import GRDB

/// A per-show tri-state override of the account's global `PodcastSettingsRecord`. `inherit` is the
/// default ("use the global value"); a two-state toggle would pin every show on first render.
///
/// Unknown stored strings fail closed to `disabled` without hiding the show. That is a query-time
/// concern for the store that resolves effective settings, not this record.
public enum PodcastShowAutoDownloadOverride: String, Codable, Sendable, DatabaseValueConvertible {
  case inherit
  case enabled
  case disabled
}

/// One show's settings override row. Primary-keyed by `itemId` (at most one row per show), with
/// `accountId` alongside for the `(accountId, itemId)` unique index and for account-scoped queries
/// that need no join through `item`.
///
/// An absent row means every field inherits the global settings, so no backfill or guarded heal.
/// `enabledAt` is the show activation floor, stamped only when a mutation flips this show's
/// effective setting Off to On.
public struct PodcastShowSettingsRecord: Codable, Equatable, Sendable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "podcastShowSettings"

  public var itemId: Int64
  public var accountId: Int64
  public var autoDownloadOverride: PodcastShowAutoDownloadOverride
  public var keepLatestOverride: Int?
  public var deleteAfterPlayedOverride: Bool?
  public var enabledAt: Date?

  public init(
    itemId: Int64,
    accountId: Int64,
    autoDownloadOverride: PodcastShowAutoDownloadOverride = .inherit,
    keepLatestOverride: Int? = nil,
    deleteAfterPlayedOverride: Bool? = nil,
    enabledAt: Date? = nil
  ) {
    self.itemId = itemId
    self.accountId = accountId
    self.autoDownloadOverride = autoDownloadOverride
    self.keepLatestOverride = keepLatestOverride
    self.deleteAfterPlayedOverride = deleteAfterPlayedOverride
    self.enabledAt = enabledAt
  }
}
