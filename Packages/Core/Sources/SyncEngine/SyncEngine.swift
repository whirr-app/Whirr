import ABSApi
import Foundation
import Persistence

/// The production `SyncCoordinating` conformance (ARCHITECTURE.md): the sole post-login
/// orchestrator of library-pull API work. A whole-account refresh is the unit of work, so the
/// single `currentRefresh` slot stops a concurrent trigger starting a second traversal.
///
/// Wire DTOs end here: every `ABSClient` response is mapped into a plain
/// `ItemRecord`/`MediaProgressRecord` before it reaches `Persistence`'s DAOs.
public actor SyncEngine: SyncCoordinating {
  let client: ABSClient
  let clock: any SyncClock
  let randomSource: @Sendable () -> Double
  let pageLimit: Int
  let diagnostics: any DiagnosticsRecording
  let progressMerge = ProgressMergePolicy()
  let appLifecycle: any AppLifecycle
  let playback: (any PlaybackSyncing)?
  /// Fires `OutboxDrainer.drainLocalSessionUploads()`, injected by App-level composition (this
  /// engine never constructs a drainer). `nil` in harnesses that don't need the local-all
  /// trigger. The drainer's own in-flight flag coalesces overlapping calls. There is no timer
  /// path (API-CONVENTIONS.md rule 20): only launch, foreground, an offline-session close while
  /// non-offline, and explicit refresh call this.
  let localSessionUploadDrain: (@Sendable () async -> Void)?
  let recentEpisodes: RecentEpisodeRefreshCoordinator?
  /// Lands the half of `/api/me` a library pull structurally cannot (see the coordinator's own
  /// doc comment). `nil` in harnesses that don't need podcast progress.
  let podcastProgressHydration: PodcastProgressHydrationCoordinator?
  /// Fills one bounded page of missing expanded book metadata after a completed library pull.
  /// `nil` makes it a no-op.
  let metadataBackfill: ItemMetadataBackfillCoordinator?
  /// Fires an auto-download pass, then a reap, right after the recent-episodes shelf commits
  /// successfully. `nil` in harnesses that don't need device auto-download (no-op unless
  /// supplied).
  let podcastAutoDownload: PodcastAutoDownloadCoordinator?
  let podcastAutoDownloadReaper: PodcastAutoDownloadReaper?
  /// Refreshes the complete author/series index after a successful library traversal. Kept as a
  /// closure so this orchestrator does not own a second service instance or its flight state.
  let authorSeriesFilterDataRefresh: (@Sendable () async -> Void)?
  /// Refreshes the server collections and playlists after the author and series hand-off.
  /// A closure for the same ownership reason.
  let libraryCollectionRefresh: (@Sendable () async -> Void)?

  let accountDAO: AccountDAO
  let libraryDAO: LibraryDAO
  let database: AppDatabase
  let syncRunDAO: SyncRunDAO
  let mediaProgressDAO: MediaProgressDAO
  let itemDAO: ItemDAO
  /// Only used to reach `hasUnacknowledgedSessionWrite` from `progressOutcome`. `nil` only if
  /// `OutboxStore`'s construction failed (not expected against a valid database), in which case
  /// the session-aware protection falls back to the item-keyed check alone.
  let sessionStore: PlaybackSessionStore?

  /// The traversal in flight, run in a task this engine owns rather than on its caller's, so
  /// `shutdown()` can cancel and await it. Set before the task can start and cleared by the task
  /// itself as its last isolated step, so a later trigger never sees a finished run as active.
  var currentRefresh: Task<LibraryDiscoveryRefreshResult, Never>?
  /// Actor-isolated coalescing state for triggers arriving while a traversal is suspended on I/O.
  /// Any number collapse into one later traversal, but the slot keeps the strongest reason, not a
  /// bare flag: a pull-to-refresh or library inclusion joining an in-flight foreground pass must
  /// still reconcile as that trigger, in `syncRun` and for anything deciding whether a pass may be
  /// skipped.
  var pendingRefreshReason: RefreshReason?

  /// When each library's last completed traversal finished, for the foreground minimum interval.
  /// Engine memory rather than a `syncRun` read (see `pullLibrary` for why the persisted state is
  /// the wrong source). Lost on relaunch, so a cold start traverses.
  var lastCompletedTraversalAtByLibraryRowId: [Int64: Date] = [:]

  /// How long a completed traversal satisfies a foreground refresh for. Foreground delivery is
  /// frequent and uncorrelated with server change: E47 measured 140 of 196 consecutive foreground
  /// intervals under a minute, with a 11.9s minimum. Explicit refresh is never gated by it.
  static let minimumForegroundTraversalInterval: TimeInterval = 60
  private var lifecycleSubscriptionTask: Task<Void, Never>?
  private var launchDrainTask: Task<Void, Never>?
  var isShutdown = false
  /// Exponential-with-jitter pacing for a library whose traversal ended `incomplete` or
  /// `unstablePagination` (API-CONVENTIONS.md rule 14).
  var backoffByLibraryRowId: [Int64: ABSApi.BackoffPolicy] = [:]
  var nextAttemptAllowedAtByLibraryRowId: [Int64: Date] = [:]
  /// Admission pacing for the account-wide library list, independent from each library's page
  /// traversal and from the drains triggered by `refresh()`.
  var libraryListBackoff: ABSApi.BackoffPolicy?
  var nextLibraryListAttemptAllowedAt: Date?
  /// `/api/me` is enrichment only: a closed gate returns an empty projection and the library
  /// traversal below still runs.
  var progressBackoff: ABSApi.BackoffPolicy?
  var nextProgressAttemptAllowedAt: Date?
  /// Recent shelves are gated by server library id so one unreachable podcast library does not
  /// suppress the other shelves in the same refresh.
  var podcastShelfBackoffByLibraryID: [String: ABSApi.BackoffPolicy] = [:]
  var nextPodcastShelfAttemptAllowedAtByLibraryID: [String: Date] = [:]

  /// Requests deterministic server sort by stable item id. ABS's sort dot-path grammar for "by
  /// id" is unconfirmed against a live server (its API docs show `media.metadata.title`-style
  /// paths, not an id path). The value is only requested and recorded, never assumed honoured.
  static let requestedSort = "id"

  nonisolated static func durationMilliseconds(startedAt: Date, endedAt: Date) -> Double {
    max(0, endedAt.timeIntervalSince(startedAt) * 1_000)
  }

  private init(
    client: ABSClient,
    database: AppDatabase,
    diagnostics: any DiagnosticsRecording,
    clock: any SyncClock,
    randomSource: @escaping @Sendable () -> Double,
    pageLimit: Int,
    appLifecycle: any AppLifecycle,
    playback: (any PlaybackSyncing)?,
    localSessionUploadDrain: (@Sendable () async -> Void)?,
    recentEpisodes: RecentEpisodeRefreshCoordinator?,
    podcastProgressHydration: PodcastProgressHydrationCoordinator?,
    metadataBackfill: ItemMetadataBackfillCoordinator?,
    podcastAutoDownload: PodcastAutoDownloadCoordinator?,
    podcastAutoDownloadReaper: PodcastAutoDownloadReaper?,
    authorSeriesFilterDataRefresh: (@Sendable () async -> Void)?,
    libraryCollectionRefresh: (@Sendable () async -> Void)? = nil
  ) {
    self.database = database
    self.client = client
    self.diagnostics = diagnostics
    self.clock = clock
    self.randomSource = randomSource
    self.pageLimit = pageLimit
    self.appLifecycle = appLifecycle
    self.playback = playback
    self.localSessionUploadDrain = localSessionUploadDrain
    self.recentEpisodes = recentEpisodes
    self.podcastProgressHydration = podcastProgressHydration
    self.metadataBackfill = metadataBackfill
    self.podcastAutoDownload = podcastAutoDownload
    self.podcastAutoDownloadReaper = podcastAutoDownloadReaper
    self.authorSeriesFilterDataRefresh = authorSeriesFilterDataRefresh
    self.libraryCollectionRefresh = libraryCollectionRefresh
    accountDAO = AccountDAO(database: database)
    libraryDAO = LibraryDAO(database: database)
    syncRunDAO = SyncRunDAO(database: database)
    mediaProgressDAO = MediaProgressDAO(database: database)
    itemDAO = ItemDAO(database: database)
    sessionStore = (try? OutboxStore(database: database)).map { PlaybackSessionStore(database: database, outbox: $0) }
  }

  /// The one public construction path (mirrors `ABSClient.production(...)`). An actor `init`
  /// cannot let `self` escape into a `Task` before every stored property is initialized, so the
  /// foreground-transition subscriber (API-CONVENTIONS rule 20; ARCHITECTURE.md D15) is wired here
  /// against the constructed instance. The two long-lived task handles are installed back onto the
  /// actor so the app composition can shut this engine down before replacing it.
  public static func make(
    client: ABSClient,
    database: AppDatabase,
    diagnostics: any DiagnosticsRecording,
    appLifecycle: any AppLifecycle,
    playback: (any PlaybackSyncing)? = nil,
    clock: any SyncClock = SystemSyncClock(),
    randomSource: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
    pageLimit: Int = 100,
    localSessionUploadDrain: (@Sendable () async -> Void)? = nil,
    recentEpisodes: RecentEpisodeRefreshCoordinator? = nil,
    podcastProgressHydration: PodcastProgressHydrationCoordinator? = nil,
    metadataBackfill: ItemMetadataBackfillCoordinator? = nil,
    podcastAutoDownload: PodcastAutoDownloadCoordinator? = nil,
    podcastAutoDownloadReaper: PodcastAutoDownloadReaper? = nil,
    authorSeriesFilterDataRefresh: (@Sendable () async -> Void)? = nil,
    libraryCollectionRefresh: (@Sendable () async -> Void)? = nil
  ) -> SyncEngine {
    let engine = SyncEngine(
      client: client, database: database, diagnostics: diagnostics, clock: clock,
      randomSource: randomSource, pageLimit: pageLimit, appLifecycle: appLifecycle, playback: playback,
      localSessionUploadDrain: localSessionUploadDrain,
      recentEpisodes: recentEpisodes,
      podcastProgressHydration: podcastProgressHydration,
      metadataBackfill: metadataBackfill,
      podcastAutoDownload: podcastAutoDownload,
      podcastAutoDownloadReaper: podcastAutoDownloadReaper,
      authorSeriesFilterDataRefresh: authorSeriesFilterDataRefresh,
      libraryCollectionRefresh: libraryCollectionRefresh)
    let stream = appLifecycle.transitions
    let lifecycleSubscriptionTask = Task { [weak engine] in
      for await transition in stream {
        guard let engine else { return }
        await engine.handleLifecycleTransition(transition)
      }
    }
    // Launch drains are spawned rather than awaited inline for the same actor-initializer reason
    // the subscriber `Task` above is: a plain (non-static) actor `init` cannot let `self` escape
    // into a `Task` closure before every stored property is definitely initialized.
    let launchDrainTask = Task { [weak engine] in
      guard let engine else { return }
      await engine.triggerOrdinaryOutboxDrain()
      await engine.triggerLocalSessionUploadDrain()
    }
    Task { [weak engine] in
      await engine?.installSubscriptionTasks(
        lifecycleSubscriptionTask: lifecycleSubscriptionTask,
        launchDrainTask: launchDrainTask)
    }
    return engine
  }

  private func installSubscriptionTasks(
    lifecycleSubscriptionTask: Task<Void, Never>,
    launchDrainTask: Task<Void, Never>
  ) {
    guard isShutdown == false else {
      lifecycleSubscriptionTask.cancel()
      launchDrainTask.cancel()
      return
    }
    self.lifecycleSubscriptionTask = lifecycleSubscriptionTask
    self.launchDrainTask = launchDrainTask
  }

  /// Cancels every task the engine owns, including the traversal in flight, and returns once that
  /// traversal has ended. Account removal awaits this before purging or wiping credentials. Safe
  /// to call repeatedly (each call waits for the traversal it finds); the shutdown flag also
  /// rejects a lifecycle event racing cancellation after the stream yields it.
  ///
  /// Cancellation is the only bound (no timer): the traversal checks for it at each page boundary
  /// and before each ancillary hand-off.
  public func shutdown() async {
    if isShutdown == false {
      isShutdown = true
      pendingRefreshReason = nil
      lastCompletedTraversalAtByLibraryRowId.removeAll()
      lifecycleSubscriptionTask?.cancel()
      launchDrainTask?.cancel()
      lifecycleSubscriptionTask = nil
      launchDrainTask = nil
    }
    guard let currentRefresh else { return }
    currentRefresh.cancel()
    _ = await currentRefresh.value
  }

  /// Whether the traversal running on the current task must stop at its next boundary.
  var isTraversalStopped: Bool { isShutdown || Task.isCancelled }

  func scheduleBackoff(
    current: ABSApi.BackoffPolicy?, at now: Date
  ) -> (policy: ABSApi.BackoffPolicy, nextAttemptAllowedAt: Date) {
    var policy = current ?? ABSApi.BackoffPolicy()
    let delay = policy.nextDelay(now: now, randomUnit: randomSource())
    return (policy, now.addingTimeInterval(delay))
  }
}
