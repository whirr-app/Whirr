import ABSApi
import Foundation
import Persistence

/// App-facing boundary for an explicit refresh of the currently selected podcast show.
///
/// Account identity is absent: SyncEngine resolves the one persisted account and
/// item scope internally, just as `ItemDetailExtrasService` does.
public protocol PodcastRefreshing: Sendable {
  func refresh(itemID: String) async throws -> PodcastRefreshOutcome
  /// The screen-appear form. A source that records when it last refreshed may answer from its
  /// cache while that is younger than `maximumAge`; a pull-to-refresh uses `refresh(itemID:)`
  /// and is never gated. The default refreshes unconditionally.
  func refreshIfStale(itemID: String, maximumAge: TimeInterval) async throws
    -> PodcastRefreshOutcome
}

extension PodcastRefreshing {
  public func refreshIfStale(itemID: String, maximumAge: TimeInterval) async throws
    -> PodcastRefreshOutcome
  {
    try await refresh(itemID: itemID)
  }
}

public enum PodcastRefreshOutcome: Sendable, Equatable {
  case complete
  case partial
}

public struct NoOpPodcastRefreshing: PodcastRefreshing, Sendable {
  public init() {}
  public func refresh(itemID: String) async throws -> PodcastRefreshOutcome { .complete }
}

/// The local and authenticated scope resolved before an expanded request is issued.
public struct PodcastRefreshContext: Sendable, Equatable {
  public let accountID: Int64
  public let localItemID: Int64
  public let tokenAccount: TokenAccount

  public init(accountID: Int64, localItemID: Int64, tokenAccount: TokenAccount) {
    self.accountID = accountID
    self.localItemID = localItemID
    self.tokenAccount = tokenAccount
  }
}

/// One decoded episode ready for Persistence. The transient stream `contentUrl` is absent;
/// offline identity comes only from the validated stored-audio tuple.
public struct PodcastRefreshEpisode: Sendable, Equatable {
  public let serverEpisodeID: String
  public let title: String?
  public let subtitle: String?
  public let episodeDescription: String?
  public let seasonNumber: String?
  public let episodeNumber: String?
  public let episodeType: String?
  public let mimeType: String?
  public let durationSeconds: Double?
  public let sizeBytes: Int?
  public let publishedAt: Date?
  public let storedAudio: PodcastRefreshEpisodeAudio?
  /// The server's chapter list for this episode, already normalised for storage. Empty is an
  /// authoritative "no chapters", not "unknown".
  public let chapters: [StoredItemChapter]

  public init(
    serverEpisodeID: String,
    title: String?,
    subtitle: String?,
    episodeDescription: String?,
    seasonNumber: String?,
    episodeNumber: String?,
    episodeType: String?,
    mimeType: String?,
    durationSeconds: Double?,
    sizeBytes: Int?,
    publishedAt: Date?,
    storedAudio: PodcastRefreshEpisodeAudio?,
    chapters: [StoredItemChapter] = []
  ) {
    self.serverEpisodeID = serverEpisodeID
    self.title = title
    self.subtitle = subtitle
    self.episodeDescription = episodeDescription
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.episodeType = episodeType
    self.mimeType = mimeType
    self.durationSeconds = durationSeconds
    self.sizeBytes = sizeBytes
    self.publishedAt = publishedAt
    self.storedAudio = storedAudio
    self.chapters = chapters
  }
}

public struct PodcastRefreshEpisodeAudio: Sendable, Equatable {
  public let ino: String
  public let expectedSize: Int
  public let mimeType: String
  public let durationSeconds: Double

  public init(ino: String, expectedSize: Int, mimeType: String, durationSeconds: Double) {
    self.ino = ino
    self.expectedSize = expectedSize
    self.mimeType = mimeType
    self.durationSeconds = durationSeconds
  }
}

/// Fully decoded refresh input. It contains local scope but no Persistence record types, keeping
/// the fetch/coalescing boundary independently testable.
public struct PodcastRefresh: Sendable, Equatable {
  public let accountID: Int64
  public let localItemID: Int64
  public let itemID: String
  public let episodes: [PodcastRefreshEpisode]
  public let progressObservations: [PodcastEpisodeProgressObservation]
  public let autoDownloadEpisodes: Bool?
  public let autoDownloadSchedule: String?
  public let lastEpisodeCheck: Date?
  public let maxEpisodesToKeep: Int?
  public let maxNewEpisodesToDownload: Int?
  /// The show's own synopsis, forwarded with its HTML intact. Stripping it is the presentation
  /// layer's job, not the sync layer's.
  public let showDescription: String?
  public let isComplete: Bool
  public let refreshedAt: Date
  /// Monotonicity token captured just before the request. Persistence rejects a response already
  /// in flight when a newer local save, removal or authoritative refresh checkpoint committed.
  /// `nil` for callers supplying an authoritative snapshot directly (for example, removal
  /// reconciliation).
  public let requestStartedAt: Date?
  /// Whether `progressObservations` came from a complete `/api/me` snapshot that mapped every row
  /// for this show. Only then may an observed episode missing from it be treated as reset.
  public let progressSnapshotIsComplete: Bool

  public init(
    accountID: Int64,
    localItemID: Int64,
    itemID: String,
    episodes: [PodcastRefreshEpisode],
    progressObservations: [PodcastEpisodeProgressObservation],
    autoDownloadEpisodes: Bool?,
    autoDownloadSchedule: String? = nil,
    lastEpisodeCheck: Date?,
    maxEpisodesToKeep: Int? = nil,
    maxNewEpisodesToDownload: Int? = nil,
    showDescription: String? = nil,
    isComplete: Bool,
    refreshedAt: Date = Date(),
    requestStartedAt: Date? = nil,
    progressSnapshotIsComplete: Bool = false
  ) {
    self.accountID = accountID
    self.localItemID = localItemID
    self.itemID = itemID
    self.episodes = episodes
    self.progressObservations = progressObservations
    self.autoDownloadEpisodes = autoDownloadEpisodes
    self.autoDownloadSchedule = autoDownloadSchedule
    self.lastEpisodeCheck = lastEpisodeCheck
    self.maxEpisodesToKeep = maxEpisodesToKeep
    self.maxNewEpisodesToDownload = maxNewEpisodesToDownload
    self.showDescription = showDescription
    self.isComplete = isComplete
    self.refreshedAt = refreshedAt
    self.requestStartedAt = requestStartedAt
    self.progressSnapshotIsComplete = progressSnapshotIsComplete
  }
}

public protocol PodcastRefreshApplying: Sendable {
  func applyPodcastRefresh(
    _ refresh: PodcastRefresh,
    decideProgress: @escaping PodcastProgressMergeDecider
  ) async throws
}

public enum PodcastRefreshError: Error, Sendable, Equatable {
  case accountUnavailable
  case itemUnavailable
  case notPodcast
}
