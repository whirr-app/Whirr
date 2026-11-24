import Foundation
import GRDB

public enum NativeFeedRecoveryReason: String, Codable, Sendable, Equatable {
  case credentialStorageFailed
}

public struct RSSFeedRecoveryRecord: Codable, Sendable, Equatable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "rssFeedRecovery"

  public let feedId: Int64
  public let reason: NativeFeedRecoveryReason
  public let createdAt: Date

  public init(feedId: Int64, reason: NativeFeedRecoveryReason, createdAt: Date) {
    self.feedId = feedId
    self.reason = reason
    self.createdAt = createdAt
  }
}
