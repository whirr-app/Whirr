import Persistence
import PlayerCore
import PodcastFeeds
import ReaderCore
import SyncEngine

/// Root composition point for every lower-layer boundary.
///
/// Holds protocols only. No concrete network, keychain, database, or AV type appears here or
/// anywhere above it, so the whole graph can be built from fakes on the macOS host
/// (ARCHITECTURE.md §1).
public struct AppDependencies: Sendable {
  public let account: any AccountLifecycle
  public let sync: any SyncCoordinating
  public let library: any LibraryReading
  public let player: any PlaybackControlling
  /// The `SyncEngine`-side playback boundary `PlaybackModel` drives. Separate from `sync`
  /// (library/search only). `PlaybackSessionCoordinator` is the real conformance, orchestrating
  /// `/play`/`/sync`/`/close`.
  public let playbackSync: any PlaybackSyncing
  /// `PlaybackModel.displayedItem`'s boundary onto `Persistence`'s `PlaybackBookmarkStoring`.
  /// AppModel may not import the concrete GRDB-backed conformance (ARCHITECTURE.md §2).
  /// Defaults to `NoOpPlaybackBookmarkStoring()`.
  public let playbackBookmarkStoring: any PlaybackBookmarkStoring
  public let reader: any EPUBRendering
  public let networkConditions: any NetworkConditions
  public let appLifecycle: any AppLifecycle
  public let diagnostics: any DiagnosticsRecording
  /// `ItemDownloadModel`'s per-item detailed status observation. Runtime-only: `platform`
  /// supplies the no-op for the setup and removal graphs; a fake graph names its own.
  public let downloadReading: any DownloadReading
  /// `StorageModel`'s purgeable-bytes observation. Runtime-only: `platform` supplies the no-op.
  public let storageReading: any StorageReading
  /// Device-owned RSS download groups for the Downloads screen. Kept separate from account-owned
  /// storage so logout can rebuild ABS services without dropping feed subscriptions or media.
  /// Runtime-only: `platform` supplies the empty list.
  public let rssDownloadsReading: any RSSDownloadsReading
  /// Optional device-capacity context for Downloads settings. `platform` reports an unavailable
  /// result for the setup and removal graphs rather than inventing a sentinel.
  public let deviceStorageCapacityReading: any DeviceStorageCapacityReading
  /// `ItemDownloadModel`/`StorageModel`'s download/purge intents, forwarded to SyncEngine's
  /// `DownloadCoordinator`. AppModel may not import the concrete actor (ARCHITECTURE.md §2).
  /// Runtime-only: `platform` supplies `NoOpDownloadIntents()`.
  public let downloadIntents: any DownloadIntents
  /// Native item context menus' reset/finished actions. The production conformance commits the
  /// local progress projection and durable outbox mutation atomically before requesting a drain.
  /// Runtime-only: `platform` supplies the no-op.
  public let itemProgressIntents: any ItemProgressIntents
  /// `SettingsModel`'s device-side download preferences. Runtime-only: `platform` supplies the
  /// no-op.
  public let downloadPreferences: any DownloadPreferences
  /// The Artwork Cache boundary used by `ArtworkCacheModel` and Settings › Downloads. Runtime-only:
  /// `platform` supplies `NoOpArtworkCacheAccess()`, a clean no-cache graph, until the runtime
  /// composition supplies the on-device cover-cache size and clear.
  public let artworkCacheAccess: any ArtworkCacheAccess
  /// `ResolutionCenterModel`'s enumeration/action boundary onto SyncEngine's `ResolutionCenter`.
  /// AppModel may not import the concrete actor (ARCHITECTURE.md §2). Runtime-only: `platform`
  /// supplies `NoOpResolutionCenterAccess()`.
  public let resolutionCenterAccess: any ResolutionCenterAccess
  /// `ItemDetailExtrasModel`'s series/narrator/chapters boundary onto SyncEngine's
  /// `ItemDetailExtrasService`. AppModel may not import the concrete actor (ARCHITECTURE.md §2).
  /// Runtime-only: `platform` supplies `NoOpItemDetailExtrasAccess()`.
  public let extrasAccess: any ItemDetailExtrasAccess
  /// `ItemHistoryModel`'s listening-history boundary onto SyncEngine's
  /// `ListeningHistoryCoordinator`. Runtime-only: `platform` supplies
  /// `NoOpListeningHistoryProviding()`.
  public let historyAccess: any ListeningHistoryProviding
  /// `ListeningStatsModel`'s boundary onto SyncEngine's `ListeningStatsCoordinator`. Runtime-only:
  /// `platform` supplies `NoOpListeningStatsProviding()`.
  public let listeningStatsAccess: any ListeningStatsProviding
  /// `AudioBookmarksModel`'s boundary onto SyncEngine's `AudioBookmarkCoordinator`. Runtime-only:
  /// `platform` supplies `NoOpAudioBookmarkIntents()`.
  public let audioBookmarkIntents: any AudioBookmarkIntents
  /// `HomeModel`'s three-section read boundary onto `Persistence`'s `HomeReading`. Runtime-only:
  /// `platform` supplies `NoOpHomeReading()`.
  public let homeReading: any HomeReading
  public let nativeLatestPodcastEpisodesReading: any NativeLatestPodcastEpisodesReading
  public let nativeContinueListeningReading: any NativeContinueListeningReading
  public let podcastReading: any PodcastReading
  public let podcastRefreshing: any PodcastRefreshing
  /// Bounded device-owned all-feed refresh, used only by Podcasts-tab and foreground triggers.
  public let rssFeedRefreshCoordinator: any RSSFeedRefreshCoordinating
  /// Composition-time override for episode actions. The factory receives the shell's one shared
  /// `PlaybackModel`; `nil` preserves the current ABS-only construction.
  public let makePodcastEpisodeIntents: (@MainActor @Sendable (PlaybackModel) -> any PodcastEpisodeIntents)?
  /// Detected podcast ad ranges for the player: the device-owned ad-skip coordinator, shared
  /// across account rebuilds. `nil` composes no ad skipping.
  public let skipRanges: (any PlaybackSkipRangeSource)?
  /// The device's time-saved totals, shared across account rebuilds. `nil` records nothing.
  public let timeSaved: (any TimeSavedRecording)?
  /// Trim Silences for the player: the device-owned pause analysis, the engine's composition
  /// preparer and the settings it resolves. `nil` composes no trimming.
  public let trim: PlaybackTrimDependencies?
  /// What plays before Up Next while a smart list runs (ADR 0016). Defaults to no run.
  public let playbackContinuation: any PlaybackContinuationSource
  /// The active smart list run as the Up Next sheet and Play Next copy read it. `nil` composes no
  /// run, so the sheet and the copy stay as they were.
  public let smartListRun: SmartListRunModel?
  /// The universal Up Next boundaries onto `Persistence`'s `ListeningQueueStore`, which resolves
  /// an audiobook or a podcast-episode identity against the same account-scoped
  /// `listeningQueueEntry` table. One queue boundary per account graph.
  public let listeningQueueReading: any ListeningQueueReading
  public let listeningQueueStoring: any ListeningQueueStoring
  public let savedShelfStoring: any SavedShelfStoring
  /// `nil` means there is no saved source. Never pass a live `NoOpSavedShelfReading`: its stream
  /// finishes without emitting, which would stall `HomeModel`'s readiness barrier.
  public let savedShelfReading: (any SavedShelfReading)?
  /// `PodcastSettingsModel`/`PodcastShowSettingsModel`'s boundary onto `Persistence`'s
  /// `PodcastSettingsStore`. AppModel may not import the concrete GRDB-backed store
  /// (ARCHITECTURE.md §2). Runtime-only: `platform` supplies `NoOpPodcastSettingsAccess()`. The
  /// real store structurally conforms to both boundaries (`PodcastSettingsBoundaries.swift`).
  public let podcastSettingsReading: any PodcastSettingsReading
  public let podcastSettingsWriting: any PodcastSettingsWriting
  public let nativePodcastSettingsAccess: (any (PodcastSettingsReading & PodcastSettingsWriting))?
  /// `PlaybackRateCoordinator`'s boundary onto `Persistence`'s `ItemPlaybackSettingsStore`.
  /// Runtime-only: `platform` supplies the no-op access, so a graph built before an account exists
  /// reports no overrides, which is the correct answer.
  public let itemPlaybackSettingsReading: any ItemPlaybackSettingsReading
  public let itemPlaybackSettingsWriting: any ItemPlaybackSettingsWriting
  /// The app-wide default speed, inherited by every title without an override. A PlayerCore
  /// boundary rather than a Persistence one: it is device-local and account-independent, and
  /// `PlayerController` already reads it at process start.
  public let playbackPreferences: any PlaybackPreferences
  /// `PodcastShowsModel`'s boundary onto `Persistence`'s `DefaultPodcastShowOrdering`. AppModel
  /// may not import the concrete GRDB-backed store (ARCHITECTURE.md §2). Runtime-only: `platform`
  /// supplies `NoOpPodcastShowOrdering()`.
  public let podcastShowOrdering: any PodcastShowOrdering
  /// The bounded reads behind the car's lists. Runtime-only: `platform` supplies empty lists; the
  /// runtime composition supplies the account-scoped readers.
  public let carPlayBrowseSources: CarPlayBrowseSources
  /// `SearchModel`'s local-search boundary onto `Persistence`'s `SearchReading`. Runtime-only:
  /// `platform` supplies `NoOpSearchReading()`.
  public let searchReading: any SearchReading
  /// `SearchModel`'s per-account recent-queries boundary onto `Persistence`'s
  /// `RecentSearchStoring`. Runtime-only: `platform` supplies `NoOpRecentSearchStoring()`.
  public let recentSearchStore: any RecentSearchStoring
  /// `AuthorSeriesModel`'s boundary onto the live, paginated `/api/libraries/{id}/authors|series`
  /// fetch. Runtime-only: `platform` supplies `NoOpAuthorSeriesReading()`.
  public let authorSeriesReading: any AuthorSeriesReading
  /// The stored collections and playlists and their fetch. `platform` supplies `.unavailable` for
  /// the setup and removal graphs, which open no account observation.
  public let libraryCollections: LibraryCollectionsAccess
  /// The read-only Server & Account Settings boundary. Its live profile read and durable snapshot
  /// are kept separate so an unavailable `/api/me` response cannot hide cached account data.
  /// Runtime-only: `platform` supplies the no-op.
  public let serverAccountReading: any ServerAccountReading
  /// The device-local library-selection snapshot and immediate mutation boundary used by Settings.
  /// `platform` supplies the inert store for the removal graph; setup and runtime name their own.
  public let librarySelectionReading: any LibrarySelectionReading
  /// The device-owned native-subscription preference. Production supplies one shared instance to
  /// both sides so a Settings write immediately reaches the shell's visibility gate. Runtime-only:
  /// `platform` supplies the inert pair.
  public let nativePodcastSubscriptionsReading: any NativePodcastSubscriptionsReading
  public let accountIdentityReading: any AccountIdentityReading
  public let nativePodcastSubscriptionsWriting: any NativePodcastSubscriptionsWriting
  public let nativeEpisodeServerSaving: any NativeEpisodeServerSaving
  public let nativeEpisodeServerSaveBatchSaving: any NativeEpisodeServerSaveBatchSaving
  public let nativeEpisodeServerSaveRecovering: any NativeEpisodeServerSaveRecovering
  public let nativeEpisodeServerSaveStatusReading: any NativeEpisodeServerSaveStatusReading
  public let nativeEpisodeIDResolving: any NativeEpisodeIDResolving
  public let serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading
  /// Show Settings' server automation editor (ADR 0017). `platform` reports `.notPermitted`, so the
  /// setup and removal graphs write nothing.
  public let serverPodcastAutomationSettingsWriting: any ServerPodcastAutomationSettingsWriting
  /// Send to E-reader for the book menus. `platform` offers no devices, so the setup and removal
  /// graphs draw no entry.
  public let ebookDelivery: any EbookDelivering
  public let notificationIntentReading: any RSSNotificationIntentReading
  public let notificationIntentWriting: any RSSNotificationIntentWriting
  public let localNotificationAuthorizer: any RSSLocalNotificationAuthorizing
  public let rssNotificationLifecycle: any RSSNotificationLifecycleHandling
  /// The local RSS show collection, kept separate from the account-owned ABS library reader.
  public let nativePodcastShowsReading: any NativePodcastShowsReading
  /// The image an RSS episode declares, observed for the players' covers.
  public let rssEpisodeArtworkReading: any RSSEpisodeArtworkReading
  public let nativeFeedRecoveryReading: any NativeFeedRecoveryReading
  /// Previewing opens the bounded RSS transport only when the user asks; the default client is the
  /// production transport. Following and managing remain inert until the composition root supplies
  /// database-backed stores.
  public let feedPreviewProviding: any FeedPreviewProviding
  public let podcastDirectorySearching: any PodcastDirectorySearching
  public let nativeFeedFollowing: any NativeFeedFollowing
  public let nativeFeedManaging: any NativeFeedManaging
  public let nativeSubscriptionOPMLExporter: any NativeSubscriptionOPMLExporting
  public let librarySelectionWriting: any LibrarySelectionWriting
  /// Setup's small post-authentication discovery operation. Separate from the runtime
  /// `SyncCoordinating` graph, which must not be constructed while selection is pending.
  public let librarySelectionDiscovery: any LibrarySelectionDiscovering

  /// Whether the authenticated account still needs the setup-only library-selection step.
  public let isLibrarySelectionPending: @Sendable () -> Bool
  /// The shell gate: a completed selection with at least one live included library.
  public let hasConfiguredIncludedLibrary: @Sendable () -> Bool
  /// The synchronous read of the removal journal `AccountLifecycle.isRemovalPending()` reports
  /// asynchronously, so `RootModel.init` can raise the removal gate before the first frame. The
  /// async boundary still performs the resume; this only decides the launch presentation.
  public let isRemovalPendingSynchronously: @Sendable () -> Bool
  /// A playback stall asks the configured server monitor for one debounced detection probe. The
  /// callback stays a closure so AppModel does not depend on the monitor's actor or on
  /// `ConnectivityModel`.
  public let requestReachabilityProbe: @Sendable () -> Void
  /// Device-owned ordering for native shows, distinct from ABS account ordering.
  public let nativePodcastShowOrdering: any NativePodcastShowOrdering

  public init(
    account: any AccountLifecycle,
    sync: any SyncCoordinating,
    library: any LibraryReading,
    player: any PlaybackControlling,
    playbackSync: any PlaybackSyncing,
    reader: any EPUBRendering,
    networkConditions: any NetworkConditions,
    appLifecycle: any AppLifecycle,
    diagnostics: any DiagnosticsRecording,
    isLibrarySelectionPending: @escaping @Sendable () -> Bool = { false },
    hasConfiguredIncludedLibrary: @escaping @Sendable () -> Bool = { false },
    isRemovalPendingSynchronously: @escaping @Sendable () -> Bool = { false },
    requestReachabilityProbe: @escaping @Sendable () -> Void = {},
    downloadReading: any DownloadReading,
    storageReading: any StorageReading,
    rssDownloadsReading: any RSSDownloadsReading,
    deviceStorageCapacityReading: any DeviceStorageCapacityReading,
    downloadIntents: any DownloadIntents,
    itemProgressIntents: any ItemProgressIntents,
    downloadPreferences: any DownloadPreferences,
    artworkCacheAccess: any ArtworkCacheAccess,
    resolutionCenterAccess: any ResolutionCenterAccess,
    extrasAccess: any ItemDetailExtrasAccess,
    historyAccess: any ListeningHistoryProviding,
    listeningStatsAccess: any ListeningStatsProviding,
    audioBookmarkIntents: any AudioBookmarkIntents,
    homeReading: any HomeReading,
    nativeLatestPodcastEpisodesReading: any NativeLatestPodcastEpisodesReading,
    nativeContinueListeningReading: any NativeContinueListeningReading,
    playbackBookmarkStoring: any PlaybackBookmarkStoring,
    podcastReading: any PodcastReading,
    podcastRefreshing: any PodcastRefreshing,
    rssFeedRefreshCoordinator: any RSSFeedRefreshCoordinating,
    makePodcastEpisodeIntents: (@MainActor @Sendable (PlaybackModel) -> any PodcastEpisodeIntents)? = nil,
    skipRanges: (any PlaybackSkipRangeSource)? = nil,
    timeSaved: (any TimeSavedRecording)? = nil,
    trim: PlaybackTrimDependencies? = nil,
    playbackContinuation: any PlaybackContinuationSource = NoOpPlaybackContinuationSource(),
    smartListRun: SmartListRunModel? = nil,
    listeningQueueReading: any ListeningQueueReading,
    listeningQueueStoring: any ListeningQueueStoring,
    savedShelfStoring: any SavedShelfStoring,
    savedShelfReading: (any SavedShelfReading)? = nil,
    itemPlaybackSettingsReading: any ItemPlaybackSettingsReading,
    itemPlaybackSettingsWriting: any ItemPlaybackSettingsWriting,
    playbackPreferences: any PlaybackPreferences,
    podcastSettingsReading: any PodcastSettingsReading,
    podcastSettingsWriting: any PodcastSettingsWriting,
    nativePodcastSettingsAccess: (any (PodcastSettingsReading & PodcastSettingsWriting))? = nil,
    podcastShowOrdering: any PodcastShowOrdering,
    carPlayBrowseSources: CarPlayBrowseSources,
    searchReading: any SearchReading,
    recentSearchStore: any RecentSearchStoring,
    authorSeriesReading: any AuthorSeriesReading,
    libraryCollections: LibraryCollectionsAccess,
    serverAccountReading: any ServerAccountReading,
    librarySelectionReading: any LibrarySelectionReading,
    nativePodcastSubscriptionsReading: any NativePodcastSubscriptionsReading,
    accountIdentityReading: any AccountIdentityReading,
    nativePodcastSubscriptionsWriting: any NativePodcastSubscriptionsWriting,
    nativeEpisodeServerSaving: any NativeEpisodeServerSaving,
    nativeEpisodeServerSaveBatchSaving: any NativeEpisodeServerSaveBatchSaving,
    nativeEpisodeServerSaveRecovering: any NativeEpisodeServerSaveRecovering,
    nativeEpisodeServerSaveStatusReading: any NativeEpisodeServerSaveStatusReading,
    nativeEpisodeIDResolving: any NativeEpisodeIDResolving,
    serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading,
    serverPodcastAutomationSettingsWriting: any ServerPodcastAutomationSettingsWriting,
    ebookDelivery: any EbookDelivering,
    notificationIntentReading: any RSSNotificationIntentReading,
    notificationIntentWriting: any RSSNotificationIntentWriting,
    localNotificationAuthorizer: any RSSLocalNotificationAuthorizing,
    rssNotificationLifecycle: any RSSNotificationLifecycleHandling,
    nativePodcastShowsReading: any NativePodcastShowsReading,
    rssEpisodeArtworkReading: any RSSEpisodeArtworkReading = NoOpRSSEpisodeArtworkReading(),
    nativeFeedRecoveryReading: any NativeFeedRecoveryReading,
    librarySelectionWriting: any LibrarySelectionWriting,
    librarySelectionDiscovery: any LibrarySelectionDiscovering = NoOpLibrarySelectionDiscovery(),
    feedPreviewProviding: any FeedPreviewProviding = FeedPreviewClient(),
    podcastDirectorySearching: any PodcastDirectorySearching = PodcastDirectorySearchClient(),
    nativeFeedFollowing: any NativeFeedFollowing,
    nativeFeedManaging: any NativeFeedManaging,
    nativeSubscriptionOPMLExporter: any NativeSubscriptionOPMLExporting,
    nativePodcastShowOrdering: any NativePodcastShowOrdering
  ) {
    self.account = account
    self.sync = sync
    self.library = library
    self.player = player
    self.playbackSync = playbackSync
    self.reader = reader
    self.networkConditions = networkConditions
    self.appLifecycle = appLifecycle
    self.diagnostics = diagnostics
    self.isLibrarySelectionPending = isLibrarySelectionPending
    self.hasConfiguredIncludedLibrary = hasConfiguredIncludedLibrary
    self.isRemovalPendingSynchronously = isRemovalPendingSynchronously
    self.requestReachabilityProbe = requestReachabilityProbe
    self.downloadReading = downloadReading
    self.storageReading = storageReading
    self.rssDownloadsReading = rssDownloadsReading
    self.deviceStorageCapacityReading = deviceStorageCapacityReading
    self.downloadIntents = downloadIntents
    self.itemProgressIntents = itemProgressIntents
    self.downloadPreferences = downloadPreferences
    self.artworkCacheAccess = artworkCacheAccess
    self.resolutionCenterAccess = resolutionCenterAccess
    self.extrasAccess = extrasAccess
    self.historyAccess = historyAccess
    self.listeningStatsAccess = listeningStatsAccess
    self.audioBookmarkIntents = audioBookmarkIntents
    self.homeReading = homeReading
    self.nativeLatestPodcastEpisodesReading = nativeLatestPodcastEpisodesReading
    self.nativeContinueListeningReading = nativeContinueListeningReading
    self.playbackBookmarkStoring = playbackBookmarkStoring
    self.podcastReading = podcastReading
    self.podcastRefreshing = podcastRefreshing
    self.rssFeedRefreshCoordinator = rssFeedRefreshCoordinator
    self.makePodcastEpisodeIntents = makePodcastEpisodeIntents
    self.skipRanges = skipRanges
    self.timeSaved = timeSaved
    self.trim = trim
    self.playbackContinuation = playbackContinuation
    self.smartListRun = smartListRun
    self.listeningQueueReading = listeningQueueReading
    self.listeningQueueStoring = listeningQueueStoring
    self.savedShelfStoring = savedShelfStoring
    self.savedShelfReading = savedShelfReading
    self.itemPlaybackSettingsReading = itemPlaybackSettingsReading
    self.itemPlaybackSettingsWriting = itemPlaybackSettingsWriting
    self.playbackPreferences = playbackPreferences
    self.podcastSettingsReading = podcastSettingsReading
    self.podcastSettingsWriting = podcastSettingsWriting
    self.nativePodcastSettingsAccess = nativePodcastSettingsAccess
    self.podcastShowOrdering = podcastShowOrdering
    self.carPlayBrowseSources = carPlayBrowseSources
    self.searchReading = searchReading
    self.recentSearchStore = recentSearchStore
    self.authorSeriesReading = authorSeriesReading
    self.libraryCollections = libraryCollections
    self.serverAccountReading = serverAccountReading
    self.librarySelectionReading = librarySelectionReading
    self.nativePodcastSubscriptionsReading = nativePodcastSubscriptionsReading
    self.accountIdentityReading = accountIdentityReading
    self.nativePodcastSubscriptionsWriting = nativePodcastSubscriptionsWriting
    self.nativeEpisodeServerSaving = nativeEpisodeServerSaving
    self.nativeEpisodeServerSaveBatchSaving = nativeEpisodeServerSaveBatchSaving
    self.nativeEpisodeServerSaveRecovering = nativeEpisodeServerSaveRecovering
    self.nativeEpisodeServerSaveStatusReading = nativeEpisodeServerSaveStatusReading
    self.nativeEpisodeIDResolving = nativeEpisodeIDResolving
    self.serverPodcastMutationCapabilityReading = serverPodcastMutationCapabilityReading
    self.serverPodcastAutomationSettingsWriting = serverPodcastAutomationSettingsWriting
    self.ebookDelivery = ebookDelivery
    self.notificationIntentReading = notificationIntentReading
    self.notificationIntentWriting = notificationIntentWriting
    self.localNotificationAuthorizer = localNotificationAuthorizer
    self.rssNotificationLifecycle = rssNotificationLifecycle
    self.nativePodcastShowsReading = nativePodcastShowsReading
    self.rssEpisodeArtworkReading = rssEpisodeArtworkReading
    self.nativeFeedRecoveryReading = nativeFeedRecoveryReading
    self.librarySelectionWriting = librarySelectionWriting
    self.librarySelectionDiscovery = librarySelectionDiscovery
    self.feedPreviewProviding = feedPreviewProviding
    self.podcastDirectorySearching = podcastDirectorySearching
    self.nativeFeedFollowing = nativeFeedFollowing
    self.nativeFeedManaging = nativeFeedManaging
    self.nativeSubscriptionOPMLExporter = nativeSubscriptionOPMLExporter
    self.nativePodcastShowOrdering = nativePodcastShowOrdering
  }

  /// The inert baseline the setup and removal graphs build from.
  ///
  /// Those two graphs must run without an account, so every account-owned read, write and
  /// observation is a no-op there. Naming that baseline once keeps the no-ops honest and stops
  /// them from being repeated (or silently forgotten) at each site. The runtime graph does not use
  /// this factory: it builds through `init` and must name every live service.
  ///
  /// `sync` and `playbackSync` are parameters rather than baseline no-ops so each caller chooses
  /// its inert coordinator explicitly.
  public static func platform(
    player: any PlaybackControlling,
    library: any LibraryReading,
    reader: any EPUBRendering,
    networkConditions: any NetworkConditions,
    account: any AccountLifecycle,
    sync: any SyncCoordinating,
    playbackSync: any PlaybackSyncing,
    appLifecycle: any AppLifecycle,
    diagnostics: any DiagnosticsRecording,
    isRemovalPendingSynchronously: @escaping @Sendable () -> Bool = { false },
    isLibrarySelectionPending: @escaping @Sendable () -> Bool = { false },
    librarySelectionReading: any LibrarySelectionReading = NoOpLibrarySelectionStore(),
    librarySelectionWriting: any LibrarySelectionWriting = NoOpLibrarySelectionStore(),
    librarySelectionDiscovery: any LibrarySelectionDiscovering = NoOpLibrarySelectionDiscovery(),
    rssNotificationLifecycle: any RSSNotificationLifecycleHandling = NoOpRSSNotificationLifecycle()
  ) -> AppDependencies {
    AppDependencies(
      account: account,
      sync: sync,
      library: library,
      player: player,
      playbackSync: playbackSync,
      reader: reader,
      networkConditions: networkConditions,
      appLifecycle: appLifecycle,
      diagnostics: diagnostics,
      isLibrarySelectionPending: isLibrarySelectionPending,
      isRemovalPendingSynchronously: isRemovalPendingSynchronously,
      downloadReading: NoOpDownloadReading(),
      storageReading: NoOpStorageReading(),
      rssDownloadsReading: NoOpRSSDownloadsReading(),
      deviceStorageCapacityReading: NoOpDeviceStorageCapacityReading(),
      downloadIntents: NoOpDownloadIntents(),
      itemProgressIntents: NoOpItemProgressIntents(),
      downloadPreferences: NoOpDownloadPreferences(),
      artworkCacheAccess: NoOpArtworkCacheAccess(),
      resolutionCenterAccess: NoOpResolutionCenterAccess(),
      extrasAccess: NoOpItemDetailExtrasAccess(),
      historyAccess: NoOpListeningHistoryProviding(),
      listeningStatsAccess: NoOpListeningStatsProviding(),
      audioBookmarkIntents: NoOpAudioBookmarkIntents(),
      homeReading: NoOpHomeReading(),
      nativeLatestPodcastEpisodesReading: NoOpNativeLatestPodcastEpisodesReading(),
      nativeContinueListeningReading: NoOpNativeContinueListeningReading(),
      playbackBookmarkStoring: NoOpPlaybackBookmarkStoring(),
      podcastReading: NoOpPodcastReading(),
      podcastRefreshing: NoOpPodcastRefreshing(),
      rssFeedRefreshCoordinator: NoOpRSSFeedRefreshCoordinator(),
      listeningQueueReading: NoOpListeningQueueStore(),
      listeningQueueStoring: NoOpListeningQueueStore(),
      savedShelfStoring: NoOpSavedShelfStore(),
      itemPlaybackSettingsReading: NoOpItemPlaybackSettingsAccess(),
      itemPlaybackSettingsWriting: NoOpItemPlaybackSettingsAccess(),
      playbackPreferences: NoOpPlaybackPreferences(),
      podcastSettingsReading: NoOpPodcastSettingsAccess(),
      podcastSettingsWriting: NoOpPodcastSettingsAccess(),
      podcastShowOrdering: NoOpPodcastShowOrdering(),
      carPlayBrowseSources: .empty,
      searchReading: NoOpSearchReading(),
      recentSearchStore: NoOpRecentSearchStoring(),
      authorSeriesReading: NoOpAuthorSeriesReading(),
      libraryCollections: .unavailable,
      serverAccountReading: NoOpServerAccountReading(),
      librarySelectionReading: librarySelectionReading,
      nativePodcastSubscriptionsReading: NoOpNativePodcastSubscriptionsReading(),
      accountIdentityReading: NoOpAccountIdentityReading(),
      nativePodcastSubscriptionsWriting: NoOpNativePodcastSubscriptionsWriting(),
      nativeEpisodeServerSaving: NoOpNativeEpisodeServerSaving(),
      nativeEpisodeServerSaveBatchSaving: NoOpNativeEpisodeServerSaveBatchSaving(),
      nativeEpisodeServerSaveRecovering: NoOpNativeEpisodeServerSaveRecovering(),
      nativeEpisodeServerSaveStatusReading: NoOpNativeEpisodeServerSaveStatusReading(),
      nativeEpisodeIDResolving: NoOpNativeEpisodeIDResolving(),
      serverPodcastMutationCapabilityReading: NoOpServerPodcastMutationCapabilityReading(),
      serverPodcastAutomationSettingsWriting: NoOpServerPodcastAutomationSettingsWriting(),
      ebookDelivery: NoOpEbookDelivering(),
      notificationIntentReading: DisabledRSSNotificationIntent(),
      notificationIntentWriting: DisabledRSSNotificationIntent(),
      localNotificationAuthorizer: NoOpRSSLocalNotificationAuthorizer(),
      rssNotificationLifecycle: rssNotificationLifecycle,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
      nativeFeedRecoveryReading: NoOpNativeFeedRecoveryReading(),
      librarySelectionWriting: librarySelectionWriting,
      librarySelectionDiscovery: librarySelectionDiscovery,
      nativeFeedFollowing: NoOpNativeFeedFollowing(),
      nativeFeedManaging: NoOpNativeFeedManaging(),
      nativeSubscriptionOPMLExporter: NoOpNativeSubscriptionOPMLExporter(),
      nativePodcastShowOrdering: NoOpNativePodcastShowOrdering()
    )
  }
}
