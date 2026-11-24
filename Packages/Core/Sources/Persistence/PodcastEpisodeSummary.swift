import Foundation

/// One locally-cached podcast episode for AppModel. The database row, GRDB types, authenticated
/// content URL, and stored-audio file identity stay inside Persistence.
public struct PodcastEpisodeSummary: Sendable, Equatable, Identifiable {
  public let id: String
  public let title: String
  public let subtitle: String?
  public let episodeDescription: String?
  /// A plain-text line for the row, stored at refresh time by sources whose descriptions are
  /// HTML (`rssEpisode.synopsisLine`). The presentation draws it verbatim; `nil` means the row
  /// derives its line from `subtitle`/`episodeDescription` instead.
  public let synopsisLine: String?
  public let seasonNumber: String?
  public let episodeNumber: String?
  public let episodeType: String?
  public let durationSeconds: Double?
  public let sizeBytes: Int?
  public let publishedAt: Date?
  public let progressSeconds: Double
  public let isPlayed: Bool
  public let isFinished: Bool
  public let downloadStatus: ItemDownloadStatus
  /// Whether the download's declared total size is positive and therefore suitable for a
  /// determinate progress indicator. This is presentation metadata, not a transport byte total.
  public let isDownloadSizeKnown: Bool
  public let isAvailableOnServer: Bool

  public init(
    id: String,
    title: String,
    subtitle: String?,
    episodeDescription: String?,
    seasonNumber: String?,
    episodeNumber: String?,
    episodeType: String?,
    durationSeconds: Double?,
    sizeBytes: Int?,
    publishedAt: Date?,
    progressSeconds: Double,
    isPlayed: Bool,
    isFinished: Bool,
    downloadStatus: ItemDownloadStatus,
    isAvailableOnServer: Bool,
    isDownloadSizeKnown: Bool = true,
    synopsisLine: String? = nil
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.episodeDescription = episodeDescription
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.episodeType = episodeType
    self.durationSeconds = durationSeconds
    self.sizeBytes = sizeBytes
    self.publishedAt = publishedAt
    self.progressSeconds = progressSeconds
    self.isPlayed = isPlayed
    self.isFinished = isFinished
    self.downloadStatus = downloadStatus
    self.isDownloadSizeKnown = isDownloadSizeKnown
    self.isAvailableOnServer = isAvailableOnServer
    self.synopsisLine = synopsisLine
  }
}

/// Read-only show settings surfaced as diagnostics, never inferred from absent server values.
public struct PodcastShowDiagnostics: Sendable, Equatable {
  public let autoDownloadEpisodes: Bool?
  public let autoDownloadSchedule: String?
  public let lastEpisodeCheck: Date?
  public let maxEpisodesToKeep: Int?
  public let maxNewEpisodesToDownload: Int?

  public init(
    autoDownloadEpisodes: Bool?, autoDownloadSchedule: String? = nil,
    lastEpisodeCheck: Date?, maxEpisodesToKeep: Int? = nil,
    maxNewEpisodesToDownload: Int? = nil
  ) {
    self.autoDownloadEpisodes = autoDownloadEpisodes
    self.autoDownloadSchedule = autoDownloadSchedule
    self.lastEpisodeCheck = lastEpisodeCheck
    self.maxEpisodesToKeep = maxEpisodesToKeep
    self.maxNewEpisodesToDownload = maxNewEpisodesToDownload
  }
}

/// One episode's full projection (same shape `observeEpisodes` returns, `episodeDescription`
/// included) paired with its show's title and author for the episode card header. Not
/// `ItemSummary`, which carries a whole item's unrelated fields (duration, category, series,
/// `addedAt`, ...) that either do not apply to a per-episode header or would need re-deriving.
public struct PodcastEpisodeContext: Sendable, Equatable {
  public let episode: PodcastEpisodeSummary
  public let showTitle: String
  public let showAuthor: String?
  /// The parent show's declared artwork, carried by RSS's existing feed join so the episode card
  /// can resolve the same credential-aware source as the show and episode-list surfaces.
  public let artworkURL: URL?
  public let artworkFeedURL: URL?
  /// The ABS show's server `updatedAt`, which revisions the cover the card draws. `nil` for RSS.
  public let showServerUpdatedAt: Date?
  /// The RSS episode's own declared artwork; nil for ABS and for episodes that declare none.
  /// `artworkURL` stays the show's.
  public let episodeArtworkURL: URL?

  public init(
    episode: PodcastEpisodeSummary,
    showTitle: String,
    showAuthor: String?,
    artworkURL: URL?,
    artworkFeedURL: URL?,
    showServerUpdatedAt: Date? = nil,
    episodeArtworkURL: URL? = nil
  ) {
    self.episode = episode
    self.showTitle = showTitle
    self.showAuthor = showAuthor
    self.artworkURL = artworkURL
    self.artworkFeedURL = artworkFeedURL
    self.showServerUpdatedAt = showServerUpdatedAt
    self.episodeArtworkURL = episodeArtworkURL
  }
}
