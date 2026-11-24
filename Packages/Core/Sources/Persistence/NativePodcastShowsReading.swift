public enum NativePodcastShowSortMode: String, Sendable, Equatable, CaseIterable {
  case alphabetical
  case mostRecent
  case custom
}

/// One effective, already-ordered view of the device-owned shows plus the mode that produced it.
/// The emitted sequence is the durable truth: nothing above Persistence re-sorts it.
public struct NativePodcastShowsSnapshot: Sendable, Equatable {
  public let mode: NativePodcastShowSortMode
  public let shows: [ItemSummary]

  public init(mode: NativePodcastShowSortMode, shows: [ItemSummary]) {
    self.mode = mode
    self.shows = shows
  }
}

/// Device-local reading boundary for the native podcast subscription grid.
public protocol NativePodcastShowsReading: Sendable {
  func observeShows() -> AsyncStream<NativePodcastShowsSnapshot>
  /// One followed feed as the same `ItemSummary` projection used by `observeShows()`. A missing
  /// or unsubscribed feed emits nil, so callers can distinguish a cold route from a loaded show.
  func observeShow(itemId: String) -> AsyncStream<ItemSummary?>
}

public struct NoOpNativePodcastShowsReading: NativePodcastShowsReading, Sendable {
  public init() {}

  public func observeShows() -> AsyncStream<NativePodcastShowsSnapshot> {
    AsyncStream { $0.finish() }
  }

  public func observeShow(itemId: String) -> AsyncStream<ItemSummary?> {
    AsyncStream { continuation in
      continuation.yield(nil)
      continuation.finish()
    }
  }
}
