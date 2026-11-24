import Foundation
import Observation
import Persistence
import SyncEngine

/// The bounded list behind a browse section's disclosure heading. It observes the local
/// Home projection rather than the Library tab, so the selected Home filter and the section’s
/// meaning survive the push.
@MainActor
@Observable
public final class HomeMoreModel {
  public enum State: Sendable, Equatable {
    case loading
    case empty
    case loaded
  }

  /// Latest Episodes opens three aggregate observations (ABS, RSS and the device gate), waits for
  /// every initial value, and publishes at most once per distinct merged snapshot.
  public static let latestEpisodesObservationSourceCount = 3

  private struct Content: Equatable {
    var state: State = .loading
    var items: [HomeItem] = []
    var podcastEpisodes: [HomePodcastEpisode] = []
  }

  private var content = Content()
  public var state: State { content.state }
  public var items: [HomeItem] { content.items }
  public var podcastEpisodes: [HomePodcastEpisode] { content.podcastEpisodes }
  /// Account-wide purgeable download storage, shown above the Downloaded list. `nil` until the
  /// storage observation first reports, so the page never briefly claims that an existing
  /// library occupies zero bytes.
  public private(set) var accountStorageBytes: Int64?
  /// Per-item purgeable storage for rows on the Downloaded page, keyed by server item id.
  /// Kept separate from `HomeItem`: storage changes independently of library metadata.
  public private(set) var itemStorageBytes: [String: Int64] = [:]

  public let section: HomeMoreSection
  public let filter: MediaFilter

  private static let limit = 100
  private let home: any HomeReading
  private let nativeLatestEpisodes: any NativeLatestPodcastEpisodesReading
  private let nativeContinueListening: any NativeContinueListeningReading
  private let nativeSubscriptions: any NativePodcastSubscriptionsReading
  private let sync: any SyncCoordinating
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var storageObservationTask: Task<Void, Never>?
  @ObservationIgnored private var itemStorageObservationTask: Task<Void, Never>?
  @ObservationIgnored private var sectionObservations = FilterObservationCoordinator()
  @ObservationIgnored private var continueListeningObservations = FilterObservationCoordinator()
  @ObservationIgnored private var latestABSEpisodeSnapshot: HomeLatestPodcastEpisodesSnapshot?
  @ObservationIgnored private var latestRSSEpisodes: [HomePodcastEpisode]?
  @ObservationIgnored private var nativeSubscriptionsEnabled: Bool?
  @ObservationIgnored private var latestRecentlyAddedSnapshot: HomeRecentlyAddedSnapshot?
  @ObservationIgnored private var latestABSContinueListening: [HomeItem]?
  @ObservationIgnored private var latestRSSContinueListening: [HomeItem]?
  @ObservationIgnored private var nativeContinueSubscriptionsEnabled: Bool?
  @ObservationIgnored private var downloadedObservations = FilterObservationCoordinator()
  @ObservationIgnored private var latestABSDownloaded: [HomeItem]?
  @ObservationIgnored private var latestRSSDownloaded: [HomeItem]?
  @ObservationIgnored private var nativeDownloadedSubscriptionsEnabled: Bool?

  public init(
    section: HomeMoreSection,
    filter: MediaFilter,
    home: any HomeReading,
    sync: any SyncCoordinating,
    nativeLatestEpisodes: any NativeLatestPodcastEpisodesReading =
      NoOpNativeLatestPodcastEpisodesReading(),
    nativeContinueListening: any NativeContinueListeningReading =
      NoOpNativeContinueListeningReading(),
    nativeSubscriptions: any NativePodcastSubscriptionsReading =
      NoOpNativePodcastSubscriptionsReading(),
    storageReading: any StorageReading = NoOpStorageReading(),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    // The old Recently Added/Podcasts restoration token remains readable, but its destination is
    // the same mixed Latest Episodes policy as the current route.
    self.section = section == .recentlyAdded && filter == .podcasts ? .newEpisodes : section
    self.filter = filter
    self.home = home
    self.nativeLatestEpisodes = nativeLatestEpisodes
    self.nativeContinueListening = nativeContinueListening
    self.nativeSubscriptions = nativeSubscriptions
    self.sync = sync
    subscribe(now: now)

    if self.section == .downloaded {
      let storageStream = storageReading.observeAccountStorageTotals()
      storageObservationTask = Task { [weak self] in
        for await totals in storageStream {
          guard let self else { return }
          self.accountStorageBytes = totals.totalBytes
        }
      }

      let itemStorageStream = storageReading.observeDownloadedItems()
      itemStorageObservationTask = Task { [weak self] in
        for await totals in itemStorageStream {
          guard let self else { return }
          self.itemStorageBytes = Dictionary(
            uniqueKeysWithValues: totals.map { ($0.itemId, $0.totalBytes) })
        }
      }
    }
  }

  deinit {
    observationTask?.cancel()
    storageObservationTask?.cancel()
    itemStorageObservationTask?.cancel()
  }

  public func refresh() async {
    await sync.refresh()
  }

  private func subscribe(now: @escaping @Sendable () -> Date) {
    let cutoff = HomeRecency.cutoff(now: now())

    if section == .newEpisodes {
      subscribeToLatestEpisodes(now: now)
      return
    }

    if section == .continueListening && (filter == .all || filter == .podcasts) {
      subscribeToContinueListening()
      return
    }

    if section == .downloaded && (filter == .all || filter == .podcasts) {
      subscribeToDownloaded()
      return
    }

    if section == .recentlyAdded && filter == .all {
      subscribeToRecentlyAdded(cutoff: cutoff)
      return
    }

    let stream: AsyncStream<[HomeItem]>
    switch section {
    case .continueListening:
      stream = home.observeContinueListening(category: filter.category, limit: Self.limit)
    case .continueReading:
      stream = home.observeContinueReading(category: filter.category, limit: Self.limit)
    case .continueSeries:
      stream = home.observeContinueSeries(category: filter.category, limit: Self.limit)
    case .newEpisodes:
      // Handled by the episode projection above.
      return
    case .recentlyAdded:
      let snapshots = home.observeRecentlyAdded(
        category: filter.category, limit: Self.limit, since: cutoff)
      stream = AsyncStream { continuation in
        let task = Task {
          for await snapshot in snapshots {
            continuation.yield(snapshot.all)
          }
          continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    case .downloaded:
      stream = home.observeDownloaded(category: filter.category, limit: Self.limit)
    case .savedForLater, .listeningStats, .smartLists:
      // Each has a dedicated destination, not this model.
      stream = AsyncStream { continuation in
        continuation.yield([])
        continuation.finish()
      }
    }

    observationTask = Task { [weak self] in
      for await items in stream {
        guard let self else { return }
        self.publish(items: items)
      }
    }
  }

  private func subscribeToContinueListening() {
    latestABSContinueListening = nil
    latestRSSContinueListening = nil
    nativeContinueSubscriptionsEnabled = nil
    let generation = continueListeningObservations.begin(
      sourceCount: HomeModel.continueListeningObservationSourceCount)
    continueListeningObservations.observe(
      home.observeContinueListening(category: filter.category, limit: Self.limit),
      sourceID: 0, in: generation
    ) { [weak self] items, _ in
      guard let self else { return }
      self.latestABSContinueListening = items
      self.publishMergedContinueListening()
    }
    continueListeningObservations.observe(
      nativeContinueListening.observeContinueListening(limit: Self.limit),
      sourceID: 1, in: generation
    ) { [weak self] items, _ in
      guard let self else { return }
      self.latestRSSContinueListening = items
      self.publishMergedContinueListening()
    }
    continueListeningObservations.observe(
      nativeSubscriptions.observeEnabledOrFalse(), sourceID: 2, in: generation
    ) { [weak self] enabled, _ in
      guard let self else { return }
      self.nativeContinueSubscriptionsEnabled = enabled
      self.publishMergedContinueListening()
    }
  }

  private func publishMergedContinueListening() {
    guard let abs = latestABSContinueListening,
      let rss = latestRSSContinueListening,
      let nativeContinueSubscriptionsEnabled
    else { return }
    publish(
      items: ContinueListeningMerge.merge(
        abs: abs,
        rss: rss,
        nativeSubscriptionsEnabled: nativeContinueSubscriptionsEnabled,
        limit: Self.limit))
  }

  /// The Downloads page mirrors Continue Listening: the account and device halves are merged
  /// under the native-subscriptions gate, so a signed-out feed download never appears while the
  /// feature is off, and the page and the Home shelf cannot disagree about what is downloaded.
  private func subscribeToDownloaded() {
    latestABSDownloaded = nil
    latestRSSDownloaded = nil
    nativeDownloadedSubscriptionsEnabled = nil
    let generation = downloadedObservations.begin(
      sourceCount: HomeModel.continueListeningObservationSourceCount)
    downloadedObservations.observe(
      home.observeDownloaded(category: filter.category, limit: Self.limit),
      sourceID: 0, in: generation
    ) { [weak self] items, _ in
      guard let self else { return }
      self.latestABSDownloaded = items
      self.publishMergedDownloaded()
    }
    downloadedObservations.observe(
      nativeContinueListening.observeDownloaded(limit: Self.limit),
      sourceID: 1, in: generation
    ) { [weak self] items, _ in
      guard let self else { return }
      self.latestRSSDownloaded = items
      self.publishMergedDownloaded()
    }
    downloadedObservations.observe(
      nativeSubscriptions.observeEnabledOrFalse(), sourceID: 2, in: generation
    ) { [weak self] enabled, _ in
      guard let self else { return }
      self.nativeDownloadedSubscriptionsEnabled = enabled
      self.publishMergedDownloaded()
    }
  }

  private func publishMergedDownloaded() {
    guard let abs = latestABSDownloaded,
      let rss = latestRSSDownloaded,
      let nativeDownloadedSubscriptionsEnabled
    else { return }
    publish(
      items: DownloadedShelfMerge.merge(
        abs: abs,
        rss: rss,
        nativeSubscriptionsEnabled: nativeDownloadedSubscriptionsEnabled,
        limit: Self.limit))
  }

  private func subscribeToLatestEpisodes(now: @escaping @Sendable () -> Date) {
    latestABSEpisodeSnapshot = nil
    latestRSSEpisodes = nil
    nativeSubscriptionsEnabled = nil
    let cutoff: @Sendable () -> Date = { HomeRecency.cutoff(now: now()) }
    let generation = sectionObservations.begin(
      sourceCount: Self.latestEpisodesObservationSourceCount)
    sectionObservations.observe(
      home.observeNewPodcastEpisodes(cutoff: cutoff, limit: Self.limit),
      sourceID: 0, in: generation
    ) { [weak self] snapshot, ready in
      guard let self else { return }
      self.latestABSEpisodeSnapshot = snapshot
      if ready { self.publishMergedLatestEpisodes() }
    }
    sectionObservations.observe(
      nativeLatestEpisodes.observeLatestPodcastEpisodes(cutoff: cutoff, limit: Self.limit),
      sourceID: 1, in: generation
    ) { [weak self] episodes, ready in
      guard let self else { return }
      self.latestRSSEpisodes = episodes
      if ready { self.publishMergedLatestEpisodes() }
    }
    sectionObservations.observe(
      nativeSubscriptions.observeEnabledOrFalse(), sourceID: 2, in: generation
    ) { [weak self] enabled, ready in
      guard let self else { return }
      self.nativeSubscriptionsEnabled = enabled
      if ready { self.publishMergedLatestEpisodes() }
    }
  }

  private func publishMergedLatestEpisodes() {
    guard let snapshot = latestABSEpisodeSnapshot, let rss = latestRSSEpisodes,
      let nativeSubscriptionsEnabled
    else { return }
    publish(
      podcastEpisodes: LatestPodcastEpisodesMerge.merge(
        snapshot: snapshot,
        rss: rss,
        nativeSubscriptionsEnabled: nativeSubscriptionsEnabled,
        limit: Self.limit))
  }

  private func subscribeToRecentlyAdded(cutoff: Date) {
    latestRecentlyAddedSnapshot = nil
    nativeSubscriptionsEnabled = nil
    let generation = sectionObservations.begin(sourceCount: 2)
    sectionObservations.observe(
      home.observeRecentlyAdded(category: nil, limit: Self.limit, since: cutoff),
      sourceID: 0, in: generation
    ) { [weak self] snapshot, _ in
      guard let self else { return }
      self.latestRecentlyAddedSnapshot = snapshot
      self.publishRecentlyAdded()
    }
    sectionObservations.observe(
      nativeSubscriptions.observeEnabledOrFalse(), sourceID: 1, in: generation
    ) { [weak self] enabled, _ in
      guard let self else { return }
      self.nativeSubscriptionsEnabled = enabled
      self.publishRecentlyAdded()
    }
  }

  private func publishRecentlyAdded() {
    guard let snapshot = latestRecentlyAddedSnapshot,
      let nativeSubscriptionsEnabled
    else { return }
    publish(
      items: HomeRecentlyAddedMerge.select(
        snapshot: snapshot, nativeSubscriptionsEnabled: nativeSubscriptionsEnabled))
  }

  private func publish(items: [HomeItem] = [], podcastEpisodes: [HomePodcastEpisode] = []) {
    let next = Content(
      state: items.isEmpty && podcastEpisodes.isEmpty ? .empty : .loaded,
      items: items,
      podcastEpisodes: podcastEpisodes)
    guard next != content else { return }
    content = next
  }
}
