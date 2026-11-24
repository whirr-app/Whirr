import Foundation

/// A recent podcast episode with enough parent-show context for a Home list row. It is a
/// cross-show projection; the underlying episode and item records never leave Persistence.
public struct HomePodcastEpisode: Sendable, Equatable, Identifiable {
  /// Episode ids are only unique within their show, so the parent item is part of the key. A
  /// cross-show list keys its rows by this.
  public var id: String { "\(itemID)/\(episodeID)" }
  public let itemID: String
  public let showTitle: String
  public let showAuthor: String?
  public let episodeID: String
  public let title: String
  public let subtitle: String?
  public let publishedAt: Date
  public let durationSeconds: Double?
  public let progressSeconds: Double
  public let isFinished: Bool
  public let artworkURL: URL?
  public let artworkFeedURL: URL?
  /// The show item's server `updatedAt`: the revision of the show's ABS cover, which every episode
  /// draws (see `ItemSummary`). Nil for RSS episodes.
  public let showServerUpdatedAt: Date?

  public init(
    itemID: String,
    showTitle: String,
    showAuthor: String?,
    episodeID: String,
    title: String,
    subtitle: String?,
    publishedAt: Date,
    durationSeconds: Double?,
    progressSeconds: Double = 0,
    isFinished: Bool = false,
    artworkURL: URL? = nil,
    artworkFeedURL: URL? = nil,
    showServerUpdatedAt: Date? = nil
  ) {
    self.itemID = itemID
    self.showTitle = showTitle
    self.showAuthor = showAuthor
    self.episodeID = episodeID
    self.title = title
    self.subtitle = subtitle
    self.publishedAt = publishedAt
    self.durationSeconds = durationSeconds
    self.progressSeconds = progressSeconds
    self.isFinished = isFinished
    self.artworkURL = artworkURL
    self.artworkFeedURL = artworkFeedURL
    self.showServerUpdatedAt = showServerUpdatedAt
  }
}
