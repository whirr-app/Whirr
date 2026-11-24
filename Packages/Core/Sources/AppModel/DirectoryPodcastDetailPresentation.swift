import Foundation
import Persistence
import PodcastFeeds

/// What the directory detail page draws. The header comes from the directory result, so it is
/// complete before the feed arrives; only `content` waits on the feed.
public struct DirectoryPodcastDetailDisplay: Sendable, Equatable {
  public enum Content: Sendable, Equatable {
    case loading
    case loaded(description: String?, episodes: [DirectoryEpisodeDisplay])
    case failed(message: String)
  }

  public let feedURL: URL
  public let title: String
  public let author: String?
  /// The directory thumbnail the result row already shows, and so already cached.
  public let artworkURL: URL?
  /// The directory's larger image for the hero, when it supplied one.
  public let largeArtworkURL: URL?
  /// The same image at full-bleed size; the hero falls back to `largeArtworkURL` without it.
  public let heroArtworkURL: URL?
  public let episodeCountText: String?
  public let content: Content

  init(result: PodcastDirectoryResult, phase: AddFeedModel.DirectoryDetailPhase) {
    feedURL = result.feedURL
    title = result.title
    author = result.author
    artworkURL = result.artworkURL
    largeArtworkURL = result.largeArtworkURL
    heroArtworkURL = result.heroArtworkURL

    var episodeCount = result.episodeCount
    switch phase {
    case .loaded(let url, let preview) where url == result.feedURL:
      // The feed's own count is the truth; the directory's can lag.
      episodeCount = preview.episodeCount
      content = .loaded(
        description: FeedHTML.paragraphs(preview.synopsis),
        episodes: preview.recentEpisodes.enumerated().map {
          DirectoryEpisodeDisplay(position: $0.offset, episode: $0.element)
        })
    case .failed(let url, let error) where url == result.feedURL:
      content = .failed(message: AddFeedSheetPresentation.directoryFollowMessage(for: error))
    default:
      content = .loading
    }
    episodeCountText = episodeCount.map(AddFeedSheetPresentation.episodeCountText)
  }
}

public struct DirectoryEpisodeDisplay: Sendable, Equatable, Identifiable {
  /// Position in the preview: feeds repeat titles and may omit GUIDs, so nothing else is unique.
  public let id: Int
  public let title: String
  /// Date and duration, omitting whichever the feed did not state.
  public let metadata: String?
  public let notes: String?

  init(position: Int, episode: FeedPreviewEpisode) {
    id = position
    let trimmedTitle = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    title = trimmedTitle.flatMap { $0.isEmpty ? nil : $0 } ?? PodcastCopy.untitledEpisode
    let parts = [
      episode.publishedAt.map(PodcastCopy.podcastPublishedDate),
      episode.duration.flatMap { $0 > 0 ? PodcastCopy.duration(seconds: $0) : nil },
    ].compactMap { $0 }
    metadata = parts.isEmpty ? nil : parts.joined(separator: " · ")
    notes = FeedHTML.paragraphs(episode.synopsis)
  }
}
