import Foundation
import GRDB

/// One cached listening-session-history entry for an item. Populated by `SyncEngine`'s
/// `ListeningHistoryCoordinator` from `GET /api/me/listening-sessions` (closed sessions only, per
/// API-CONVENTIONS.md) and read offline-first by `ItemHistoryModel`. `sessionId` is the server's
/// `ListeningSessionHistoryEntry.id`, stable across refreshes, so it is the upsert identity with
/// `accountId`/`itemId` (the same id could recur across accounts on different servers).
public struct ListeningHistoryEntryRecord: Codable, Equatable, Sendable, FetchableRecord,
  MutablePersistableRecord
{
  public static let databaseTableName = "listeningHistoryEntry"

  public var id: Int64?
  public var accountId: Int64
  public var itemId: Int64
  public var sessionId: String
  public var startedAt: Date
  public var startPosition: Double
  public var endPosition: Double
  public var listenedSeconds: Double

  public init(
    id: Int64? = nil,
    accountId: Int64,
    itemId: Int64,
    sessionId: String,
    startedAt: Date,
    startPosition: Double,
    endPosition: Double,
    listenedSeconds: Double
  ) {
    self.id = id
    self.accountId = accountId
    self.itemId = itemId
    self.sessionId = sessionId
    self.startedAt = startedAt
    self.startPosition = startPosition
    self.endPosition = endPosition
    self.listenedSeconds = listenedSeconds
  }

  public mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}
