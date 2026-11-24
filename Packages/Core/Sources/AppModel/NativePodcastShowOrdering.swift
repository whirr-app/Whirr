import Persistence

public enum NativePodcastShowOrderingError: Error, Equatable, Sendable {
  case invalidShowID(String)
}

public protocol NativePodcastShowOrdering: Sendable {
  func setSortMode(_ mode: NativePodcastShowSortMode) async throws
  func replaceCustomOrder(showIDs: [String]) async throws
  func resetToAlphabetical() async throws
}

public struct NoOpNativePodcastShowOrdering: NativePodcastShowOrdering, Sendable {
  public init() {}
  public func setSortMode(_ mode: NativePodcastShowSortMode) async throws {}
  public func replaceCustomOrder(showIDs: [String]) async throws {}
  public func resetToAlphabetical() async throws {}
}

public struct RSSShowOrdering: NativePodcastShowOrdering, Sendable {
  private let store: RSSFeedStore

  public init(store: RSSFeedStore) { self.store = store }

  public func setSortMode(_ mode: NativePodcastShowSortMode) async throws {
    try await store.setSortMode(mode)
  }

  public func replaceCustomOrder(showIDs: [String]) async throws {
    let feedIds = try showIDs.map { showID in
      guard let feedId = PodcastSourceIdentity(itemId: showID)?.rssFeedId else {
        throw NativePodcastShowOrderingError.invalidShowID(showID)
      }
      return feedId
    }
    try await store.replaceCustomOrder(feedIds: feedIds)
  }

  public func resetToAlphabetical() async throws {
    try await store.resetToAlphabetical()
  }
}
