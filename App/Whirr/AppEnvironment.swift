import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import PlayerCore
import PodcastFeeds
import ReaderCore
import SwiftUI
import SyncEngine
import UIKit

/// Production `AppDependencies` composition: the graph `AppModelWiringTests` builds from fakes
/// (ARCHITECTURE.md), with real conformances, wired to the shared `PlaybackHardware` singleton
/// `RootView` threads through every rebuild.
///
/// `SyncEngine`/`CoverImageClient`/`PlaybackSessionCoordinator` bind to a server config at
/// construction, but the server is only known once an account exists. An unauthenticated launch
/// uses a setup-only graph (real `AccountLifecycleService`, inert boundaries elsewhere); a
/// pending-removal launch a narrower removal-only graph. `RootView` rebuilds setup only after the
/// journal is cleared.
@MainActor
final class AppEnvironment {
  enum Mode: Equatable {
    /// Use the setup-only graph when there is no account and no interrupted removal to resume.
    case automatic
    /// Build every authenticated runtime service. Tests use this by default to inspect the full
    /// graph.
    case runtime
  }

  enum Composition: Equatable {
    case setup
    case runtime
    case removalPending
  }

  /// The process's single `ScenePhase` adapter, fed only by `SceneRegistry`. A per-environment one
  /// would leave `sharedServices`' cached `ServerReachabilityMonitor` deaf to the scene after the
  /// first rebuild, silently ending its foreground-gated recovery probing.
  /// `NetworkConditionsReducer` is immune: it uses `NWPathMonitor`.
  static let sharedLifecycle = ScenePhaseAppLifecycle(
    backgroundTaskProviding: RealBackgroundTaskProviding(application: .shared))

  let dependencies: AppDependencies
  let coverImageClient: CoverImageClient
  let artworkClient: ProviderArtworkClient
  /// The account's cover colour, shared by the shell's surfaces and the background writers.
  let paletteService: CoverPaletteService
  let composition: Composition
  /// Reader-specific boundaries stay in the App composition because Core's AppDependencies is
  /// frozen at the renderer boundary. Detail and reader views receive these same
  /// instances for the lifetime of one environment.
  let readerStateReading: any ReaderStateReading
  /// An audiobook's companion PDFs: the stored set joined with each file's download row, plus the
  /// viewer's device-local page memory.
  let supplementReading: any ItemSupplementReading
  /// The detail screen's Contents tab reads an EPUB's navigation document. Its own extractor,
  /// never the reader's renderer: a screen sharing the renderer could close the live publication
  /// out from under the reading page.
  let readerTableOfContents: any EPUBTableOfContentsReading
  /// Where a parsed navigation document is kept, so the Contents tab outlives the downloaded file
  /// and no viewing re-parses one it has already read.
  let readerContentsAccess: any EbookTableOfContentsAccess
  let readerProgress: any ReaderProgressAccessing
  let readerPreferencesStore: any ReaderPreferencesStoring
  let requestLocalSessionUploadDrain: @concurrent @Sendable () async -> Void
  /// Nil on the setup and removal-only graphs, which have no account to list episodes for.
  let smartListServices: SmartListServices?

  private let database: AppDatabase
  private let accountDAO: AccountDAO
  private let lifecycle: ScenePhaseAppLifecycle
  /// Nil on the setup and removal-only graphs, which compose no engine.
  private let syncEngine: SyncEngine?
  private var followedShowArtworkWarmPass: FollowedShowArtworkWarmPass? = nil
  private var coverPaletteBackfill: CoverPaletteBackfill? = nil
  private let libraryCacheLifecycleTask: Task<Void, Never>?
  private let downloadAutomationTasks: [Task<Void, Never>]
  /// The once-per-launch convergence pass over server-save attempts whose last network
  /// result the previous process never recorded. Nil outside the runtime composition.
  private let nativeEpisodeServerSaveRecoveryTask: Task<Void, Never>?
  private let queueAutoDownloadReconciler: QueueAutoDownloadReconciler?
  private let storageCeilingCoordinator: StorageCeilingCoordinator?
  /// The persisted projection consumed by the Downloads screen's `StorageModel`.
  let storageCeilingSummaryReading: any StorageCeilingSummaryReading
  /// Every show's own Trim Silences setting, both spines merged, for the show settings page and
  /// the speed card. `nil` outside the runtime composition.
  let trimSilencesShowSettings: RoutingTrimSilencesShowSettingsAccess?
  /// Every show's own Voice Boost setting, both spines merged, for the same surfaces and for the
  /// engine's observer. `nil` outside the runtime composition.
  let voiceBoostShowSettings: RoutingVoiceBoostShowSettingsAccess?
  /// `nil` on the setup-only graph (no account, so no shared client/bridge exists yet).
  /// Composition tests use this to prove the wiring and dedup guarantees.
  let authRecoveryModel: AuthRecoveryModel?
  /// The account-lifetime reachability projection from the same shared-services bundle as
  /// the live client. `nil` on setup/removal compositions that have no configured server client.
  let connectivityModel: ConnectivityModel?
  /// Endpoint selection is runtime-only; setup and interrupted-removal compositions leave it nil.
  let endpointSwitchCoordinator: EndpointSwitchCoordinator?
  /// Settings' account-scoped server-address model; nil before an account exists.
  let serverAddressesModel: ServerAddressesModel?
  /// Settings › About › Report a Problem reads through these. The export directory sits under
  /// the diagnostics root that both account-removal coordinators delete.
  let problemReportSources: ProblemReportSources
  let diagnosticsExportDirectory: URL

  init(
    hardware: PlaybackHardware,
    mode: Mode = .runtime,
    database: AppDatabase,
    accountState: AccountLaunchState? = nil,
    applicationSupportDirectory: URL? = nil
  ) {
    self.database = database
    let coverPaletteRecordStore = CoverPaletteRecordStore(database: database)
    let accountDAO = AccountDAO(database: database)
    self.accountDAO = accountDAO

    // The service namespace literals below are always non-empty, so these initializers cannot
    // actually throw. Both credential classes use device-only Keychain items (SECURITY.md).
    let tokenStore = try! KeychainTokenStore()
    let customHeaderStore = try! KeychainCustomHeaderStore()
    let feedCredentialStore = try! KeychainFeedCredentialStore()
    // The v63 database migration ran when the database opened; the Keychain item must be under
    // the account's credential namespace before any service below reads tokens.
    _ = CredentialNamespaceMigration.run(accountDAO: accountDAO, tokenStore: tokenStore)
    // `AccountRemover` is shared by the setup-only lifecycle and by the
    // `AccountRemovalCoordinator` sequence composed for authenticated logout or pending removal.
    let accountRemover = AccountRemover(database: database)

    let diagnosticsStore = DiagnosticsStore(database: database)
    let lifecycle = Self.sharedLifecycle
    self.lifecycle = lifecycle

    // The launch graph is handed what the bootstrap read, so a failed read there is an error
    // state rather than a setup screen. A replacement graph follows a login or a removal that
    // just wrote these rows, and reads them itself.
    let account = accountState.map(\.account) ?? (try? accountDAO.fetch())
    let diagnosticsRootURL = DiagnosticsLocations.root(
      applicationSupportDirectory: applicationSupportDirectory ?? AppEnvironment.applicationSupportDirectory())
    diagnosticsExportDirectory = DiagnosticsLocations.exports(root: diagnosticsRootURL)
    problemReportSources = ProblemReportComposition.sources(
      accountDAO: accountDAO,
      accountEndpointDAO: AccountEndpointDAO(database: database),
      diagnosticsStore: diagnosticsStore,
      metricKitDirectory: DiagnosticsLocations.metricKit(root: diagnosticsRootURL))
    let removalIsPending =
      accountState?.removalIsPending
      ?? (((try? AccountRemovalJournalStore(database: database).fetch()) ?? nil) != nil)
    let serverConfigFactory = ABSServerConfigFactory(customHeaderStore: customHeaderStore)
    let artwork = Self.makeArtworkComposition(
      account: account,
      serverConfigFactory: serverConfigFactory,
      feedCredentialStore: feedCredentialStore,
      coverPaletteRecordStore: coverPaletteRecordStore)
    let serverConfig = artwork.serverConfig
    let preparedArtworkScope = artwork.preparedArtworkScope
    let coverImageClient = artwork.coverImageClient
    let rssArtworkClient = artwork.rssArtworkClient
    let artworkClient = artwork.artworkClient
    let clearCachedArtwork = artwork.clearCachedArtwork
    self.artworkClient = artworkClient
    paletteService = artwork.paletteService
    let setupAccountLifecycle = AccountLifecycleService(
      tokenStore: tokenStore,
      accountDAO: accountDAO,
      accountEndpointDAO: AccountEndpointDAO(database: database),
      accountRemover: accountRemover,
      customHeaderStore: customHeaderStore,
      clearCachedArtwork: clearCachedArtwork
    )

    let usesSetupComposition =
      removalIsPending == false
      && mode == .automatic
      && (setupAccountLifecycle.isAuthenticated == false || account?.librarySelectionMode == .pending)

    if removalIsPending || usesSetupComposition {
      // Neither graph has an authenticated runtime, so both leave every runtime-only service inert.
      self.coverImageClient = coverImageClient
      authRecoveryModel = nil
      connectivityModel = nil
      endpointSwitchCoordinator = nil
      serverAddressesModel = nil
      readerStateReading = NoOpReaderStateReading()
      supplementReading = NoOpItemSupplementReading()
      readerTableOfContents = NoOpEPUBTableOfContentsReading()
      readerContentsAccess = NoOpEbookTableOfContentsAccess()
      readerProgress = NoOpReaderProgressAccess()
      readerPreferencesStore = NoOpReaderPreferencesStore()
      requestLocalSessionUploadDrain = {}
      smartListServices = nil
      syncEngine = nil
      downloadAutomationTasks = []
      nativeEpisodeServerSaveRecoveryTask = nil
      queueAutoDownloadReconciler = nil
      storageCeilingCoordinator = nil
      storageCeilingSummaryReading = NoOpStorageCeilingSummaryStore()
      trimSilencesShowSettings = nil
      voiceBoostShowSettings = nil
      libraryCacheLifecycleTask = nil

      if removalIsPending {
        // Removal-journal invariant: while a confirmed removal is durable, this launch may only
        // compose the coordinator and inert boundaries needed to finish it. No authenticated
        // client, sync subscription, download scheduler, podcast service, or account-owned-data
        // mutation is started until the journal has been cleared and RootView rebuilds normally.
        composition = .removalPending
        dependencies = Self.makeRemovalDependencies(
          account: Self.makePendingRemovalAccountLifecycle(
            database: database,
            accountDAO: accountDAO,
            tokenStore: tokenStore,
            customHeaderStore: customHeaderStore,
            accountRemover: accountRemover,
            applicationSupportDirectory: applicationSupportDirectory,
            diagnosticsRootURL: diagnosticsRootURL,
            clearCachedArtwork: clearCachedArtwork),
          database: database,
          hardware: hardware,
          lifecycle: lifecycle,
          diagnostics: diagnosticsStore)
      } else {
        PodcastBackgroundRefreshHardware.cancelScheduledRefresh()
        composition = .setup
        dependencies = Self.makeSetupDependencies(
          account: setupAccountLifecycle,
          database: database,
          accountDAO: accountDAO,
          hardware: hardware,
          lifecycle: lifecycle,
          diagnostics: diagnosticsStore,
          serverConfigFactory: serverConfigFactory,
          tokenStore: tokenStore,
          customHeaderStore: customHeaderStore,
          clearCachedArtwork: clearCachedArtwork
        )
      }
      return
    }
    composition = .runtime

    let deviceServices = Self.makeDeviceServicesComposition(
      database: database,
      account: account)
    let networkConditions = deviceServices.networkConditions
    let nativePodcastSubscriptions = deviceServices.nativePodcastSubscriptions
    let notificationIntent = deviceServices.notificationIntent
    let notificationLifecycle = deviceServices.notificationLifecycle
    let podcastSettingsAccess = deviceServices.podcastSettingsAccess
    let itemPlaybackSettingsAccess = deviceServices.itemPlaybackSettingsAccess

    let sharedServices = Self.makeSharedServicesComposition(
      serverConfig: serverConfig,
      account: account,
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore,
      feedCredentialStore: feedCredentialStore,
      database: database,
      diagnostics: diagnosticsStore,
      accountLifecycle: setupAccountLifecycle,
      appLifecycle: lifecycle,
      networkConditions: networkConditions,
      podcastSettingsReading: podcastSettingsAccess,
      nativePodcastSubscriptions: nativePodcastSubscriptions,
      notificationIntent: notificationIntent,
      applicationSupportDirectory: applicationSupportDirectory,
      clearCachedArtwork: clearCachedArtwork)
    let podcastServices = sharedServices.podcastServices
    let client = sharedServices.client
    let smartListServices = sharedServices.smartListServices
    self.smartListServices = smartListServices
    self.coverImageClient = coverImageClient
    let rssPodcastReading = sharedServices.rssPodcastReading
    let nativeEpisodeIDResolving = sharedServices.nativeEpisodeIDResolving
    let nativeEpisodeServerSaveStatusReading =
      sharedServices.nativeEpisodeServerSaveStatusReading

    // MARK: - Library Cache

    let libraryCache = Self.makeLibraryCacheComposition(
      database: database,
      paletteService: artwork.paletteService,
      coverImageClient: coverImageClient,
      rssArtworkClient: rssArtworkClient,
      artworkClient: artworkClient,
      preparedArtworkScope: preparedArtworkScope,
      rssPodcastReading: rssPodcastReading,
      client: client,
      networkConditions: networkConditions,
      lifecycle: lifecycle)
    let metadataBackfill = libraryCache.metadataBackfill
    self.followedShowArtworkWarmPass = libraryCache.followedShowArtworkWarmPass
    self.coverPaletteBackfill = libraryCache.coverPaletteBackfill
    self.libraryCacheLifecycleTask = libraryCache.lifecycleTask

    // MARK: - Downloads
    // Composed in `sharedServices` above so the background composition path resolves to the
    // same `DownloadCoordinator`.

    let downloadStore = podcastServices.downloadStore
    let downloadFileStore = podcastServices.downloadFileStore
    let rssFileStore = podcastServices.rssFileStore
    let downloadPreferences = podcastServices.downloadPreferences
    let downloadCoordinator = podcastServices.downloadCoordinator

    // MARK: - Playback session sync
    let playback = Self.makePlaybackComposition(
      hardware: hardware,
      database: database,
      smartListServices: smartListServices,
      accountDAO: accountDAO,
      client: client,
      diagnostics: diagnosticsStore,
      networkConditions: networkConditions,
      downloadStore: downloadStore,
      downloadFileStore: downloadFileStore,
      downloadCoordinator: downloadCoordinator,
      downloadPreferences: downloadPreferences,
      rssFileStore: rssFileStore,
      feedCredentialStore: feedCredentialStore,
      podcastServices: podcastServices,
      nativePodcastSubscriptions: nativePodcastSubscriptions,
      isSignedIn: account?.id != nil)
    let readerBoundaries = Self.makeReaderBoundariesComposition(
      database: database,
      downloadRootURL: downloadFileStore.rootURL,
      account: account,
      itemProgress: playback.itemProgressCoordinator)
    readerStateReading = readerBoundaries.readerStateReading
    supplementReading = readerBoundaries.supplementReading
    readerTableOfContents = readerBoundaries.readerTableOfContents
    readerContentsAccess = readerBoundaries.readerContentsAccess
    readerProgress = readerBoundaries.readerProgress
    readerPreferencesStore = readerBoundaries.readerPreferencesStore
    let trimSilencesShowSettings = readerBoundaries.trimSilencesShowSettings
    self.trimSilencesShowSettings = trimSilencesShowSettings
    voiceBoostShowSettings = readerBoundaries.voiceBoostShowSettings
    let outboxStore = playback.outboxStore
    let requestLocalSessionUploadDrain = playback.requestLocalSessionUploadDrain
    self.requestLocalSessionUploadDrain = requestLocalSessionUploadDrain
    let playbackSyncing = playback.playbackSyncing

    // Expanding a show's full episode list, and the deletion inference derived from it, is this
    // coordinator's job, driven by opening that show rather than by crawling the library on every
    // foreground.
    let catalogueRefresh = Self.makeCatalogueRefreshComposition(
      database: database,
      client: client,
      showRefresh: podcastServices.showRefresh)
    let podcastShowRefresh = catalogueRefresh.podcastShowRefresh
    let recentEpisodes = catalogueRefresh.recentEpisodes
    let podcastProgressHydration = catalogueRefresh.podcastProgressHydration
    let authorSeriesService = catalogueRefresh.authorSeriesService
    let libraryCollectionService = catalogueRefresh.libraryCollectionService
    let downloadIntents = Self.makeDownloadIntentsComposition(
      database: database,
      account: account,
      downloadCoordinator: downloadCoordinator,
      diagnostics: diagnosticsStore,
      smartListDownloadStore: podcastServices.smartListDownloadStore)
    let pinnedListStore = downloadIntents.pinnedListStore
    let pinnedListReconciler = downloadIntents.pinnedListReconciler
    let handDownloadIntents = downloadIntents.handDownloadIntents
    let syncEngine = SyncEngine.make(
      client: client,
      database: database,
      diagnostics: diagnosticsStore,
      appLifecycle: lifecycle,
      playback: playbackSyncing,
      localSessionUploadDrain: requestLocalSessionUploadDrain,
      recentEpisodes: recentEpisodes,
      podcastProgressHydration: podcastProgressHydration,
      metadataBackfill: metadataBackfill,
      // After a recent-episodes shelf commit: one pass, then a reap, against the same shared
      // coordinator/reaper that `PodcastBackgroundRefreshHardware.handle()` and
      // `podcastShowRefresh` use.
      podcastAutoDownload: podcastServices.podcastAutoDownload,
      podcastAutoDownloadReaper: podcastServices.podcastAutoDownloadReaper,
      authorSeriesFilterDataRefresh: { await authorSeriesService.refreshAllSnapshots() },
      libraryCollectionRefresh: {
        await libraryCollectionService.refreshAll(force: true)
        await pinnedListReconciler?.run()
      }
    )
    self.syncEngine = syncEngine

    hardware.rebindNowPlaying(
      itemInfoProvider: RoutingNowPlayingItemInfoProvider(
        abs: LibraryBackedNowPlayingItemInfoProvider(database: database, accountDAO: accountDAO),
        rss: RSSBackedNowPlayingItemInfoProvider(database: database)),
      coverImageClient: artworkClient
    )

    // MARK: - Resolution center

    let resolutionCenter = ResolutionCenter(
      database: database,
      outboxStore: outboxStore,
      downloadStore: downloadStore,
      downloadCoordinator: downloadCoordinator,
      client: client,
      diagnostics: diagnosticsStore,
      // Routes the resolution surface's explicit "Reconnect" action to the same
      // account-lifetime `AuthRecoveryEventBridge`/`AuthRecoveryModel` a latched definitive
      // rejection itself raises, so there is one recovery state whichever path requested it.
      requestReauthentication: { await podcastServices.authRecoveryEventBridge.requestReauthentication() }
    )
    // The bridge must exist before `client` (its auth-event observer) is constructed, so
    // `resolutionCenter`, which needs that `client`, is threaded back in here.
    podcastServices.authRecoveryEventBridge.resolutionCenter = resolutionCenter
    podcastServices.authRecoveryEventBridge.requestDrainAfterRecovery = playback.requestDrain

    // MARK: - Account removal

    let removalCoordinator = Self.makeRuntimeRemovalCoordinator(
      database: database,
      accountDAO: accountDAO,
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore,
      accountRemover: accountRemover,
      client: client,
      playbackSyncing: playbackSyncing,
      downloadCoordinator: downloadCoordinator,
      syncEngine: syncEngine,
      requestDrain: playback.requestDrain,
      downloadsRootURL: downloadFileStore.rootURL,
      diagnosticsRootURL: diagnosticsRootURL,
      widgetRootURLs: WidgetFileStore.production(applicationSupportDirectory: applicationSupportDirectory)
        .removalRootURLs,
      clearCachedArtwork: clearCachedArtwork)

    // MARK: - Item detail extras/history

    let itemDetailServices = Self.makeItemDetailServicesComposition(
      database: database, client: client)
    let extrasAccess = itemDetailServices.extrasAccess
    let ebookDelivery = itemDetailServices.ebookDelivery
    let historyAccess = itemDetailServices.historyAccess
    let listeningStatsAccess = itemDetailServices.listeningStatsAccess

    // MARK: - Runtime account-scoped services

    // Shared by the dependency graph below and by the library projections that consume it.
    let libraryReading = DefaultLibraryReading(database: database)
    let librarySelectionStore = LibrarySelectionStore(database: database)
    let serverAccountReading = ServerAccountReadingService(
      client: client, database: database, customHeaderStore: customHeaderStore)

    // Re-read the account for the account-scoped stores below. The background refresh scheduler
    // uses the same resolved row as its authenticated-launch gate.
    let resolvedAccount = try? accountDAO.fetch()
    if resolvedAccount != nil {
      PodcastBackgroundRefreshHardware.scheduleIfAuthenticated()
    }
    let recoveryModel = podcastServices.authRecoveryEventBridge.model
    authRecoveryModel = recoveryModel
    connectivityModel = podcastServices.connectivityModel
    let endpoint = Self.makeEndpointComposition(
      database: database,
      accountDAO: accountDAO,
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore,
      serverConfigFactory: serverConfigFactory,
      client: client,
      recoveryModel: recoveryModel,
      hardware: hardware,
      downloadCoordinator: downloadCoordinator)
    serverAddressesModel = endpoint.serverAddressesModel
    endpointSwitchCoordinator = endpoint.endpointSwitchCoordinator

    let storage = Self.makeStorageComposition(
      database: database,
      resolvedAccount: resolvedAccount,
      podcastServices: podcastServices,
      downloadCoordinator: downloadCoordinator,
      downloadPreferences: downloadPreferences)
    storageCeilingSummaryReading = storage.storageCeilingSummaryReading
    let storageReading = storage.storageReading
    let storageCeilingCoordinator = storage.storageCeilingCoordinator

    let accountLifecycle = Self.makeRuntimeAccountLifecycle(
      database: database,
      accountDAO: accountDAO,
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore,
      accountRemover: accountRemover,
      client: client,
      removalCoordinator: removalCoordinator,
      clearCachedArtwork: clearCachedArtwork)
    // The bridge/model is cached per server+account key and may have been created from
    // `setupAccountLifecycle` by a cold-launch composition. Rebind it on every runtime
    // AppEnvironment build so recovery always targets this environment's live client, including
    // rebuilds that reuse the existing cached bridge/model.
    podcastServices.authRecoveryEventBridge.model.bindAccountLifecycle(accountLifecycle)
    let downloadAutomation = Self.makeDownloadAutomationComposition(
      database: database,
      resolvedAccount: resolvedAccount,
      lifecycle: lifecycle,
      networkConditions: networkConditions,
      diagnostics: diagnosticsStore,
      downloadCoordinator: downloadCoordinator,
      downloadPreferences: downloadPreferences,
      storageReading: storageReading,
      storageCeilingCoordinator: storageCeilingCoordinator,
      pinnedListReconciler: pinnedListReconciler,
      smartListDownloads: (
        podcastServices.smartListDownloadReconciler, podcastServices.smartListDownloadStore
      ))
    self.queueAutoDownloadReconciler = downloadAutomation.queueAutoDownloadReconciler
    self.storageCeilingCoordinator = storageCeilingCoordinator
    self.downloadAutomationTasks = downloadAutomation.downloadAutomationTasks
    // The pass observes and checkpoints under the account fence; the only request it can send is
    // the enqueue that resumes a `createUncertain` attempt whose show has been re-resolved.
    let nativeEpisodeServerSaveRecovering = podcastServices.nativeEpisodeServerSaveRecovering
    nativeEpisodeServerSaveRecoveryTask = Task {
      await nativeEpisodeServerSaveRecovering.recoverPendingAttempts(feedId: nil)
    }
    let libraryCollections = Self.makeLibraryCollectionsComposition(
      database: database,
      account: account,
      libraryCollectionService: libraryCollectionService,
      queue: downloadAutomation.listeningQueueStoring,
      pinnedListStore: pinnedListStore,
      pinnedListReconciler: pinnedListReconciler,
      downloadCoordinator: downloadCoordinator)

    dependencies = Self.makeRuntimeDependencies(
      database: database,
      accountDAO: accountDAO,
      hardware: hardware,
      lifecycle: lifecycle,
      diagnosticsStore: diagnosticsStore,
      networkConditions: networkConditions,
      accountLifecycle: accountLifecycle,
      syncEngine: syncEngine,
      libraryReading: libraryReading,
      removalIsPending: removalIsPending,
      podcastServices: podcastServices,
      playback: playback,
      libraryCache: libraryCache,
      downloadAutomation: downloadAutomation,
      storageReading: storageReading,
      downloadFileStore: downloadFileStore,
      downloadCoordinator: downloadCoordinator,
      handDownloadIntents: handDownloadIntents,
      downloadPreferences: downloadPreferences,
      resolutionCenter: resolutionCenter,
      extrasAccess: extrasAccess,
      historyAccess: historyAccess,
      listeningStatsAccess: listeningStatsAccess,
      ebookDelivery: ebookDelivery,
      rssPodcastReading: rssPodcastReading,
      podcastShowRefresh: podcastShowRefresh,
      nativePodcastSubscriptions: nativePodcastSubscriptions,
      notificationIntent: notificationIntent,
      notificationLifecycle: notificationLifecycle,
      itemPlaybackSettingsAccess: itemPlaybackSettingsAccess,
      podcastSettingsAccess: podcastSettingsAccess,
      trimSilencesShowSettings: trimSilencesShowSettings,
      nativeEpisodeServerSaveStatusReading: nativeEpisodeServerSaveStatusReading,
      nativeEpisodeIDResolving: nativeEpisodeIDResolving,
      authorSeriesService: authorSeriesService,
      libraryCollections: libraryCollections,
      serverAccountReading: serverAccountReading,
      librarySelectionStore: librarySelectionStore,
      feedCredentialStore: feedCredentialStore)
  }

  /// Feeds a `ScenePhase` into the lifecycle adapter (ARCHITECTURE.md). Production goes
  /// through `SceneRegistry`, which aggregates every scene first; this is the direct route.
  func handleScenePhase(_ phase: ScenePhase) {
    lifecycle.handle(scenePhase: phase)
  }

  /// Purges prepared artwork before `RootView` replaces this environment at a login or logout
  /// boundary, so the process-wide cache does not retain images from the outgoing composition.
  func purgePreparedArtwork() {
    PreparedArtworkCache.shared.removeAll()
    // The incoming account's cover pass reloads its own shapes from its table.
    DetailArtwork.shapes.removeAll()
  }

  /// Shuts down this environment's sync engine before `RootView` replaces it (ARCHITECTURE.md).
  /// The lifecycle stream is process-wide, so an outgoing engine that anything still retains would
  /// otherwise keep answering `.foreground`. Not awaited: the replacement happens synchronously on
  /// the main actor, and nothing in the new graph waits for the old traversal to unwind. Removal
  /// awaits the same shutdown itself, so after a removal this is a no-op.
  @discardableResult
  func shutDownSync() -> Task<Void, Never>? {
    guard let syncEngine else { return nil }
    return Task { await syncEngine.shutdown() }
  }

  isolated deinit {
    libraryCacheLifecycleTask?.cancel()
    for task in downloadAutomationTasks { task.cancel() }
    nativeEpisodeServerSaveRecoveryTask?.cancel()
  }
}
