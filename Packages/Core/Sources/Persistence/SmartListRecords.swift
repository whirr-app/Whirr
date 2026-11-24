import Foundation
import GRDB

struct SmartListRecord: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
  static let databaseTableName = "smartList"

  var id: Int64?
  var name: String
  var position: Int
  var showScope: SmartListShowScope
  var includeUnplayed: Bool
  var includeInProgress: Bool
  var includePlayed: Bool
  var includeDownloaded: Bool
  var includeNotDownloaded: Bool
  var savedOnly: Bool
  var publishedWithinHours: SmartListReleaseWindow?
  var durationFilter: Bool
  var longerThanMinutes: Int
  var shorterThanMinutes: Int
  var sortOrder: SmartListSortOrder
  var autoDownload: Bool
  var autoDownloadLimit: SmartListAutoDownloadLimit
  var createdAt: Date
  var updatedAt: Date

  init(
    id: Int64? = nil, name: String, position: Int, rules: SmartListRules, createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.name = name
    self.position = position
    showScope = rules.showScope
    includeUnplayed = rules.includeUnplayed
    includeInProgress = rules.includeInProgress
    includePlayed = rules.includePlayed
    includeDownloaded = rules.includeDownloaded
    includeNotDownloaded = rules.includeNotDownloaded
    savedOnly = rules.savedOnly
    publishedWithinHours = rules.releaseWindow
    durationFilter = rules.durationFilter
    longerThanMinutes = rules.longerThanMinutes
    shorterThanMinutes = rules.shorterThanMinutes
    sortOrder = rules.sortOrder
    autoDownload = rules.autoDownload
    autoDownloadLimit = rules.autoDownloadLimit
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  var rules: SmartListRules {
    SmartListRules(
      showScope: showScope, includeUnplayed: includeUnplayed, includeInProgress: includeInProgress,
      includePlayed: includePlayed, includeDownloaded: includeDownloaded,
      includeNotDownloaded: includeNotDownloaded, savedOnly: savedOnly,
      releaseWindow: publishedWithinHours, durationFilter: durationFilter,
      longerThanMinutes: longerThanMinutes, shorterThanMinutes: shorterThanMinutes,
      sortOrder: sortOrder, autoDownload: autoDownload, autoDownloadLimit: autoDownloadLimit)
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

public enum SmartListShowSource: String, Codable, Sendable {
  case native
  case server
}

public enum SmartListShowRole: String, Codable, Sendable {
  case included
  case excluded
  /// Implies included.
  case priority
}

public struct SmartListShowRecord: Codable, Equatable, Sendable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "smartListShow"

  public var listId: Int64
  public var source: SmartListShowSource
  public var showKey: String
  public var role: SmartListShowRole
  public var titleSnapshot: String

  public init(
    listId: Int64, source: SmartListShowSource, showKey: String, role: SmartListShowRole,
    titleSnapshot: String
  ) {
    self.listId = listId
    self.source = source
    self.showKey = showKey
    self.role = role
    self.titleSnapshot = titleSnapshot
  }
}

public struct SmartListRunRecord: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
  public static let databaseTableName = "smartListRun"

  public var id: Int64 = 1
  public var listId: Int64
  public var anchorItemID: String?
  public var anchorEpisodeID: String?
  public var anchorSortKey: String?
  public var startedAt: Date

  public init(
    listId: Int64, anchorItemID: String? = nil, anchorEpisodeID: String? = nil,
    anchorSortKey: String? = nil, startedAt: Date
  ) {
    self.listId = listId
    self.anchorItemID = anchorItemID
    self.anchorEpisodeID = anchorEpisodeID
    self.anchorSortKey = anchorSortKey
    self.startedAt = startedAt
  }
}

public struct SmartListHiddenEpisodeRecord: Codable, Equatable, Sendable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "smartListHiddenEpisode"

  public var listId: Int64
  public var itemID: String
  public var episodeID: String

  public init(listId: Int64, itemID: String, episodeID: String) {
    self.listId = listId
    self.itemID = itemID
    self.episodeID = episodeID
  }
}

public struct SmartListDownloadClaimRecord: Codable, Equatable, Sendable, FetchableRecord,
  PersistableRecord
{
  public static let databaseTableName = "smartListDownloadClaim"

  public var listId: Int64
  public var itemID: String
  public var episodeID: String
  /// Nil for a native episode, so the claim outlives every account.
  public var accountId: Int64?
  public var claimedAt: Date

  public init(
    listId: Int64, itemID: String, episodeID: String, accountId: Int64?, claimedAt: Date
  ) {
    self.listId = listId
    self.itemID = itemID
    self.episodeID = episodeID
    self.accountId = accountId
    self.claimedAt = claimedAt
  }
}
