import Foundation
import Persistence
import PodcastFeeds

public protocol FeedPreviewProviding: Sendable {
  func preview(for url: URL) async throws -> FeedPreview
  func preview(for url: URL, credential: PodcastFeedCredential?) async throws -> FeedPreview
}

extension FeedPreviewClient: FeedPreviewProviding {}

extension FeedPreviewProviding {
  public func preview(for url: URL, credential: PodcastFeedCredential?) async throws -> FeedPreview {
    try await preview(for: url)
  }
}

/// Maps a parsed preview into the primitive, device-owned subscription store.
public protocol NativeFeedFollowing: Sendable {
  func follow(_ preview: FeedPreview, subscribedAt: Date) async throws -> Int64
  func follow(
    _ preview: FeedPreview, credential: PodcastFeedCredential?, subscribedAt: Date
  ) async throws -> Int64
  /// The credential-free feed URLs already followed on this device.
  func followedFeedURLs() async throws -> [URL]
}

extension NativeFeedFollowing {
  public func follow(
    _ preview: FeedPreview, credential: PodcastFeedCredential?, subscribedAt: Date
  ) async throws -> Int64 {
    try await follow(preview, subscribedAt: subscribedAt)
  }

  public func followedFeedURLs() async throws -> [URL] { [] }
}

public struct NoOpNativeFeedFollowing: NativeFeedFollowing {
  public init() {}

  public func follow(_ preview: FeedPreview, subscribedAt: Date) async throws -> Int64 {
    throw NoOpNativeFeedFollowingUnavailable()
  }
}

private struct NoOpNativeFeedFollowingUnavailable: Error {}

public enum FollowFeedError: Error, Sendable, Equatable {
  case alreadyFollowing(existingFeedId: Int64)
}

public struct RSSFeedFollowing: NativeFeedFollowing {
  private let store: RSSFeedStore
  private let credentialStore: (any PodcastFeedCredentialStoring)?

  public init(
    store: RSSFeedStore, credentialStore: (any PodcastFeedCredentialStoring)? = nil
  ) {
    self.store = store
    self.credentialStore = credentialStore
  }

  public func follow(_ preview: FeedPreview, subscribedAt: Date) async throws -> Int64 {
    try await follow(preview, credential: nil, subscribedAt: subscribedAt)
  }

  public func follow(
    _ preview: FeedPreview, credential: PodcastFeedCredential?, subscribedAt: Date
  ) async throws -> Int64 {
    do {
      let feedID = try await store.subscribe(
        feedURL: preview.feedURL, title: preview.title, author: preview.author,
        synopsis: preview.synopsis, artworkURL: preview.artworkURL, subscribedAt: subscribedAt,
        recoveryReason: credential == nil ? nil : .credentialStorageFailed)
      guard let credential else { return feedID }

      try Task.checkCancellation()
      guard let credentialStore else { throw FeedCredentialPersistenceUnavailable() }
      try credentialStore.save(credential, forFeedID: feedID)
      try Task.checkCancellation()
      try await store.clearRecovery(feedId: feedID)
      return feedID
    } catch let error as RSSFeedStoreError {
      if case .duplicateFeed(let existingFeedId) = error {
        throw FollowFeedError.alreadyFollowing(existingFeedId: existingFeedId)
      }
      throw error
    }
  }

  public func followedFeedURLs() async throws -> [URL] {
    try await store.fetchFeeds().compactMap { URL(string: $0.feedURL) }
  }
}

private struct FeedCredentialPersistenceUnavailable: Error {}
