import ABSApi
import AppModel
import Foundation
import Observation
import Persistence
import SyncEngine
import WidgetProtocol

/// Keeps the App Group snapshot in step with one account's shelves and the player, for the
/// widget extension to draw. Bound per account by `WidgetRuntime`, independently of the Watch.
///
/// Cadence: shelves publish on change, the player on play, pause and item change. Position is
/// never observed: progress arrives via the shelves (persisted every 15 seconds), so writes are no
/// faster, and only happen when content differs from disk. Stats read only the stored snapshot,
/// at start and when the stats model publishes a newer fetch. Smart lists reach their own file
/// through `WidgetSmartListFeed`, which owns their observation and reading.
@MainActor
final class WidgetSnapshotPublisher {
  /// Coalesces a burst of upstream changes into one publication.
  nonisolated static let debounce: Duration = .milliseconds(50)

  typealias ReloadTimelines = @MainActor () -> Void

  let stamp: WidgetAccountStamp
  private let home: any HomeReading
  private let nativeContinue: any NativeContinueListeningReading
  private let nativeLatest: any NativeLatestPodcastEpisodesReading
  private let bookmarks: any PlaybackBookmarkStoring
  private let nativeSubscriptions: any NativePodcastSubscriptionsReading
  private let listeningStats: any ListeningStatsProviding
  private let calendar: Calendar
  private let playback: PlaybackModel?
  private let artwork: (any ArtworkServing)?
  private let store: WidgetFileStore
  private let defaults: UserDefaults
  private let now: @MainActor () -> Date
  private let reloadTimelines: ReloadTimelines
  private let smartListSource: (any WidgetSmartListSource)?
  private let configuredSmartLists: WidgetSmartListFeed.ConfiguredLists
  private let notificationCenter: NotificationCenter
  private var smartListFeed: WidgetSmartListFeed?

  private var started = false
  private var epoch: UInt64 = 0
  private var salt = ""
  private var readerTasks: [Task<Void, Never>] = []
  private var publicationTask: Task<Void, Never>?
  private var coverTask: Task<Void, Never>?
  private var statsTask: Task<Void, Never>?
  private var coversPending = false
  private var preferencesObserver: NSObjectProtocol?

  private var nativeEnabled = false
  private var absContinue: [HomeItem] = []
  private var nativeContinueItems: [HomeItem] = []
  private var bookmark: PlaybackBookmark?
  private var absLatest: HomeLatestPodcastEpisodesSnapshot?
  private var nativeLatestEpisodes: [HomePodcastEpisode] = []
  private var statsSnapshot: ListeningStatsSnapshot?

  private var lastWritten: WidgetSnapshot?
  private var lastWrittenLists: WidgetSmartLists?
  /// The last complete list publication's rows and covers, kept while a newer one is incomplete
  /// so the rows already drawn still resolve and their covers are not pruned.
  private var lastListSelections: [String: WidgetTokenMap.ListSelection] = [:]
  private var lastListCoverRequests: [WidgetCoverRequest] = []
  /// Covers the previous launch's list file draws, kept until this launch's first complete list
  /// publication replaces them; their keys are not in the file, so they are kept, not refetched.
  private var retainedListCovers: Set<String> = []
  private var lastTokenMap: WidgetTokenMap?
  private var exportedCovers: Set<String> = []
  /// Covers already tried, by file name. A name embeds the cover's revision, so a cover that
  /// failed is fetched again only when its revision changes.
  private var attemptedCovers: Set<String> = []
  private var latestCoverRequests: [WidgetCoverRequest] = []

  init(
    identity: AccountIdentity,
    home: any HomeReading = NoOpHomeReading(),
    nativeContinue: any NativeContinueListeningReading = NoOpNativeContinueListeningReading(),
    nativeLatest: any NativeLatestPodcastEpisodesReading = NoOpNativeLatestPodcastEpisodesReading(),
    bookmarks: any PlaybackBookmarkStoring = NoOpPlaybackBookmarkStoring(),
    nativeSubscriptions: any NativePodcastSubscriptionsReading = NoOpNativePodcastSubscriptionsReading(),
    listeningStats: any ListeningStatsProviding = NoOpListeningStatsProviding(),
    playback: PlaybackModel? = nil,
    artwork: (any ArtworkServing)? = nil,
    store: WidgetFileStore,
    defaults: UserDefaults = .standard,
    now: @escaping @MainActor () -> Date = Date.init,
    calendar: Calendar = .autoupdatingCurrent,
    smartLists: (any WidgetSmartListSource)? = nil,
    configuredSmartLists: @escaping WidgetSmartListFeed.ConfiguredLists = { [] },
    notificationCenter: NotificationCenter = .default,
    reloadTimelines: @escaping ReloadTimelines
  ) throws {
    let hashes = CompanionCatalogueBuilder.identityHashes(for: identity)
    stamp = try WidgetAccountStamp(accountIdentityHash: hashes.account, serverIdentityHash: hashes.server)
    self.home = home
    self.nativeContinue = nativeContinue
    self.nativeLatest = nativeLatest
    self.bookmarks = bookmarks
    self.nativeSubscriptions = nativeSubscriptions
    self.listeningStats = listeningStats
    self.calendar = calendar
    self.playback = playback
    self.artwork = artwork
    self.store = store
    self.defaults = defaults
    self.now = now
    self.reloadTimelines = reloadTimelines
    self.smartListSource = smartLists
    self.configuredSmartLists = configuredSmartLists
    self.notificationCenter = notificationCenter
  }

  convenience init(
    identity: AccountIdentity, dependencies: AppDependencies, playback: PlaybackModel?,
    artwork: (any ArtworkServing)?, store: WidgetFileStore,
    smartLists: (any WidgetSmartListSource)?,
    configuredSmartLists: @escaping WidgetSmartListFeed.ConfiguredLists,
    reloadTimelines: @escaping ReloadTimelines
  ) throws {
    try self.init(
      identity: identity, home: dependencies.homeReading,
      nativeContinue: dependencies.nativeContinueListeningReading,
      nativeLatest: dependencies.nativeLatestPodcastEpisodesReading,
      bookmarks: dependencies.playbackBookmarkStoring,
      nativeSubscriptions: dependencies.nativePodcastSubscriptionsReading,
      listeningStats: dependencies.listeningStatsAccess,
      playback: playback, artwork: artwork, store: store, smartLists: smartLists,
      configuredSmartLists: configuredSmartLists, reloadTimelines: reloadTimelines)
  }

  deinit {
    if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    for task in readerTasks { task.cancel() }
    publicationTask?.cancel()
    coverTask?.cancel()
    statsTask?.cancel()
  }

  /// Cheap and synchronous apart from two small file reads: an intent can compose the app with
  /// no scene, and nothing here waits on one.
  func start() {
    guard !started else { return }
    started = true
    epoch &+= 1
    let previous = store.readTokenMap()
    if let previous, previous.belongs(to: stamp) {
      salt = previous.salt
      lastTokenMap = previous
    } else {
      // Another account's map and covers: nothing of theirs may resolve or draw for this one.
      if previous != nil { store.removeCoversAndTokenMap() }
      salt = UUID().uuidString
      lastTokenMap = nil
    }
    lastWritten = store.readSnapshot()
    lastWrittenLists = lastTokenMap == nil ? nil : store.readSmartLists()
    // The extension draws the previous list file until the feed has read every list, so its
    // rows keep resolving and its covers stay meanwhile.
    lastListSelections = lastTokenMap?.listSelections ?? [:]
    lastListCoverRequests = []
    retainedListCovers = Set(
      lastWrittenLists?.lists.flatMap { $0.items.compactMap(\.coverFileName) } ?? [])
    smartListFeed = smartListSource.map { source in
      WidgetSmartListFeed(
        source: source, configuredLists: configuredSmartLists, notificationCenter: notificationCenter
      ) { [weak self] in self?.schedulePublication() }
    }
    exportedCovers = store.existingCoverNames()
    attemptedCovers = []
    preferencesObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.schedulePublication() }
    }
    startReaders()
    observePlayback(epoch: epoch)
    reloadStats()
    schedulePublication()
  }

  /// Ends every observation and leaves the files as they are: the binding is being replaced.
  func stop() {
    started = false
    epoch &+= 1
    if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
    preferencesObserver = nil
    for task in readerTasks { task.cancel() }
    readerTasks = []
    publicationTask?.cancel()
    publicationTask = nil
    coverTask?.cancel()
    coverTask = nil
    statsTask?.cancel()
    statsTask = nil
    coversPending = false
    smartListFeed?.stop()
    smartListFeed = nil
  }

  /// Re-reads the stored stats whenever `model` publishes a newer fetch. The model only fetches
  /// when the listener opens Home's stats or the Stats screen, so this adds no network traffic.
  func observeStats(_ model: ListeningStatsModel) {
    observeStats(model, epoch: epoch)
  }

  private func observeStats(_ model: ListeningStatsModel, epoch: UInt64) {
    guard started, self.epoch == epoch else { return }
    withObservationTracking {
      _ = model.summary?.fetchedAt
    } onChange: { [weak self, weak model] in
      Task { @MainActor [weak self, weak model] in
        guard let self, let model, self.started, self.epoch == epoch else { return }
        self.reloadStats()
        self.observeStats(model, epoch: epoch)
      }
    }
  }

  private func reloadStats() {
    statsTask?.cancel()
    let epoch = epoch
    let listeningStats = listeningStats
    statsTask = Task { [weak self] in
      let snapshot = await listeningStats.cachedListeningStats()
      guard !Task.isCancelled, let self, self.started, self.epoch == epoch else { return }
      self.statsSnapshot = snapshot
      self.schedulePublication()
    }
  }

  private func startReaders() {
    let limit = WidgetSnapshotLimits.maxItemsPerShelf
    // Recomputed whenever an observation re-runs, not captured once at start.
    let cutoff: @Sendable () -> Date = { HomeRecency.cutoff(now: Date()) }
    readerTasks = [
      observe(home.observeContinueListening(category: nil, limit: limit)) { $0.absContinue = $1 },
      observe(nativeContinue.observeContinueListening(limit: limit)) { $0.nativeContinueItems = $1 },
      observe(bookmarks.observeBookmark()) { $0.bookmark = $1 },
      observe(home.observeNewPodcastEpisodes(cutoff: cutoff, limit: limit)) { $0.absLatest = $1 },
      observe(nativeLatest.observeLatestPodcastEpisodes(cutoff: cutoff, limit: limit)) {
        $0.nativeLatestEpisodes = $1
      },
      observe(nativeSubscriptions.observeEnabled()) {
        $0.nativeEnabled = $1
        // Started on the first value, so the lists are read once with the right sources.
        $0.smartListFeed?.start(nativeEnabled: $1)
      },
    ]
  }

  private func observe<Value: Sendable>(
    _ stream: AsyncStream<Value>,
    receive: @escaping @MainActor (WidgetSnapshotPublisher, Value) -> Void
  ) -> Task<Void, Never> {
    let epoch = epoch
    return Task { [weak self] in
      for await value in stream {
        guard let self, self.started, self.epoch == epoch else { return }
        receive(self, value)
        self.schedulePublication()
      }
    }
  }

  /// Play, pause and item changes. `isPlaybackIntended` is the listener's intent, so a buffer or
  /// a seek does not flip the control.
  private func observePlayback(epoch: UInt64) {
    guard started, self.epoch == epoch, let playback else { return }
    withObservationTracking {
      _ = playback.isPlaybackIntended
      _ = playback.phase
      _ = playback.activeItemID
      _ = playback.activeEpisodeID
      _ = playback.loadedItemID
      _ = playback.loadedEpisodeID
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.started, self.epoch == epoch else { return }
        self.schedulePublication()
        self.observePlayback(epoch: epoch)
      }
    }
  }

  func refresh() {
    schedulePublication()
  }

  /// A list's name as last written to the list file, for a tap's "Playing from" line.
  func publishedSmartListName(id: Int64) -> String? {
    lastWrittenLists?.list(id: id)?.name
  }

  private func schedulePublication() {
    guard started else { return }
    publicationTask?.cancel()
    let epoch = epoch
    publicationTask = Task { [weak self] in
      do {
        try await Task.sleep(for: Self.debounce)
      } catch {
        return
      }
      guard !Task.isCancelled, let self, self.started, self.epoch == epoch else { return }
      self.publishCurrent()
    }
  }

  private func publishCurrent() {
    let generatedAt = now()
    let stats = statsSnapshot.flatMap {
      WidgetStatsAssembly.make(snapshot: $0, now: generatedAt, calendar: calendar)
    }
    let assembly = WidgetSnapshotAssembly(
      accountStamp: stamp, tokenSalt: salt, nativeEnabled: nativeEnabled,
      absContinue: absContinue, nativeContinue: nativeContinueItems, absLatest: absLatest,
      nativeLatest: nativeLatestEpisodes, bookmark: bookmark, loaded: loadedSelection,
      isPlaying: playback?.isPlaybackIntended ?? false, skipBackSeconds: skipBackSeconds,
      generatedAt: generatedAt, absArtworkSource: artwork?.defaultSource,
      coverPixelWidth: CoverPaletteSource.cardPixelWidth, exportedCovers: exportedCovers,
      stats: stats)
    guard let publication = assembly.makePublication() else { return }
    let listPublication = smartListPublication(
      generatedAt: generatedAt,
      coverBudget: max(0, WidgetStorageLayout.maxCoverFiles - publication.coverRequests.count))
    if let listPublication {
      lastListSelections = listPublication.selections
      lastListCoverRequests = listPublication.coverRequests
      retainedListCovers = []
    }
    // The map first: a tap on a row drawn from the new files must already resolve.
    let map = WidgetTokenMap(
      stamp: stamp, salt: salt, selections: publication.selections, listSelections: lastListSelections)
    if map != lastTokenMap, (try? store.writeTokenMap(map)) != nil { lastTokenMap = map }
    var wrote = false
    if !Self.sameContent(publication.snapshot, lastWritten),
      let data = try? WidgetSnapshotCodec.encode(publication.snapshot),
      (try? store.writeSnapshot(data)) != nil
    {
      lastWritten = publication.snapshot
      wrote = true
    }
    if let lists = listPublication?.lists, !Self.sameContent(lists, lastWrittenLists),
      let data = try? WidgetSmartListsCodec.encode(lists),
      (try? store.writeSmartLists(data)) != nil
    {
      lastWrittenLists = lists
      wrote = true
    }
    if wrote { reloadTimelines() }
    var covers = publication.coverRequests
    for request in lastListCoverRequests where !covers.contains(where: { $0.fileName == request.fileName }) {
      covers.append(request)
    }
    requestCovers(covers)
  }

  /// `nil` with no smart lists composed, before the feed has read every list, or for a file that
  /// would not validate; the previous file then stays.
  private func smartListPublication(generatedAt: Date, coverBudget: Int) -> WidgetSmartListPublication? {
    guard let smartListFeed else { return nil }
    return WidgetSmartListAssembly(
      accountStamp: stamp, tokenSalt: salt, lists: smartListFeed.lists,
      contents: smartListFeed.contents, shownListIDs: smartListFeed.shownListIDs,
      loaded: loadedSelection,
      isPlaying: playback?.isPlaybackIntended ?? false, generatedAt: generatedAt,
      absArtworkSource: artwork?.defaultSource, coverPixelWidth: CoverPaletteSource.cardPixelWidth,
      coverBudget: coverBudget, exportedCovers: exportedCovers
    ).makePublication()
  }

  private func requestCovers(_ requests: [WidgetCoverRequest]) {
    latestCoverRequests = requests
    guard let artwork else { return }
    guard coverTask == nil else {
      coversPending = true
      return
    }
    let wanted = Set(requests.map(\.fileName)).union(retainedListCovers)
    let missing = requests.filter {
      !exportedCovers.contains($0.fileName) && !attemptedCovers.contains($0.fileName)
    }
    // Nothing to fetch and nothing to prune.
    guard !missing.isEmpty || !exportedCovers.isSubset(of: wanted) else { return }
    attemptedCovers.formUnion(missing.map(\.fileName))
    let exporter = WidgetCoverExporter(artwork: artwork, store: store)
    let epoch = epoch
    coverTask = Task { [weak self] in
      let present = await exporter.export(missing: missing, wanted: wanted)
      guard let self, self.epoch == epoch else { return }
      self.coverTask = nil
      let changed = present != self.exportedCovers
      self.exportedCovers = present
      // A pruned cover that is wanted again later is fetched again.
      self.attemptedCovers.formIntersection(wanted)
      if self.coversPending {
        self.coversPending = false
        self.requestCovers(self.latestCoverRequests)
      }
      if changed { self.schedulePublication() }
    }
  }

  private var loadedSelection: CompanionSelection? {
    guard let playback, let itemID = playback.loadedItemID,
      playback.isLoaded(itemID: itemID, episodeID: playback.loadedEpisodeID),
      let source = PodcastSourceIdentity(itemId: itemID)
    else { return nil }
    return CompanionSelection(source: source, episodeID: playback.loadedEpisodeID)
  }

  private var skipBackSeconds: Int {
    SkipIntervalConfiguration.resolvedSeconds(
      defaults.integer(forKey: SkipIntervalConfiguration.backwardStorageKey), forward: false)
  }

  /// Everything but `generatedAt`, which changes on every publication and would otherwise make
  /// every publication a write and a timeline reload.
  static func sameContent(_ lhs: WidgetSnapshot, _ rhs: WidgetSnapshot?) -> Bool {
    guard let rhs else { return false }
    return lhs.schemaVersion == rhs.schemaVersion && lhs.accountStamp == rhs.accountStamp
      && lhs.nowPlaying == rhs.nowPlaying && lhs.skipBackSeconds == rhs.skipBackSeconds
      && lhs.continueListening == rhs.continueListening && lhs.latestEpisodes == rhs.latestEpisodes
      && lhs.stats == rhs.stats
  }

  static func sameContent(_ lhs: WidgetSmartLists, _ rhs: WidgetSmartLists?) -> Bool {
    guard let rhs else { return false }
    return lhs.schemaVersion == rhs.schemaVersion && lhs.accountStamp == rhs.accountStamp
      && lhs.isPlaying == rhs.isPlaying && lhs.lists == rhs.lists
  }
}
