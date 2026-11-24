import Foundation

public enum SmartListShowScope: String, Codable, Sendable, CaseIterable {
  case all
  case allExcept
  case only
}

public enum SmartListSortOrder: String, Codable, Sendable, CaseIterable {
  case newest
  case oldest
  case shortest
  case longest
}

/// "Published within". The raw value is the window in hours, which is what the column stores.
public enum SmartListReleaseWindow: Int, Codable, Sendable, CaseIterable {
  case day = 24
  case threeDays = 72
  case week = 168
  case twoWeeks = 336
  case month = 744
}

public enum SmartListAutoDownloadLimit: Int, Codable, Sendable, CaseIterable {
  case five = 5
  case ten = 10
  case twenty = 20
  case forty = 40
  case hundred = 100
}

public enum SmartListRulesError: Error, Equatable, Sendable {
  case noEpisodeStatus
  case noDownloadStatus
  case invalidDurationRange
}

/// The rule set of one smart list. Rules are joined with AND. `releaseWindow == nil` is "Any time".
/// The duration minutes are meaningful only while `durationFilter` is on, but are always stored.
public struct SmartListRules: Sendable, Codable, Equatable {
  public static let maximumNameLength = 60

  public var showScope: SmartListShowScope
  public var includeUnplayed: Bool
  public var includeInProgress: Bool
  public var includePlayed: Bool
  public var includeDownloaded: Bool
  public var includeNotDownloaded: Bool
  public var savedOnly: Bool
  public var releaseWindow: SmartListReleaseWindow?
  public var durationFilter: Bool
  public var longerThanMinutes: Int
  public var shorterThanMinutes: Int
  public var sortOrder: SmartListSortOrder
  public var autoDownload: Bool
  public var autoDownloadLimit: SmartListAutoDownloadLimit

  public init(
    showScope: SmartListShowScope = .all,
    includeUnplayed: Bool = true,
    includeInProgress: Bool = true,
    includePlayed: Bool = false,
    includeDownloaded: Bool = true,
    includeNotDownloaded: Bool = true,
    savedOnly: Bool = false,
    releaseWindow: SmartListReleaseWindow? = nil,
    durationFilter: Bool = false,
    longerThanMinutes: Int = 20,
    shorterThanMinutes: Int = 40,
    sortOrder: SmartListSortOrder = .newest,
    autoDownload: Bool = false,
    autoDownloadLimit: SmartListAutoDownloadLimit = .ten
  ) {
    self.showScope = showScope
    self.includeUnplayed = includeUnplayed
    self.includeInProgress = includeInProgress
    self.includePlayed = includePlayed
    self.includeDownloaded = includeDownloaded
    self.includeNotDownloaded = includeNotDownloaded
    self.savedOnly = savedOnly
    self.releaseWindow = releaseWindow
    self.durationFilter = durationFilter
    self.longerThanMinutes = longerThanMinutes
    self.shorterThanMinutes = shorterThanMinutes
    self.sortOrder = sortOrder
    self.autoDownload = autoDownload
    self.autoDownloadLimit = autoDownloadLimit
  }

  /// A new list: every show, unplayed and in progress, any download state, newest first.
  public static let `default` = SmartListRules()

  /// Pocket Casts' "New Releases": unplayed and in progress, the last two weeks, newest first.
  public static let newReleases = SmartListRules(releaseWindow: .twoWeeks)

  /// Pocket Casts' "In Progress": only episodes already started, the last month.
  public static let inProgress = SmartListRules(
    includeUnplayed: false, includeInProgress: true, releaseWindow: .month)

  /// Episodes shorter than twenty minutes.
  public static let shortEpisodes = SmartListRules(
    durationFilter: true, longerThanMinutes: 0, shorterThanMinutes: 20)

  /// Everything on the device, played or not yet played.
  public static let downloaded = SmartListRules(includeNotDownloaded: false)

  /// Throws the first rule the store would otherwise have to refuse at a database CHECK.
  public func validate() throws {
    guard includeUnplayed || includeInProgress || includePlayed else {
      throw SmartListRulesError.noEpisodeStatus
    }
    guard includeDownloaded || includeNotDownloaded else {
      throw SmartListRulesError.noDownloadStatus
    }
    if durationFilter {
      guard longerThanMinutes >= 0, shorterThanMinutes >= 1, longerThanMinutes < shorterThanMinutes
      else { throw SmartListRulesError.invalidDurationRange }
    }
  }

  /// The trimmed name, or nil when it is empty or longer than `maximumNameLength` characters.
  public static func normalizedName(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...maximumNameLength).contains(trimmed.count) else { return nil }
    return trimmed
  }
}
