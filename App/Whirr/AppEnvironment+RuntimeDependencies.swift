import ABSApi
import AppModel
import Foundation
import Persistence
import PodcastFeeds
import SyncEngine

extension AppEnvironment {
  /// The authenticated runtime graph's `AppDependencies`, the counterpart of
  /// `makeSetupDependencies`/`makeRemovalDependencies`. Every service is composed by the caller;
  /// this only routes them into their slots.
  ///
  /// Unlike those two graphs, this one builds through the full `init` rather than
  /// `AppDependencies.platform`: every runtime-owned slot is non-defaulted, so a live service
  /// added or dropped here is a compile error rather than a silent no-op.
  @MainActor
  static func makeRuntimeDependencies(
    database: AppDatabase,
    accountDAO: AccountDAO,
    hardware: PlaybackHardware,
    lifecycle: ScenePhaseAppLifecycle,
    diagnosticsStore: DiagnosticsStore,
    networkConditions: NetworkConditionsReducer,
    accountLifecycle: AccountLifecycleService,
    syncEngine: SyncEngine,
    libraryReading: DefaultLibraryReading,
    removalIsPending: Bool,
    podcastServices: PodcastBackgroundRefreshHardware.SharedServices,
    playback: PlaybackComposition,
    libraryCache: LibraryCacheComposition,
    downloadAutomation: DownloadAutomationComposition,
    storageReading: any StorageReading,
    downloadFileStore: DownloadFileStore,
    downloadCoordinator: DownloadCoordinator,
    handDownloadIntents: any DownloadIntents,
    downloadPreferences: any DownloadPreferences,
    resolutionCenter: ResolutionCenter,
    extrasAccess: ItemDetailExtrasService,
    historyAccess: ListeningHistoryCoordinator,
    listeningStatsAccess: ListeningStatsCoordinator,
    ebookDelivery: EbookDeliveryService,
    rssPodcastReading: RSSPodcastReading,
    podcastShowRefresh: PodcastRefreshCoordinator,
    nativePodcastSubscriptions: NativePodcastSubscriptionsPreference,
    notificationIntent: PodcastNotificationPreference,
    notificationLifecycle: RSSNotificationLifecycleCoordinator,
    itemPlaybackSettingsAccess: any (ItemPlaybackSettingsReading & ItemPlaybackSettingsWriting),
    podcastSettingsAccess: any (PodcastSettingsReading & PodcastSettingsWriting),
    trimSilencesShowSettings: RoutingTrimSilencesShowSettingsAccess?,
    nativeEpisodeServerSaveStatusReading: any NativeEpisodeServerSaveStatusReading,
    nativeEpisodeIDResolving: PersistenceNativeEpisodeIDResolver,
    authorSeriesService: AuthorSeriesService,
    libraryCollections: LibraryCollectionsAccess,
    serverAccountReading: ServerAccountReadingService,
    librarySelectionStore: LibrarySelectionStore,
    feedCredentialStore: KeychainFeedCredentialStore
  ) -> AppDependencies {
    let playbackSyncing = playback.playbackSyncing
    let itemProgressCoordinator = playback.itemProgressCoordinator
    let rssEpisodeStore = playback.rssEpisodeStore
    let requestFinishedDownloadDeletion = playback.requestFinishedDownloadDeletion
    let artworkCacheAccess = libraryCache.access
    let listeningQueueReading = downloadAutomation.listeningQueueReading
    let listeningQueueStoring = downloadAutomation.listeningQueueStoring
    let savedShelfStoring = downloadAutomation.savedShelfStoring
    let savedShelfReading = downloadAutomation.savedShelfReading
    let recentSearchStore = downloadAutomation.recentSearchStore
    let podcastShowOrdering = downloadAutomation.podcastShowOrdering

    let rssFeedStore = RSSFeedStore(database: database)
    return AppDependencies(
      account: accountLifecycle,
      sync: syncEngine,
      library: libraryReading,
      player: hardware.player,
      playbackSync: playbackSyncing,
      reader: ReadiumEPUBRenderer(),
      networkConditions: networkConditions,
      appLifecycle: lifecycle,
      diagnostics: diagnosticsStore,
      isLibrarySelectionPending: { (try? accountDAO.fetch())?.librarySelectionMode == .pending },
      hasConfiguredIncludedLibrary: {
        guard let account = try? accountDAO.fetch(), account.librarySelectionMode != .pending,
          let accountID = account.id
        else { return false }
        return ((try? LibraryDAO(database: database).fetchIncluded(accountId: accountID)) ?? []).isEmpty == false
      },
      // Always false on this branch (a pending removal returns early from `init` into the
      // removal-only composition), but passed explicitly rather than left to the parameter
      // default, so the gate `RootModel.init` consults is visibly wired on every path.
      isRemovalPendingSynchronously: { removalIsPending },
      requestReachabilityProbe: {
        Task { await podcastServices.serverReachabilityMonitor.triggerDetectionProbe() }
      },
      downloadReading: DefaultDownloadReading(database: database),
      storageReading: storageReading,
      rssDownloadsReading: DefaultRSSDownloadsReading(database: database),
      deviceStorageCapacityReading: FileSystemDeviceStorageCapacityReader(
        rootURL: downloadFileStore.rootURL),
      downloadIntents: handDownloadIntents,
      itemProgressIntents: itemProgressCoordinator,
      downloadPreferences: downloadPreferences,
      artworkCacheAccess: artworkCacheAccess,
      resolutionCenterAccess: resolutionCenter,
      extrasAccess: extrasAccess,
      historyAccess: historyAccess,
      listeningStatsAccess: listeningStatsAccess,
      audioBookmarkIntents: playback.audioBookmarkCoordinator,
      // `HomeModel`'s three-section read boundary: a `ValueObservation`-backed stream against this
      // same `database`, like `DefaultDownloadReading`/`DefaultStorageReading` above, so it needs
      // no launch-time kickoff beyond construction.
      homeReading: DefaultHomeReading(database: database),
      nativeLatestPodcastEpisodesReading: RSSLatestPodcastEpisodesReading(database: database),
      // Composed only here, in the runtime graph: the RSS tables outlive an account, but the
      // setup and account-removal graphs must keep the no-op so a signed-out shell cannot open
      // an observation against them.
      nativeContinueListeningReading: RSSContinueListeningReading(database: database),
      // One observation projects the newest account or device-owned marker. Writes route by typed
      // identity so a native start never attempts to resolve an account-owned `item` row.
      playbackBookmarkStoring: RoutingPlaybackBookmarkStoring(
        abs: DefaultPlaybackBookmarkStoring(database: database),
        rss: RSSPlaybackBookmarkStore(database: database),
        reads: MergedPlaybackBookmarkReading(database: database)),
      podcastReading: RoutingPodcastReading(
        abs: DefaultPodcastReading(database: database),
        rss: rssPodcastReading),
      podcastRefreshing: RoutingPodcastRefreshing(
        abs: podcastShowRefresh,
        rss: NativePodcastSubscriptionsGatedRefreshing(
          child: podcastServices.rssPodcastRefreshing,
          reading: nativePodcastSubscriptions)),
      rssFeedRefreshCoordinator: podcastServices.rssFeedRefreshCoordinator,
      makePodcastEpisodeIntents: { playback in
        PlaybackPodcastEpisodeIntents(
          playback: playback,
          queue: listeningQueueStoring,
          downloadIntents: handDownloadIntents,
          progress: RoutingPodcastEpisodeProgressBackend(
            abs: ABSEpisodeProgressBackend(progressIntents: itemProgressCoordinator),
            rss: RSSEpisodeProgressBackend(
              episodeStore: rssEpisodeStore,
              stateStore: RSSEpisodeStateStore(database: database),
              // The explicit and bulk finish routes share the ABS intents' cleanup: same
              // preference, same medium-aware action, applied after the durable finish.
              downloadPreferences: downloadPreferences,
              requestFinishedDownloadDeletion: requestFinishedDownloadDeletion)),
          savedShelf: savedShelfStoring)
      },
      // Device-owned like the RSS tables; only the runtime graph plays, so only it skips ads.
      skipRanges: {
        #if DEBUG
          // Armed for one launch only: the transcript trigger watches which file is loaded.
          TranscriptDebugTrigger.observing(AdSkipComposition.coordinator)
        #else
          AdSkipComposition.coordinator
        #endif
      }(),
      // Device-owned, so the figure survives logout and an account switch.
      timeSaved: TimeSavedComposition.store,
      // Device-owned analysis like ad skip; the account's own show settings join the RSS ones.
      trim: trimSilencesShowSettings.flatMap {
        PauseTrimComposition.playbackDependencies(engine: hardware.engine, showSettings: $0)
      },
      playbackContinuation: playback.continuation,
      smartListRun: playback.smartListRun,
      listeningQueueReading: listeningQueueReading,
      listeningQueueStoring: listeningQueueStoring,
      savedShelfStoring: savedShelfStoring,
      savedShelfReading: savedShelfReading,
      // The per-title speed store and the app-wide default it resolves against. The default is
      // the same `UserDefaults` key `PlayerController` reads at process start: one shared value,
      // not a second copy that could disagree with the restored rate.
      itemPlaybackSettingsReading: itemPlaybackSettingsAccess,
      itemPlaybackSettingsWriting: itemPlaybackSettingsAccess,
      playbackPreferences: UserDefaultsPlaybackPreferences(),
      // The real `PodcastSettingsStore` built in `init` (shared with `sharedServices`'s own
      // `podcastAutoDownload` construction) rather than the `NoOp` defaults.
      podcastSettingsReading: podcastSettingsAccess,
      podcastSettingsWriting: podcastSettingsAccess,
      nativePodcastSettingsAccess: NativePodcastSettingsStore(database: database),
      // The account-scoped ordering store built in `init`. The setup-only graph never supplies
      // this slot, so it keeps `NoOpPodcastShowOrdering` and opens no observation over
      // account-owned tables before there is an account.
      podcastShowOrdering: podcastShowOrdering,
      carPlayBrowseSources: downloadAutomation.carPlayBrowseSources,
      // The real cross-library FTS5 read, account-scoped recents constructed in `init`, and the
      // live `/authors|series` fetch: the composition's last three no-op-defaulted
      // `AppDependencies` slots.
      searchReading: DefaultSearchReading(database: database),
      recentSearchStore: recentSearchStore,
      authorSeriesReading: authorSeriesService,
      libraryCollections: libraryCollections,
      serverAccountReading: serverAccountReading,
      librarySelectionReading: librarySelectionStore,
      nativePodcastSubscriptionsReading: nativePodcastSubscriptions,
      accountIdentityReading: DefaultAccountIdentityReading(database: database),
      nativePodcastSubscriptionsWriting: NotificationDisarmingNativePodcastSubscriptions(
        writing: nativePodcastSubscriptions, notifications: notificationLifecycle),
      nativeEpisodeServerSaving: podcastServices.nativeEpisodeServerSaving,
      nativeEpisodeServerSaveBatchSaving: podcastServices.nativeEpisodeServerSaveBatchSaving,
      nativeEpisodeServerSaveRecovering: podcastServices.nativeEpisodeServerSaveRecovering,
      nativeEpisodeServerSaveStatusReading: nativeEpisodeServerSaveStatusReading,
      nativeEpisodeIDResolving: nativeEpisodeIDResolving,
      serverPodcastMutationCapabilityReading:
        podcastServices.serverPodcastMutationCapabilityReading,
      serverPodcastAutomationSettingsWriting:
        podcastServices.serverPodcastAutomationSettingsWriting,
      ebookDelivery: ebookDelivery,
      notificationIntentReading: notificationIntent,
      notificationIntentWriting: notificationIntent,
      localNotificationAuthorizer: PodcastLocalNotificationCenter.shared,
      rssNotificationLifecycle: notificationLifecycle,
      nativePodcastShowsReading: rssPodcastReading,
      rssEpisodeArtworkReading: DefaultRSSEpisodeArtworkReading(database: database),
      nativeFeedRecoveryReading: rssFeedStore,
      librarySelectionWriting: librarySelectionStore,
      nativeFeedFollowing: RSSFeedFollowing(
        store: rssFeedStore, credentialStore: feedCredentialStore),
      nativeFeedManaging: RSSFeedManaging(
        store: rssFeedStore, credentialStore: feedCredentialStore,
        credentialUpdateHandler: downloadCoordinator,
        refreshing: podcastServices.rssPodcastRefreshing,
        notificationLifecycle: notificationLifecycle,
        downloadFileCleaner: downloadCoordinator),
      nativeSubscriptionOPMLExporter: RSSSubscriptionOPMLExporter(
        store: RSSFeedStore(database: database)),
      nativePodcastShowOrdering: RSSShowOrdering(store: RSSFeedStore(database: database))
    )
  }
}
