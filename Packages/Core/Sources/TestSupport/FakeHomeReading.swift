import Foundation
import Persistence

/// `HomeReading`'s fake. Unlike `FakeLibraryReading`, which broadcasts to every subscriber,
/// `HomeModel` re-subscribes (a new call to each `observe*` method) whenever `filter` changes, so
/// this fake keeps one continuation array per call, in creation order. `push…(at:)` targets a
/// specific subscription (proving a cancelled-but-pending earlier one can't leak a stale value
/// into the model); the no-index overload targets the most recent, the common case.
public final class FakeHomeReading: HomeReading, @unchecked Sendable {
  public init() {}

  private let continueListeningSubs = Locked<[AsyncStream<[HomeItem]>.Continuation]>([])
  private let continueReadingSubs = Locked<[AsyncStream<[HomeItem]>.Continuation]>([])
  private let continueSeriesSubs = Locked<[AsyncStream<[HomeItem]>.Continuation]>([])
  private let recentlyAddedSubs =
    Locked<[AsyncStream<HomeRecentlyAddedSnapshot>.Continuation]>([])
  private let downloadedSubs = Locked<[AsyncStream<[HomeItem]>.Continuation]>([])
  private let newPodcastEpisodeSubs =
    Locked<[AsyncStream<HomeLatestPodcastEpisodesSnapshot>.Continuation]>([])

  public typealias Call = (category: ItemMediaCategory?, limit: Int)
  public typealias RecentCall = (category: ItemMediaCategory?, limit: Int, since: Date?)
  public typealias EpisodeCall = (since: Date, limit: Int)
  private let continueListeningCallsBox = Locked<[Call]>([])
  private let continueReadingCallsBox = Locked<[Call]>([])
  private let continueSeriesCallsBox = Locked<[Call]>([])
  private let recentlyAddedCallsBox = Locked<[Call]>([])
  private let recentlyAddedSinceCallsBox = Locked<[RecentCall]>([])
  private let downloadedCallsBox = Locked<[Call]>([])
  private let newPodcastEpisodeCallsBox = Locked<[EpisodeCall]>([])
  public var continueListeningCalls: [Call] { continueListeningCallsBox.value }
  public var continueReadingCalls: [Call] { continueReadingCallsBox.value }
  public var continueSeriesCalls: [Call] { continueSeriesCallsBox.value }
  public var recentlyAddedCalls: [Call] { recentlyAddedCallsBox.value }
  public var recentlyAddedSinceCalls: [RecentCall] { recentlyAddedSinceCallsBox.value }
  public var downloadedCalls: [Call] { downloadedCallsBox.value }
  public var newPodcastEpisodeCalls: [EpisodeCall] { newPodcastEpisodeCallsBox.value }

  public func observeContinueListening(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]> {
    continueListeningCallsBox.withValue { $0.append((category, limit)) }
    return AsyncStream { continuation in
      continueListeningSubs.withValue { $0.append(continuation) }
    }
  }

  public func observeContinueReading(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]> {
    continueReadingCallsBox.withValue { $0.append((category, limit)) }
    return AsyncStream { continuation in
      continueReadingSubs.withValue { $0.append(continuation) }
    }
  }

  public func observeContinueSeries(
    category: ItemMediaCategory?, limit: Int
  ) -> AsyncStream<[HomeItem]> {
    continueSeriesCallsBox.withValue { $0.append((category, limit)) }
    return AsyncStream { continuation in
      continueSeriesSubs.withValue { $0.append(continuation) }
    }
  }

  public func observeRecentlyAdded(
    category: ItemMediaCategory?, limit: Int
  ) -> AsyncStream<HomeRecentlyAddedSnapshot> {
    recentlyAddedCallsBox.withValue { $0.append((category, limit)) }
    return AsyncStream { continuation in
      recentlyAddedSubs.withValue { $0.append(continuation) }
    }
  }

  public func observeRecentlyAdded(
    category: ItemMediaCategory?, limit: Int, since: Date?
  ) -> AsyncStream<HomeRecentlyAddedSnapshot> {
    recentlyAddedSinceCallsBox.withValue { $0.append((category, limit, since)) }
    return observeRecentlyAdded(category: category, limit: limit)
  }

  private let initialDownloadedBox = Locked<[HomeItem]?>(nil)
  /// Makes each new `observeDownloaded` subscription yield `items` straight away, as a store with
  /// rows already on disk does. `nil` (the default) yields nothing until a `pushDownloaded`.
  public func stubInitialDownloaded(_ items: [HomeItem]?) {
    initialDownloadedBox.value = items
  }

  public func observeDownloaded(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]> {
    downloadedCallsBox.withValue { $0.append((category, limit)) }
    return AsyncStream { continuation in
      downloadedSubs.withValue { $0.append(continuation) }
      if let initial = initialDownloadedBox.value { continuation.yield(initial) }
    }
  }

  public func observeNewPodcastEpisodes(
    cutoff: @escaping @Sendable () -> Date, limit: Int
  ) -> AsyncStream<HomeLatestPodcastEpisodesSnapshot> {
    // Recorded as the cutoff at subscribe time, which is what the existing call-site assertions
    // check; `cutoff` itself stays live for anything observing a later emission.
    newPodcastEpisodeCallsBox.withValue { $0.append((cutoff(), limit)) }
    return AsyncStream { continuation in
      newPodcastEpisodeSubs.withValue { $0.append(continuation) }
    }
  }

  /// Test-only: simulates `observeContinueListening`'s subscription at `index` (creation order;
  /// defaults to the most recent one) firing again.
  public func pushContinueListening(_ items: [HomeItem], at index: Int? = nil) {
    Self.push(items, to: continueListeningSubs, at: index)
  }

  public func pushContinueReading(_ items: [HomeItem], at index: Int? = nil) {
    Self.push(items, to: continueReadingSubs, at: index)
  }

  public func pushContinueSeries(_ items: [HomeItem], at index: Int? = nil) {
    Self.push(items, to: continueSeriesSubs, at: index)
  }

  /// Test-only: simulates `observeRecentlyAdded`'s subscription at `index` firing again.
  public func pushRecentlyAdded(_ items: [HomeItem], at index: Int? = nil) {
    pushRecentlyAdded(
      HomeRecentlyAddedSnapshot(all: items, nativePreferred: items), at: index)
  }

  public func pushRecentlyAdded(
    _ snapshot: HomeRecentlyAddedSnapshot, at index: Int? = nil
  ) {
    Self.push(snapshot, to: recentlyAddedSubs, at: index)
  }

  /// Test-only: simulates `observeDownloaded`'s subscription at `index` firing again.
  public func pushDownloaded(_ items: [HomeItem], at index: Int? = nil) {
    Self.push(items, to: downloadedSubs, at: index)
  }

  /// Test-only: simulates `observeNewPodcastEpisodes`'s subscription at `index` firing again.
  public func pushNewPodcastEpisodes(_ episodes: [HomePodcastEpisode], at index: Int? = nil) {
    pushNewPodcastEpisodes(
      HomeLatestPodcastEpisodesSnapshot(all: episodes, nativePreferred: episodes), at: index)
  }

  public func pushNewPodcastEpisodes(
    _ snapshot: HomeLatestPodcastEpisodesSnapshot, at index: Int? = nil
  ) {
    Self.push(snapshot, to: newPodcastEpisodeSubs, at: index)
  }

  private static func push<Value: Sendable>(
    _ value: Value, to subs: Locked<[AsyncStream<Value>.Continuation]>, at index: Int?
  ) {
    subs.withValue { continuations in
      let target = index ?? continuations.count - 1
      guard continuations.indices.contains(target) else { return }
      continuations[target].yield(value)
    }
  }
}
