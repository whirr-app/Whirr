import Foundation
import PodcastFeeds

/// Plain display values keep the App target independent of `PodcastFeeds`.
public struct AddFeedPreviewDisplay: Sendable, Equatable {
  public let title: String
  public let author: String?
  public let artworkURL: URL?
  public let episodeCount: Int

  public init(title: String, author: String?, artworkURL: URL?, episodeCount: Int) {
    self.title = title
    self.author = author
    self.artworkURL = artworkURL
    self.episodeCount = episodeCount
  }
}

public enum AddFeedError: Error, Sendable, Equatable {
  case invalidAddress
  case unreachable
  case notAFeed
  case alreadyFollowing
  case couldNotFollow
}

extension AddFeedError {
  init(feedPreviewError error: FeedPreviewError) {
    switch error {
    case .invalidURL: self = .invalidAddress
    case .unreachable: self = .unreachable
    case .notAFeed: self = .notAFeed
    }
  }
}

public struct DirectoryPodcastDisplay: Sendable, Equatable, Identifiable {
  public var id: URL { feedURL }
  public let feedURL: URL
  public let title: String
  public let author: String?
  public let artworkURL: URL?
  public let episodeCount: Int?

  init(_ result: PodcastDirectoryResult) {
    feedURL = result.feedURL
    title = result.title
    author = result.author
    artworkURL = result.artworkURL
    episodeCount = result.episodeCount
  }
}
