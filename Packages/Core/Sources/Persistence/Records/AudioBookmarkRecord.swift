import Foundation
import GRDB

/// One row of `audioBookmark` (v87): an Audiobookshelf audio bookmark, keyed by
/// `(accountId, serverItemId, time)`. See `AudioBookmarkMigration` for why `time` is exact and why
/// `serverItemId` is not a foreign key.
public struct AudioBookmarkRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "audioBookmark"

  public var accountId: Int64
  public var serverItemId: String
  public var time: Double
  public var title: String
  public var createdAt: Date?

  public init(accountId: Int64, serverItemId: String, time: Double, title: String, createdAt: Date?) {
    self.accountId = accountId
    self.serverItemId = serverItemId
    self.time = time
    self.title = title
    self.createdAt = createdAt
  }
}
