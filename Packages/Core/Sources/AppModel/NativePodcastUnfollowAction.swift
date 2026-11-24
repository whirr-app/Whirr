import Persistence

public enum NativePodcastUnfollowError: Error, Sendable, Equatable {
  case notNativePodcast
  case playbackStopFailed
  case unsubscribeFailed
}

/// The one destructive sequence every native-podcast unfollow entry point uses. Playback is
/// retired before the feed cascade begins, so no screen can leave a now-unreachable RSS item
/// loaded by deleting through `NativeFeedManaging` directly.
public protocol NativePodcastUnfollowing: Sendable {
  func unfollow(itemID: String) async throws
}

public struct NoOpNativePodcastUnfollowing: NativePodcastUnfollowing, Sendable {
  public init() {}

  public func unfollow(itemID: String) async throws {
    throw NativePodcastUnfollowError.unsubscribeFailed
  }
}

public struct NativePodcastUnfollowAction: NativePodcastUnfollowing, Sendable {
  private let feedManaging: any NativeFeedManaging
  private let stopPlayback: @MainActor @Sendable (String) async throws -> Void

  public init(
    feedManaging: any NativeFeedManaging,
    stopPlayback: @escaping @MainActor @Sendable (String) async throws -> Void
  ) {
    self.feedManaging = feedManaging
    self.stopPlayback = stopPlayback
  }

  public func unfollow(itemID: String) async throws {
    guard let feedID = PodcastSourceIdentity(itemId: itemID)?.rssFeedId else {
      throw NativePodcastUnfollowError.notNativePodcast
    }

    do {
      try Task.checkCancellation()
      try await stopPlayback(itemID)
      try Task.checkCancellation()
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw NativePodcastUnfollowError.playbackStopFailed
    }

    do {
      try await feedManaging.unsubscribe(feedId: feedID)
    } catch {
      throw NativePodcastUnfollowError.unsubscribeFailed
    }
  }
}
