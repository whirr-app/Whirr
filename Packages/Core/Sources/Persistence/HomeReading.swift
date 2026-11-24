import Foundation

/// Home-screen projections: continue listening, continue reading, recently added, downloaded.
/// All account-scoped and cross-library, unlike `LibraryReading.observeBrowseList`. As with
/// `DownloadReading`, screens observe these, never raw `ItemRecord`, `MediaProgressRecord` or
/// `DownloadRecord` values.
public protocol HomeReading: Sendable {
  /// Items with progress (`mediaProgress.currentTime > 0`, not finished), most-recently-
  /// progressed first, ordered by the server's last-progress timestamp with the local sequence
  /// as the fallback for progress that has not reached the server yet. `category` filters in SQL
  /// before `limit` is applied; `nil` returns every category. Re-emitted whenever matching
  /// progress changes.
  func observeContinueListening(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]>

  /// EPUB-bearing items with ebook progress (`mediaProgress.ebookProgress > 0`, not finished),
  /// ordered by server progress update, falling back to local progress sequence when the server
  /// timestamp is absent. `category` filters in SQL before `limit` is applied; podcasts never
  /// qualify even if malformed rows carry EPUB-shaped signals.
  func observeContinueReading(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]>

  /// Continue Series suggestions: a series is offered when at least one of its books is finished,
  /// none is in progress, and at least one is unfinished. The offered book is the lowest-sequenced
  /// unfinished one; there is one book per series, and series are ordered by most recent progress.
  /// `category` filters in SQL before the series limit is applied; `nil` returns every category,
  /// with podcasts excluded explicitly by the projection.
  func observeContinueSeries(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]>

  /// Items ordered by `addedAt` descending (nulls last), soft-deleted excluded. `category`
  /// filters in SQL before `limit` is applied; `nil` returns every category. Both policy arrays
  /// are independently ranked and capped by the effective non-negative limit in one tracked
  /// projection: `all` is the ordinary ABS result and `nativePreferred` omits only server podcast
  /// shows with a valid, exact RSS feed fingerprint.
  func observeRecentlyAdded(
    category: ItemMediaCategory?, limit: Int
  ) -> AsyncStream<HomeRecentlyAddedSnapshot>

  /// The same recently-added projection, optionally restricted to a recency cutoff. The
  /// database-backed reader applies the cutoff before each policy's limit so a full Home-more
  /// page cannot be starved by older rows.
  func observeRecentlyAdded(
    category: ItemMediaCategory?, limit: Int, since: Date?
  ) -> AsyncStream<HomeRecentlyAddedSnapshot>

  /// Recent episodes across every podcast show, with parent-show context for Home’s podcast page.
  ///
  /// `cutoff` is a closure because the window is relative to now. It is re-evaluated on every
  /// emission, so a long-lived subscription stops projecting episodes that have aged out. A
  /// plain `Date` would freeze the window at the subscribe instant for the life of the stream.
  func observeNewPodcastEpisodes(
    cutoff: @escaping @Sendable () -> Date, limit: Int
  ) -> AsyncStream<HomeLatestPodcastEpisodesSnapshot>

  /// Items whose download rollup (`DownloadStore.itemStatus`) is `.completed`; partial, paused
  /// and deleting are excluded. Ordered by `sortTitle` (the download schema records no completion
  /// timestamp, so there is no recency ordering). `category` filters in SQL before `limit`
  /// is applied; `nil` returns every category. Re-emitted whenever a download completes.
  func observeDownloaded(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]>
}

extension HomeReading {
  public func observeRecentlyAdded(
    category: ItemMediaCategory?, limit: Int, since: Date?
  ) -> AsyncStream<HomeRecentlyAddedSnapshot> {
    observeRecentlyAdded(category: category, limit: limit)
  }

  public func observeNewPodcastEpisodes(
    cutoff: @escaping @Sendable () -> Date, limit: Int
  ) -> AsyncStream<HomeLatestPodcastEpisodesSnapshot> {
    AsyncStream {
      $0.yield(HomeLatestPodcastEpisodesSnapshot(all: [], nativePreferred: []))
      $0.finish()
    }
  }
}

/// The default no-op `HomeReading` conformance: every stream finishes immediately without
/// yielding, like `NoOpDownloadReading`.
public struct NoOpHomeReading: HomeReading, Sendable {
  public init() {}
  public func observeContinueListening(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]> {
    AsyncStream { $0.finish() }
  }
  public func observeContinueReading(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]> {
    AsyncStream { $0.finish() }
  }
  public func observeContinueSeries(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]> {
    AsyncStream { $0.finish() }
  }
  public func observeRecentlyAdded(
    category: ItemMediaCategory?, limit: Int
  ) -> AsyncStream<HomeRecentlyAddedSnapshot> {
    AsyncStream {
      $0.yield(HomeRecentlyAddedSnapshot(all: [], nativePreferred: []))
      $0.finish()
    }
  }
  public func observeNewPodcastEpisodes(
    cutoff: @escaping @Sendable () -> Date, limit: Int
  ) -> AsyncStream<HomeLatestPodcastEpisodesSnapshot> {
    AsyncStream {
      $0.yield(HomeLatestPodcastEpisodesSnapshot(all: [], nativePreferred: []))
      $0.finish()
    }
  }
  public func observeDownloaded(category: ItemMediaCategory?, limit: Int) -> AsyncStream<[HomeItem]> {
    AsyncStream { $0.finish() }
  }
}
