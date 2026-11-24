import ABSApi
import AppModel
import BackgroundTasks
import Foundation
import Persistence
import SyncEngine

extension PodcastBackgroundRefreshHardware {
  struct SharedServices: Sendable {
    let client: ABSClient
    let nativeEpisodeServerSaving: any NativeEpisodeServerSaving
    let nativeEpisodeServerSaveBatchSaving: any NativeEpisodeServerSaveBatchSaving
    let nativeEpisodeServerSaveRecovering: any NativeEpisodeServerSaveRecovering
    let serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading
    /// ADR 0017: writes a server show's automatic-download settings and confirms them through
    /// `showRefresh`, the same coordinator the show screen refreshes with.
    let serverPodcastAutomationSettingsWriting: any ServerPodcastAutomationSettingsWriting
    let showRefresh: PodcastRefreshCoordinator
    /// The account-lifetime `DownloadCoordinator`, shared by the foreground `AppEnvironment` graph
    /// and this file's cold-launch-safe background composition. A second instance would race the
    /// first over the two-transfer cap and session subscription (see `DownloadCoordinator.make`).
    let downloadCoordinator: DownloadCoordinator
    /// Exposed alongside `downloadCoordinator` because `AppEnvironment` also builds
    /// `PlaybackSessionCoordinator`/`ResolutionCenter`/`AccountRemovalCoordinator` directly against
    /// the store/file-store/preferences.
    let downloadStore: DownloadStore
    let downloadFileStore: DownloadFileStore
    let rssDownloadStore: RSSDownloadStore
    let rssFileStore: RSSFileStore
    let rssPodcastRefreshing: RSSPodcastRefreshing
    /// The production trigger surface wraps the bounded feed pass with one shared RSS automatic
    /// selection/reap sequence. Foreground and background callers therefore use identical gates.
    let rssFeedRefreshCoordinator: RSSRefreshAutomationCoordinator
    let rssActivePlaybackTracker: RSSActivePlaybackTracker
    let downloadPreferences: any DownloadPreferences
    /// `nil` only when no account id was supplied (the runtime graph always has one). Mirrors the
    /// other "no-op unless an account is known" optionals in this composition.
    let podcastAutoDownload: PodcastAutoDownloadCoordinator?
    let podcastAutoDownloadReaper: PodcastAutoDownloadReaper?
    /// Reaps device-owned (RSS) auto-downloads. The account-owned reaper above only sees server
    /// rows, so finishing an RSS episode must trigger this one.
    let rssPodcastAutoDownloadReaper: PodcastAutoDownloadReaper?
    /// Per-list Smart List auto-download. Shared by the foreground triggers and the
    /// background refresh pass so concurrent callers join one pass.
    let smartListDownloadReconciler: SmartListDownloadReconciler
    let smartListDownloadStore: SmartListDownloadStore
    /// The account-lifetime auth-recovery bridge/model, cached under this key so an
    /// `AppEnvironment` rebuild or same-process background wake reuses the same instance.
    let authRecoveryEventBridge: AuthRecoveryEventBridge
    /// The account-lifetime reachability monitor and its AppModel projection, cached under the same
    /// server+account key as the client so foreground and background composition never publish from
    /// competing monitors.
    let serverReachabilityMonitor: ServerReachabilityMonitor
    let serverReachabilityObserver: ServerReachabilityMonitorAdapter
    let connectivityModel: ConnectivityModel
  }

  /// Keeps the API request gate, download queue and auto-download coordinator/reaper process-wide,
  /// so a background launch that becomes foreground (or vice versa) joins the same in-flight work.
  /// `DownloadCoordinator` is composed here because the auto-download coordinator and reaper need
  /// it as their planner/low-disk-gate/purge boundary, and `handle()` and `AppEnvironment.init`
  /// must resolve to the same instance.
  ///
  /// Composed in construction phases below, in this order, because later phases take earlier ones
  /// as parameters: connectivity and client, server-save seams, downloads, podcast refresh. The
  /// order is load-bearing (see each phase), so a phase's body must not be reordered.
  @MainActor
  static func sharedServices(
    key: String,
    server: ABSServerConfig,
    tokenAccount: TokenAccount?,
    tokenStore: KeychainTokenStore,
    customHeaderStore: any CustomHeaderStoring = InMemoryCustomHeaderStore(),
    feedCredentialStore: any FeedCredentialStoring = InMemoryFeedCredentialStore(),
    database: AppDatabase,
    diagnostics: DiagnosticsStore,
    accountLifecycle: any AccountLifecycle,
    appLifecycle: any AppLifecycle,
    networkConditions: any NetworkConditions,
    podcastSettingsReading: any PodcastSettingsReading,
    nativePodcastSubscriptions: any NativePodcastSubscriptionsReading =
      NoOpNativePodcastSubscriptionsReading(),
    notificationIntent: any RSSNotificationIntentReading = DisabledRSSNotificationIntent(),
    notificationScheduler: any RSSLocalNotificationScheduling =
      NoOpRSSLocalNotificationScheduler(),
    accountId: Int64?,
    applicationSupportDirectory: URL? = nil,
    clearCachedArtwork: @escaping @Sendable () async -> Void = {}
  ) -> SharedServices {
    if let cachedServices, cachedServices.key == key {
      return cachedServices.value
    }

    let connectivity = makeConnectivity(
      server: server,
      tokenAccount: tokenAccount,
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore,
      clearCachedArtwork: clearCachedArtwork,
      database: database,
      accountLifecycle: accountLifecycle,
      appLifecycle: appLifecycle,
      diagnostics: diagnostics,
      accountId: accountId)
    let serverSave = makeServerSave(
      accountId: accountId,
      client: connectivity.client,
      database: database,
      feedCredentialStore: feedCredentialStore,
      nativePodcastSubscriptions: nativePodcastSubscriptions)
    let downloads = makeDownloads(
      client: connectivity.client,
      database: database,
      applicationSupportDirectory: applicationSupportDirectory,
      networkConditions: networkConditions,
      diagnostics: diagnostics,
      feedCredentialStore: feedCredentialStore,
      nativePodcastSubscriptions: nativePodcastSubscriptions,
      notificationIntent: notificationIntent,
      notificationScheduler: notificationScheduler)
    let podcastRefresh = makePodcastRefresh(
      accountId: accountId,
      database: database,
      client: connectivity.client,
      downloadCoordinator: downloads.downloadCoordinator,
      rssActivePlaybackTracker: downloads.rssActivePlaybackTracker,
      rssFeedRefreshCoreCoordinator: downloads.rssFeedRefreshCoreCoordinator,
      serverPodcastMutationCapabilityReading: serverSave.serverPodcastMutationCapabilityReading,
      accountLifecycle: accountLifecycle,
      networkConditions: networkConditions,
      podcastSettingsReading: podcastSettingsReading,
      nativePodcastSubscriptions: nativePodcastSubscriptions,
      diagnostics: diagnostics)

    let value = SharedServices(
      client: connectivity.client,
      nativeEpisodeServerSaving: serverSave.nativeEpisodeServerSaving,
      nativeEpisodeServerSaveBatchSaving: serverSave.nativeEpisodeServerSaveBatchSaving,
      nativeEpisodeServerSaveRecovering: serverSave.nativeEpisodeServerSaveRecovering,
      serverPodcastMutationCapabilityReading: serverSave.serverPodcastMutationCapabilityReading,
      serverPodcastAutomationSettingsWriting: podcastRefresh.serverPodcastAutomationSettingsWriting,
      showRefresh: podcastRefresh.showRefresh,
      downloadCoordinator: downloads.downloadCoordinator,
      downloadStore: downloads.downloadStore,
      downloadFileStore: downloads.downloadFileStore,
      rssDownloadStore: downloads.rssDownloadStore,
      rssFileStore: downloads.rssFileStore,
      rssPodcastRefreshing: downloads.rssPodcastRefreshing,
      rssFeedRefreshCoordinator: podcastRefresh.rssFeedRefreshCoordinator,
      rssActivePlaybackTracker: downloads.rssActivePlaybackTracker,
      downloadPreferences: downloads.downloadPreferences,
      podcastAutoDownload: podcastRefresh.podcastAutoDownload,
      podcastAutoDownloadReaper: podcastRefresh.podcastAutoDownloadReaper,
      rssPodcastAutoDownloadReaper: podcastRefresh.rssPodcastAutoDownloadReaper,
      smartListDownloadReconciler: podcastRefresh.smartListDownloadReconciler,
      smartListDownloadStore: podcastRefresh.smartListDownloadStore,
      authRecoveryEventBridge: connectivity.authRecoveryEventBridge,
      serverReachabilityMonitor: connectivity.monitor,
      serverReachabilityObserver: connectivity.observer,
      connectivityModel: connectivity.connectivityModel)
    cachedServices = (key, value)
    return value
  }

  /// The reachability monitor, the client bound to it, and the account-lifetime auth-recovery
  /// bridge. Order: the monitor and bridge must predate the client.
  @MainActor
  private static func makeConnectivity(
    server: ABSServerConfig,
    tokenAccount: TokenAccount?,
    tokenStore: KeychainTokenStore,
    customHeaderStore: any CustomHeaderStoring,
    clearCachedArtwork: @escaping @Sendable () async -> Void,
    database: AppDatabase,
    accountLifecycle: any AccountLifecycle,
    appLifecycle: any AppLifecycle,
    diagnostics: DiagnosticsStore,
    accountId: Int64?
  ) -> (
    client: ABSClient,
    authRecoveryEventBridge: AuthRecoveryEventBridge,
    monitor: ServerReachabilityMonitor,
    observer: ServerReachabilityMonitorAdapter,
    connectivityModel: ConnectivityModel
  ) {
    // The monitor must predate the client because the client receives the monitor adapter,
    // while the monitor's explicit `/status` probe needs that same client. This late-bound probe
    // keeps the construction order acyclic and returns an unanswered result if a cold-launch
    // trigger arrives before the binding below.
    let serverStatusProbe = LateBoundServerStatusProbe()
    let serverReachabilityMonitor = ServerReachabilityMonitor(
      path: RealPathObserving(),
      probe: serverStatusProbe,
      appLifecycle: appLifecycle,
      clock: SystemSyncClock())
    let serverReachabilityObserver = ServerReachabilityMonitorAdapter(
      monitor: serverReachabilityMonitor)
    // Constructed before the client, which uses it as its auth-event observer (see
    // `AuthRecoveryEventBridge` for the construction-order knot).
    let authRecoveryEventBridge = AuthRecoveryEventBridge(
      accountLifecycle: accountLifecycle,
      diagnostics: diagnostics,
      accountId: accountId)
    // Bound to the signed-in account: this bundle can outlive it in anything that retains it,
    // and an unbound client would then authenticate as the next account against this server.
    let client = ABSClient.production(
      server: server,
      account: tokenAccount,
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore,
      clearCachedArtwork: clearCachedArtwork,
      serverDateObserving: AccountServerTimeObserver(database: database),
      authEventObserving: authRecoveryEventBridge,
      serverReachabilityObserving: serverReachabilityObserver)
    serverStatusProbe.setClient(client)
    let connectivityModel = ConnectivityModel(monitor: serverReachabilityMonitor)
    return (
      client, authRecoveryEventBridge, serverReachabilityMonitor, serverReachabilityObserver,
      connectivityModel
    )
  }

  /// The server-save seams, all four pointing at one coordinator. Inert without an account.
  @MainActor
  private static func makeServerSave(
    accountId: Int64?,
    client: ABSClient,
    database: AppDatabase,
    feedCredentialStore: any FeedCredentialStoring,
    nativePodcastSubscriptions: any NativePodcastSubscriptionsReading
  ) -> (
    serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading,
    nativeEpisodeServerSaving: any NativeEpisodeServerSaving,
    nativeEpisodeServerSaveBatchSaving: any NativeEpisodeServerSaveBatchSaving,
    nativeEpisodeServerSaveRecovering: any NativeEpisodeServerSaveRecovering
  ) {
    // This coordinator is account-lifetime state, so it belongs in the same server+account cache
    // as the client and the other podcast coordinators. A runtime composition without an account
    // stays inert even when tests request the runtime mode defensively.
    if accountId != nil {
      let capabilityReader = ServerPodcastMutationCapabilityService(
        client: client, database: database)
      let coordinator = NativeEpisodeServerSaveCoordinator(
        accountReader: PersistenceNativeEpisodeServerSaveAccountReader(database: database),
        capabilityReader: capabilityReader,
        commandReader: PersistenceNativeEpisodeServerSaveCommandReader(
          database: database,
          feedCredentialStore: feedCredentialStore,
          nativeSubscriptions: nativePodcastSubscriptions),
        destinationResolver: ServerPodcastDestinationResolver(client: client),
        podcastWriter: client,
        itemDetailReader: client,
        attemptStore: NativeEpisodeServerSaveAttemptStore(database: database),
        nativeSubscriptions: nativePodcastSubscriptions)
      return (capabilityReader, coordinator, coordinator, coordinator)
    }
    return (
      NoOpServerPodcastMutationCapabilityReading(), NoOpNativeEpisodeServerSaving(),
      NoOpNativeEpisodeServerSaveBatchSaving(), NoOpNativeEpisodeServerSaveRecovering()
    )
  }

  /// The download stores and the account-lifetime coordinator, which starts its launch reconcile
  /// before the auto-download coordinators below take it as their boundary.
  @MainActor
  private static func makeDownloads(
    client: ABSClient,
    database: AppDatabase,
    applicationSupportDirectory: URL?,
    networkConditions: any NetworkConditions,
    diagnostics: DiagnosticsStore,
    feedCredentialStore: any FeedCredentialStoring,
    nativePodcastSubscriptions: any NativePodcastSubscriptionsReading,
    notificationIntent: any RSSNotificationIntentReading,
    notificationScheduler: any RSSLocalNotificationScheduling
  ) -> (
    downloadStore: DownloadStore,
    downloadFileStore: DownloadFileStore,
    rssDownloadStore: RSSDownloadStore,
    rssFileStore: RSSFileStore,
    downloadPreferences: any DownloadPreferences,
    rssActivePlaybackTracker: RSSActivePlaybackTracker,
    rssPodcastRefreshing: RSSPodcastRefreshing,
    rssFeedRefreshCoreCoordinator: RSSFeedRefreshCoordinator,
    downloadCoordinator: DownloadCoordinator
  ) {
    let stores = makeDownloadStores(
      database: database, applicationSupportDirectory: applicationSupportDirectory)
    let rss = makeRSSRefresh(
      database: database,
      feedCredentialStore: feedCredentialStore,
      networkConditions: networkConditions,
      nativePodcastSubscriptions: nativePodcastSubscriptions,
      notificationIntent: notificationIntent,
      notificationScheduler: notificationScheduler)
    let freeSpaceReporting = FileSystemFreeSpaceReporting(rootURL: stores.rootURL)
    let downloadCoordinator = DownloadCoordinator.make(
      client: client,
      database: database,
      downloadStore: stores.downloadStore,
      downloadFileStore: stores.downloadFileStore,
      backgroundTransferring: BackgroundDownloadHardware.transferring,
      downloadPreferences: stores.downloadPreferences,
      networkConditions: networkConditions,
      diagnostics: diagnostics,
      freeSpaceReporting: freeSpaceReporting,
      rssDownloadStore: stores.rssDownloadStore,
      rssFileStore: stores.rssFileStore,
      feedCredentialStore: feedCredentialStore)

    // `Task.detached`, not `Task`: this runs from `AppEnvironment.init` (`@MainActor`) as well as
    // from background composition, and the sweep/reconciliation must not inherit main-actor
    // isolation. `reconcileAfterLaunch` owns the integrity sweep, which serialises it against
    // transfer completion, deletion and purge.
    Task.detached(priority: .utility) {
      await downloadCoordinator.reconcileAfterLaunch()
    }

    return (
      stores.downloadStore, stores.downloadFileStore, stores.rssDownloadStore, stores.rssFileStore,
      stores.downloadPreferences, rss.tracker, rss.refreshing, rss.coreCoordinator,
      downloadCoordinator
    )
  }

  /// The two download spines and their preferences, all rooted in Application Support.
  @MainActor
  private static func makeDownloadStores(
    database: AppDatabase, applicationSupportDirectory: URL?
  ) -> (
    rootURL: URL,
    downloadStore: DownloadStore,
    downloadFileStore: DownloadFileStore,
    rssDownloadStore: RSSDownloadStore,
    rssFileStore: RSSFileStore,
    downloadPreferences: any DownloadPreferences
  ) {
    // Application Support, never Caches (SECURITY.md). `applicationSupportDirectory` stays a test
    // seam threaded through from `AppEnvironment.init`.
    let downloadsRootURL = DownloadLocations.root(
      applicationSupportDirectory: applicationSupportDirectory
        ?? AppEnvironment.applicationSupportDirectory())
    let downloadStore = try! DownloadStore(database: database)
    let downloadFileStore = try! DownloadFileStore(
      rootURL: downloadsRootURL, fileAttributes: POSIXFileAttributeApplier(), downloadStore: downloadStore)
    let rssDownloadStore = try! RSSDownloadStore(database: database)
    let rssFileStore = try! RSSFileStore(
      rootURL: downloadsRootURL, fileAttributes: POSIXFileAttributeApplier(),
      downloadStore: rssDownloadStore)
    let downloadPreferences = UserDefaultsDownloadPreferences()
    return (
      downloadsRootURL, downloadStore, downloadFileStore, rssDownloadStore, rssFileStore,
      downloadPreferences
    )
  }

  /// The RSS feed refresh spine: the playback tracker its retention sweep consults, the refreshing
  /// service, and the coordinator that runs the pass.
  @MainActor
  private static func makeRSSRefresh(
    database: AppDatabase,
    feedCredentialStore: any FeedCredentialStoring,
    networkConditions: any NetworkConditions,
    nativePodcastSubscriptions: any NativePodcastSubscriptionsReading,
    notificationIntent: any RSSNotificationIntentReading,
    notificationScheduler: any RSSLocalNotificationScheduling
  ) -> (
    tracker: RSSActivePlaybackTracker,
    refreshing: RSSPodcastRefreshing,
    coreCoordinator: RSSFeedRefreshCoordinator
  ) {
    let rssFeedStore = RSSFeedStore(database: database)
    // Constructed before the refresh store so the retention sweep can consult it. The sweep
    // deletes episode rows, and an episode whose playback has just started has no listening
    // history yet to protect it. The process-wide instance, because podcast cloud sync consults
    // the same marker to keep the playing episode's listening ahead of a remote reset.
    let rssActivePlaybackTracker = PodcastCloudSyncComposition.activePlaybackTracker
    let rssPodcastRefreshing = RSSPodcastRefreshing(
      feedStore: rssFeedStore,
      episodeStore: RSSEpisodeStore(
        database: database,
        activeRSSExclusionProvider: { [rssActivePlaybackTracker] in
          rssActivePlaybackTracker.activeEpisodeRowIDs
        }),
      credentialStore: feedCredentialStore,
      recoveryReading: rssFeedStore,
      cloudRefreshObserver: PodcastCloudSyncComposition.refreshRelay)
    let rssFeedRefreshCoreCoordinator = RSSFeedRefreshCoordinator(
      candidates: rssFeedStore,
      refreshing: rssPodcastRefreshing,
      networkConditions: networkConditions,
      nativeSubscriptions: nativePodcastSubscriptions,
      notificationIntent: notificationIntent,
      backgroundCompletion: RSSNotificationDeliveryCoordinator(
        ledger: RSSNotificationLedgerStore(database: database), intent: notificationIntent,
        scheduler: notificationScheduler))
    return (rssActivePlaybackTracker, rssPodcastRefreshing, rssFeedRefreshCoreCoordinator)
  }

  /// The podcast auto-download coordinators, the Smart List reconciler and the show refresh the
  /// automation writer confirms through. Every seam here takes the download boundary built above.
  @MainActor
  private static func makePodcastRefresh(
    accountId: Int64?,
    database: AppDatabase,
    client: ABSClient,
    downloadCoordinator: DownloadCoordinator,
    rssActivePlaybackTracker: RSSActivePlaybackTracker,
    rssFeedRefreshCoreCoordinator: RSSFeedRefreshCoordinator,
    serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading,
    accountLifecycle: any AccountLifecycle,
    networkConditions: any NetworkConditions,
    podcastSettingsReading: any PodcastSettingsReading,
    nativePodcastSubscriptions: any NativePodcastSubscriptionsReading,
    diagnostics: DiagnosticsStore
  ) -> (
    podcastAutoDownload: PodcastAutoDownloadCoordinator?,
    podcastAutoDownloadReaper: PodcastAutoDownloadReaper?,
    rssPodcastAutoDownloadReaper: PodcastAutoDownloadReaper?,
    smartListDownloadReconciler: SmartListDownloadReconciler,
    smartListDownloadStore: SmartListDownloadStore,
    rssFeedRefreshCoordinator: RSSRefreshAutomationCoordinator,
    showRefresh: PodcastRefreshCoordinator,
    serverPodcastAutomationSettingsWriting: any ServerPodcastAutomationSettingsWriting
  ) {
    let autoDownload = makePodcastAutoDownload(
      accountId: accountId,
      database: database,
      downloadCoordinator: downloadCoordinator,
      rssActivePlaybackTracker: rssActivePlaybackTracker,
      accountLifecycle: accountLifecycle,
      networkConditions: networkConditions,
      podcastSettingsReading: podcastSettingsReading,
      diagnostics: diagnostics)
    let smartList = makeSmartListDownloads(
      accountId: accountId,
      database: database,
      downloadCoordinator: downloadCoordinator,
      rssActivePlaybackTracker: rssActivePlaybackTracker,
      networkConditions: networkConditions,
      podcastSettingsReading: podcastSettingsReading,
      nativePodcastSubscriptions: nativePodcastSubscriptions,
      diagnostics: diagnostics)
    let rssFeedRefreshCoordinator = RSSRefreshAutomationCoordinator(
      refresh: rssFeedRefreshCoreCoordinator,
      autoDownload: autoDownload.rssPodcastAutoDownload,
      reaper: autoDownload.rssPodcastAutoDownloadReaper,
      nativeSubscriptions: nativePodcastSubscriptions)
    let show = makeShowRefresh(
      accountId: accountId,
      database: database,
      client: client,
      podcastAutoDownload: autoDownload.podcastAutoDownload,
      podcastAutoDownloadReaper: autoDownload.podcastAutoDownloadReaper,
      serverPodcastMutationCapabilityReading: serverPodcastMutationCapabilityReading,
      diagnostics: diagnostics)
    return (
      autoDownload.podcastAutoDownload, autoDownload.podcastAutoDownloadReaper,
      autoDownload.rssPodcastAutoDownloadReaper, smartList.reconciler, smartList.store,
      rssFeedRefreshCoordinator, show.showRefresh, show.automationSettingsWriting
    )
  }

  /// The account-owned and device-owned auto-download coordinators and their reapers.
  @MainActor
  private static func makePodcastAutoDownload(
    accountId: Int64?,
    database: AppDatabase,
    downloadCoordinator: DownloadCoordinator,
    rssActivePlaybackTracker: RSSActivePlaybackTracker,
    accountLifecycle: any AccountLifecycle,
    networkConditions: any NetworkConditions,
    podcastSettingsReading: any PodcastSettingsReading,
    diagnostics: DiagnosticsStore
  ) -> (
    podcastAutoDownload: PodcastAutoDownloadCoordinator?,
    podcastAutoDownloadReaper: PodcastAutoDownloadReaper?,
    rssPodcastAutoDownload: PodcastAutoDownloadCoordinator?,
    rssPodcastAutoDownloadReaper: PodcastAutoDownloadReaper?
  ) {
    let podcastAutoDownload: PodcastAutoDownloadCoordinator?
    let podcastAutoDownloadReaper: PodcastAutoDownloadReaper?
    let rssPodcastAutoDownload: PodcastAutoDownloadCoordinator?
    let rssPodcastAutoDownloadReaper: PodcastAutoDownloadReaper?
    if let accountId {
      podcastAutoDownload = PodcastAutoDownloadCoordinator(
        selecting: PodcastAutoDownloadSelectionStore(database: database, accountId: accountId),
        planner: downloadCoordinator,
        accountLifecycle: accountLifecycle,
        networkConditions: networkConditions,
        podcastSettingsReading: podcastSettingsReading,
        lowDiskGating: downloadCoordinator,
        diagnostics: diagnostics,
        accountId: accountId)
      podcastAutoDownloadReaper = PodcastAutoDownloadReaper(
        reapCandidateProvider: PodcastAutoDownloadReapStore(database: database, accountId: accountId),
        purging: downloadCoordinator,
        diagnostics: diagnostics,
        accountId: accountId)
      rssPodcastAutoDownload = PodcastAutoDownloadCoordinator(
        selecting: RSSPodcastAutoDownloadSelectionStore(
          database: database, accountId: accountId),
        planner: downloadCoordinator,
        accountLifecycle: accountLifecycle,
        networkConditions: networkConditions,
        podcastSettingsReading: NativePodcastSettingsStore(database: database),
        lowDiskGating: downloadCoordinator,
        diagnostics: diagnostics,
        accountId: accountId)
      rssPodcastAutoDownloadReaper = PodcastAutoDownloadReaper(
        reapCandidateProvider: RSSPodcastAutoDownloadReapStore(
          database: database, accountId: accountId,
          activeEpisodeIDs: { rssActivePlaybackTracker.activeEpisodeRowIDs }),
        purging: downloadCoordinator,
        diagnostics: diagnostics,
        accountId: accountId)
    } else {
      podcastAutoDownload = nil
      podcastAutoDownloadReaper = nil
      rssPodcastAutoDownload = nil
      rssPodcastAutoDownloadReaper = nil
    }
    return (
      podcastAutoDownload, podcastAutoDownloadReaper, rssPodcastAutoDownload,
      rssPodcastAutoDownloadReaper
    )
  }

  /// Per-list Smart List auto-download: the store the reconciler claims through and the reconciler
  /// itself. Account-scoped claims: server episodes are requested under `accountId`, native ones
  /// carry none.
  @MainActor
  private static func makeSmartListDownloads(
    accountId: Int64?,
    database: AppDatabase,
    downloadCoordinator: DownloadCoordinator,
    rssActivePlaybackTracker: RSSActivePlaybackTracker,
    networkConditions: any NetworkConditions,
    podcastSettingsReading: any PodcastSettingsReading,
    nativePodcastSubscriptions: any NativePodcastSubscriptionsReading,
    diagnostics: DiagnosticsStore
  ) -> (store: SmartListDownloadStore, reconciler: SmartListDownloadReconciler) {
    // Native playback is judged by the process-wide tracker, as for eviction.
    let store = SmartListDownloadStore(
      database: database,
      nativeEnabled: { await nativePodcastSubscriptions.isEnabled() },
      activeNativeEpisodeIDs: { rssActivePlaybackTracker.activeEpisodeRowIDs })
    let reconciler = SmartListDownloadReconciler(
      accountID: accountId,
      store: store,
      requesting: downloadCoordinator,
      networkConditions: networkConditions,
      nativeSettings: NativePodcastSettingsStore(database: database),
      serverSettings: podcastSettingsReading,
      diagnostics: diagnostics)
    return (store, reconciler)
  }

  /// The show refresh both the show screen and the background pass use, and the automation writer
  /// that confirms a write through it.
  @MainActor
  private static func makeShowRefresh(
    accountId: Int64?,
    database: AppDatabase,
    client: ABSClient,
    podcastAutoDownload: PodcastAutoDownloadCoordinator?,
    podcastAutoDownloadReaper: PodcastAutoDownloadReaper?,
    serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading,
    diagnostics: DiagnosticsStore
  ) -> (showRefresh: PodcastRefreshCoordinator, automationSettingsWriting: any ServerPodcastAutomationSettingsWriting) {
    let showRefresh = PodcastRefreshCoordinator(
      database: database,
      client: client,
      persistence: PodcastRefreshStore(database: database),
      diagnostics: diagnostics,
      podcastAutoDownload: podcastAutoDownload,
      podcastAutoDownloadReaper: podcastAutoDownloadReaper)
    // ADR 0017: the same capability reader and refresh coordinator the show screen already uses,
    // so a write's confirming refresh also runs the device auto-download and reaper passes. Inert
    // without an account, like every other server-save seam above.
    let automationSettingsWriting: any ServerPodcastAutomationSettingsWriting
    if accountId != nil {
      automationSettingsWriting = ServerPodcastAutomationSettingsService(
        client: client,
        capabilityReader: serverPodcastMutationCapabilityReading,
        accountReader: PersistenceNativeEpisodeServerSaveAccountReader(database: database),
        refreshing: showRefresh)
    } else {
      automationSettingsWriting = NoOpServerPodcastAutomationSettingsWriting()
    }
    return (showRefresh, automationSettingsWriting)
  }
}
