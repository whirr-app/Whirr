import Foundation
import Observation
import Persistence
import SyncEngine

/// The Home tab, the app's landing screen. Populates entirely
/// from `HomeReading`'s observed, account-scoped projections (never the network directly,
/// mirroring `LibraryBrowseModel`) and forwards pull-to-refresh to `SyncCoordinating.refresh()`.
/// Unlike `LibraryBrowseModel`, the subscription itself is not fixed at construction: changing
/// `filter` must swap the relevant underlying observations for ones scoped to the new category.
@MainActor
@Observable
public final class HomeModel {
  /// Overall screen readiness. Carries no data of its own: the section properties are the
  /// content, this only says whether they're safe to trust yet. `.empty` only once every relevant
  /// section has reported and all are empty. Until every section has emitted at least once the
  /// screen stays where it is (`.loading` on first load, and after a `filter` change the previous
  /// filter's state and contents) rather than flashing an empty or loading section.
  public enum State: Sendable, Equatable {
    case loading
    case empty
    case loaded
  }

  /// Continue Listening opens three aggregate observations (ABS, RSS and the device gate), waits
  /// for every initial value, and publishes at most once per distinct merged snapshot.
  public static let continueListeningObservationSourceCount = 3

  public private(set) var state: State = .loading
  public private(set) var continueListening: [HomeItem] = []
  public private(set) var continueReading: [HomeItem] = []
  public private(set) var recentlyAdded: [HomeItem] = []
  public private(set) var continueSeries: [HomeItem] = []
  public private(set) var downloaded: [HomeItem] = []
  public private(set) var savedForLater: [SavedShelfItem] = []

  /// Settable directly (a SwiftUI `Picker`/chip row binds straight to this), like
  /// `NavigationModel.section`. Re-subscribing on every actual change (not every assignment) makes
  /// repeatedly selecting the already-active chip a no-op.
  public var filter: MediaFilter {
    didSet {
      guard filter != oldValue else { return }
      subscribe(filter: filter)
    }
  }

  private let home: any HomeReading
  private let sync: any SyncCoordinating
  private let nativeContinueListening: any NativeContinueListeningReading
  private let nativeSubscriptions: any NativePodcastSubscriptionsReading
  /// Optional because `NoOpSavedShelfReading` finishes without emitting; `nil` means there is no
  /// saved source to observe or count in the readiness barrier, so the section stays empty.
  private let savedShelf: (any SavedShelfReading)?
  private let limit: Int
  /// Handed to the projection rather than read here: the episode window is relative to now, so
  /// it is evaluated per emission. A subscription that survives a filter change, or outlives the
  /// day it was made, must cut from the current moment and not from launch.
  private let now: @Sendable () -> Date

  // Per-section trackers for the current subscription generation only. `nil` until this
  // generation's stream has emitted at least once. `recomputeState` uses that to hold `state` at
  // `.loading` until every section has reported.
  private var latestContinueListening: [HomeItem]?
  private var latestABSContinueListening: [HomeItem]?
  private var latestRSSContinueListening: [HomeItem]?
  private var nativeContinueSubscriptionsEnabled: Bool?
  private var latestContinueReading: [HomeItem]?
  private var latestRecentlyAddedSnapshot: HomeRecentlyAddedSnapshot?
  private var latestRecentlyAdded: [HomeItem]?
  private var latestContinueSeries: [HomeItem]?
  private var latestDownloaded: [HomeItem]?
  private var latestABSDownloaded: [HomeItem]?
  private var latestRSSDownloaded: [HomeItem]?
  private var latestSavedForLater: [SavedShelfItem]?

  /// Shared with `LibraryBrowseModel`: owns generation invalidation, task cancellation, and the
  /// “all sources have emitted” readiness barrier. It is ignored by Observation because it is
  /// lifecycle machinery, not screen state.
  @ObservationIgnored private var filterObservations = FilterObservationCoordinator()

  /// `limit`: how many items each horizontally-scrolling row asks for. A screen-layout decision
  /// this model owns, since `HomeReading` takes it as a plain parameter with no default.
  public init(
    home: any HomeReading,
    sync: any SyncCoordinating,
    filter: MediaFilter = .all,
    limit: Int = 20,
    savedShelf: (any SavedShelfReading)? = nil,
    nativeContinueListening: any NativeContinueListeningReading =
      NoOpNativeContinueListeningReading(),
    nativeSubscriptions: any NativePodcastSubscriptionsReading =
      NoOpNativePodcastSubscriptionsReading(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.home = home
    self.sync = sync
    self.nativeContinueListening = nativeContinueListening
    self.nativeSubscriptions = nativeSubscriptions
    self.savedShelf = savedShelf
    self.limit = limit
    self.now = now
    self.filter = filter

    // Explicit first subscribe: `filter`'s `didSet` does not fire for this initial assignment
    // (Swift never calls property observers from a stored property's own initializer).
    // Subscribed synchronously in `init`.
    subscribe(filter: filter)
  }

  /// Pull-to-refresh: forwards to `SyncCoordinating.refresh()`. This model never talks to
  /// `ABSApi` directly (ARCHITECTURE.md §2).
  public func refresh() async {
    await sync.refresh()
  }

  private func subscribe(filter: MediaFilter) {
    latestContinueListening = nil
    latestABSContinueListening = nil
    latestRSSContinueListening = nil
    nativeContinueSubscriptionsEnabled = nil
    latestContinueReading = nil
    latestRecentlyAddedSnapshot = nil
    latestRecentlyAdded = nil
    latestContinueSeries = nil
    latestDownloaded = nil
    latestABSDownloaded = nil
    latestRSSDownloaded = nil
    latestSavedForLater = nil

    // A re-subscribe holds whatever is on screen (contents and `state`) until every section of
    // the new generation has reported, then `recomputeState` swaps them all at once. Clearing
    // here would drop the screen to `.loading` for the milliseconds a filter change takes, which
    // flickers and, by tearing the loaded subtree down, robs the filter control of its selection
    // animation. The very first subscribe has nothing to hold and starts empty and `.loading`.
    if state == .loading {
      continueListening = []
      continueReading = []
      recentlyAdded = []
      continueSeries = []
      downloaded = []
      savedForLater = []
    }

    let observesRecentItems = filter != .podcasts
    let observesContinueReading = filter != .podcasts
    let observesContinueSeries = filter != .podcasts
    let observesSaved = savedShelf != nil
    let observesMergedContinueListening = filter == .all || filter == .podcasts
    let continueListeningSourceCount =
      observesMergedContinueListening ? Self.continueListeningObservationSourceCount : 1
    // The Downloads shelf merges the same two halves under the same gate, and the gate
    // observation is opened once for both merges, so the shelf adds only its RSS source.
    let observesMergedDownloaded = observesMergedContinueListening
    let downloadedSourceCount = observesMergedDownloaded ? 2 : 1
    let sourceCount =
      continueListeningSourceCount + downloadedSourceCount
      + (observesContinueReading ? 1 : 0)
      + (observesRecentItems ? 1 : 0)
      + (observesContinueSeries ? 1 : 0)
      + (observesSaved ? 1 : 0)
    let generation = filterObservations.begin(sourceCount: sourceCount)
    let category = filter.category
    var sourceID = 0

    // Subscribed synchronously here, not inside the `Task`s below, on every call and not only at
    // construction, so a re-subscribe after a filter change cannot miss its first emission.
    let continueListeningStream = home.observeContinueListening(category: category, limit: limit)
    let downloadedStream = home.observeDownloaded(category: category, limit: limit)

    filterObservations.observe(continueListeningStream, sourceID: sourceID, in: generation) {
      [weak self] items, ready in
      guard let self else { return }
      if observesMergedContinueListening {
        self.latestABSContinueListening = items
        self.publishMergedContinueListening(filter: filter, ready: ready)
      } else {
        self.latestContinueListening = items
        if ready { self.recomputeState(filter: filter) }
      }
    }
    sourceID += 1

    if observesMergedContinueListening {
      filterObservations.observe(
        nativeContinueListening.observeContinueListening(limit: limit),
        sourceID: sourceID, in: generation
      ) { [weak self] items, ready in
        guard let self else { return }
        self.latestRSSContinueListening = items
        self.publishMergedContinueListening(filter: filter, ready: ready)
      }
      sourceID += 1

      filterObservations.observe(
        nativeSubscriptions.observeEnabledOrFalse(), sourceID: sourceID, in: generation
      ) { [weak self] enabled, ready in
        guard let self else { return }
        self.nativeContinueSubscriptionsEnabled = enabled
        self.publishMergedContinueListening(filter: filter, ready: ready)
        self.publishMergedDownloaded(filter: filter, ready: ready)
        self.publishRecentlyAdded(filter: filter, ready: ready)
      }
      sourceID += 1
    }

    if observesContinueReading {
      let continueReadingStream = home.observeContinueReading(category: category, limit: limit)
      filterObservations.observe(continueReadingStream, sourceID: sourceID, in: generation) {
        [weak self] items, ready in
        guard let self else { return }
        self.latestContinueReading = items
        if ready { self.recomputeState(filter: filter) }
      }
      sourceID += 1
    }

    if observesContinueSeries {
      let seriesStream = home.observeContinueSeries(category: category, limit: limit)
      filterObservations.observe(seriesStream, sourceID: sourceID, in: generation) {
        [weak self] items, ready in
        guard let self else { return }
        self.latestContinueSeries = items
        if ready { self.recomputeState(filter: filter) }
      }
      sourceID += 1
    }

    if observesRecentItems {
      let now = now
      let recentlyAddedStream = home.observeRecentlyAdded(
        category: category, limit: limit, since: HomeRecency.cutoff(now: now()))
      filterObservations.observe(recentlyAddedStream, sourceID: sourceID, in: generation) {
        [weak self] snapshot, ready in
        guard let self else { return }
        self.latestRecentlyAddedSnapshot = snapshot
        self.publishRecentlyAdded(filter: filter, ready: ready)
      }
      sourceID += 1
    }

    filterObservations.observe(downloadedStream, sourceID: sourceID, in: generation) {
      [weak self] items, ready in
      guard let self else { return }
      if observesMergedDownloaded {
        self.latestABSDownloaded = items
        self.publishMergedDownloaded(filter: filter, ready: ready)
      } else {
        self.latestDownloaded = items
        if ready { self.recomputeState(filter: filter) }
      }
    }
    if observesMergedDownloaded {
      sourceID += 1
      filterObservations.observe(
        nativeContinueListening.observeDownloaded(limit: limit), sourceID: sourceID, in: generation
      ) { [weak self] items, ready in
        guard let self else { return }
        self.latestRSSDownloaded = items
        self.publishMergedDownloaded(filter: filter, ready: ready)
      }
    }
    if let savedShelf {
      sourceID += 1
      let savedStream = savedShelf.observeSaved(filter: category, limit: limit)
      filterObservations.observe(savedStream, sourceID: sourceID, in: generation) {
        [weak self] items, ready in
        guard let self else { return }
        self.latestSavedForLater = items
        if ready { self.recomputeState(filter: filter) }
      }
    }
  }

  private func publishMergedContinueListening(filter: MediaFilter, ready: Bool) {
    guard let abs = latestABSContinueListening,
      let rss = latestRSSContinueListening,
      let nativeContinueSubscriptionsEnabled
    else { return }
    latestContinueListening = ContinueListeningMerge.merge(
      abs: abs,
      rss: rss,
      nativeSubscriptionsEnabled: nativeContinueSubscriptionsEnabled,
      limit: limit)
    if ready { recomputeState(filter: filter) }
  }

  private func publishMergedDownloaded(filter: MediaFilter, ready: Bool) {
    guard let abs = latestABSDownloaded,
      let rss = latestRSSDownloaded,
      let nativeContinueSubscriptionsEnabled
    else { return }
    latestDownloaded = DownloadedShelfMerge.merge(
      abs: abs,
      rss: rss,
      nativeSubscriptionsEnabled: nativeContinueSubscriptionsEnabled,
      limit: limit)
    if ready { recomputeState(filter: filter) }
  }

  private func publishRecentlyAdded(filter: MediaFilter, ready: Bool) {
    guard let snapshot = latestRecentlyAddedSnapshot else { return }
    if filter == .all {
      guard let nativeContinueSubscriptionsEnabled else { return }
      latestRecentlyAdded =
        HomeRecentlyAddedMerge.select(
          snapshot: snapshot, nativeSubscriptionsEnabled: nativeContinueSubscriptionsEnabled)
    } else {
      latestRecentlyAdded = snapshot.all
    }
    if ready { recomputeState(filter: filter) }
  }

  private func recomputeState(filter: MediaFilter) {
    guard
      let continueListening = latestContinueListening,
      let downloaded = latestDownloaded
    else {
      // Leaves `state` alone: on a first subscribe it is already `.loading`, and on a
      // re-subscribe it is the held previous state, which must survive until all sources report.
      return
    }

    let observesRecentItems = filter != .podcasts
    let observesContinueReading = filter != .podcasts
    let observesContinueSeries = filter != .podcasts
    let observesSaved = savedShelf != nil
    guard observesContinueReading == false || latestContinueReading != nil else { return }
    guard observesRecentItems == false || latestRecentlyAdded != nil else { return }
    guard observesContinueSeries == false || latestContinueSeries != nil else { return }
    guard observesSaved == false || latestSavedForLater != nil else { return }

    let nextRecentlyAdded = observesRecentItems ? (latestRecentlyAdded ?? []) : []
    let nextContinueReading = observesContinueReading ? (latestContinueReading ?? []) : []
    let nextContinueSeries = observesContinueSeries ? (latestContinueSeries ?? []) : []
    let nextDownloaded = downloaded
    let nextSavedForLater = observesSaved ? (latestSavedForLater ?? []) : []
    if recentlyAdded != nextRecentlyAdded { recentlyAdded = nextRecentlyAdded }
    if continueReading != nextContinueReading { continueReading = nextContinueReading }
    if continueSeries != nextContinueSeries { continueSeries = nextContinueSeries }
    if self.continueListening != continueListening { self.continueListening = continueListening }
    if self.downloaded != nextDownloaded { self.downloaded = nextDownloaded }
    if savedForLater != nextSavedForLater { savedForLater = nextSavedForLater }
    let nextState =
      (continueListening.isEmpty && nextContinueReading.isEmpty && nextContinueSeries.isEmpty
        && nextRecentlyAdded.isEmpty && nextDownloaded.isEmpty && nextSavedForLater.isEmpty)
      ? State.empty : .loaded
    if state != nextState { state = nextState }
  }
}
