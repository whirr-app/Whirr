import Foundation

extension SmartListEpisode {
  /// The episode as the shared episode card draws it. The list screen reuses Home's card, which
  /// reads a `HomePodcastEpisode`. An episode with no publish date takes the epoch, because that type
  /// has no optional date.
  public var homeEpisode: HomePodcastEpisode {
    HomePodcastEpisode(
      itemID: itemID, showTitle: showTitle, showAuthor: showAuthor, episodeID: episodeID,
      title: title, subtitle: nil, publishedAt: publishedAt ?? Date(timeIntervalSince1970: 0),
      durationSeconds: durationSeconds, progressSeconds: progressSeconds,
      isFinished: isFinished, artworkURL: artworkURL, artworkFeedURL: artworkFeedURL,
      showServerUpdatedAt: showServerUpdatedAt)
  }
}
