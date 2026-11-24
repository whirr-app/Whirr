import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine

extension AppEnvironment {
  /// The cached server+account bundle, its client, and the smart-list, RSS and server-save
  /// readings built over them. `makeSharedServicesComposition` is the runtime graph's only
  /// `sharedServices` call: a second call under the same key would be a cache hit and hide a
  /// duplicate composition, so `init` must never call it separately.
  struct SharedServicesComposition {
    let podcastServices: PodcastBackgroundRefreshHardware.SharedServices
    let client: ABSClient
    let smartListServices: SmartListServices
    let rssPodcastReading: RSSPodcastReading
    let nativeEpisodeIDResolving: PersistenceNativeEpisodeIDResolver
    let nativeEpisodeServerSaveStatusReading: any NativeEpisodeServerSaveStatusReading
  }

  @MainActor
  static func makeSharedServicesComposition(
    serverConfig: ABSServerConfig,
    account: AccountRecord?,
    tokenStore: KeychainTokenStore,
    customHeaderStore: KeychainCustomHeaderStore,
    feedCredentialStore: KeychainFeedCredentialStore,
    database: AppDatabase,
    diagnostics: DiagnosticsStore,
    accountLifecycle: AccountLifecycleService,
    appLifecycle: ScenePhaseAppLifecycle,
    networkConditions: NetworkConditionsReducer,
    podcastSettingsReading: any (PodcastSettingsReading & PodcastSettingsWriting),
    nativePodcastSubscriptions: NativePodcastSubscriptionsPreference,
    notificationIntent: PodcastNotificationPreference,
    applicationSupportDirectory: URL?,
    clearCachedArtwork: @escaping @Sendable () async -> Void
  ) -> SharedServicesComposition {
    // `AccountServerTimeObserver` is the SyncEngine-owned `ServerDateObserving` conformance (ABSApi
    // may not import Persistence): each response's `Date` header feeds the per-account server-clock
    // offset read by `ResolutionCenter`'s skew confirmations and the session-upload clamp.
    //
    // The account-lifetime download and auto-download services also come from this cache, shared
    // with `PodcastBackgroundRefreshHardware.handle()`, so a background wake builds no second copy.
    let podcastServices = PodcastBackgroundRefreshHardware.sharedServices(
      key: Self.sharedServicesKey(server: serverConfig, accountID: account?.id),
      server: serverConfig,
      tokenAccount: try? account?.credentialTokenAccount,
      tokenStore: tokenStore,
      customHeaderStore: customHeaderStore,
      feedCredentialStore: feedCredentialStore,
      database: database,
      diagnostics: diagnostics,
      accountLifecycle: accountLifecycle,
      appLifecycle: appLifecycle,
      networkConditions: networkConditions,
      podcastSettingsReading: podcastSettingsReading,
      nativePodcastSubscriptions: nativePodcastSubscriptions,
      notificationIntent: notificationIntent,
      notificationScheduler: PodcastLocalNotificationCenter.shared,
      accountId: account?.id,
      applicationSupportDirectory: applicationSupportDirectory,
      clearCachedArtwork: clearCachedArtwork)
    let client = podcastServices.client
    // One instance for both consumers: the Smart Lists surfaces and the run model playback
    // composes below.
    let smartListServices = Self.makeSmartListServices(
      database: database, nativeSubscriptions: nativePodcastSubscriptions, client: client,
      showRefresh: podcastServices.showRefresh,
      downloads: podcastServices.smartListDownloadReconciler)
    let rssPodcastReading = RSSPodcastReading(database: database)
    // Device-owned rows, so the resolver is live signed in or out; the account gate below is what
    // keeps a signed-out composition from reporting any server-save status.
    let nativeEpisodeIDResolving = PersistenceNativeEpisodeIDResolver(database: database)

    let nativeEpisodeServerSaveStatusReading: any NativeEpisodeServerSaveStatusReading =
      account?.id == nil
      ? NoOpNativeEpisodeServerSaveStatusReading()
      : NativeEpisodeServerSaveStatusProjection(
        database: database, nativeSubscriptionsReading: nativePodcastSubscriptions)

    return SharedServicesComposition(
      podcastServices: podcastServices,
      client: client,
      smartListServices: smartListServices,
      rssPodcastReading: rssPodcastReading,
      nativeEpisodeIDResolving: nativeEpisodeIDResolving,
      nativeEpisodeServerSaveStatusReading: nativeEpisodeServerSaveStatusReading)
  }
}
