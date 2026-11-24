import AppModel
import Foundation
import Persistence
import SyncEngine

extension AppEnvironment {
  /// The device-owned services one runtime graph shares: `nativePodcastSubscriptions` gates
  /// Smart Lists and both subscription slots, `podcastSettingsAccess` is the instance handed to
  /// `sharedServices`, and `networkConditions` reaches the playback, library-cache and
  /// download-automation compositions and the `AppDependencies` slot as one object.
  ///
  /// `NetworkConditionsReducer.init` starts the path and power observers, so this type is built at
  /// the head of the runtime graph, before `sharedServices`.
  struct DeviceServicesComposition {
    let networkConditions: NetworkConditionsReducer
    let nativePodcastSubscriptions: NativePodcastSubscriptionsPreference
    let notificationIntent: PodcastNotificationPreference
    let notificationLifecycle: RSSNotificationLifecycleCoordinator
    let podcastSettingsAccess: any (PodcastSettingsReading & PodcastSettingsWriting)
    let itemPlaybackSettingsAccess: any (ItemPlaybackSettingsReading & ItemPlaybackSettingsWriting)
  }

  @MainActor
  static func makeDeviceServicesComposition(
    database: AppDatabase,
    account: AccountRecord?
  ) -> DeviceServicesComposition {
    let networkConditions = NetworkConditionsReducer(path: RealPathObserving(), power: RealPowerObserving())
    // Device-owned by design: logout rebuilds the account graph without deleting the preference
    // or RSS rows. This same instance gates show refresh, all-feed refresh, and the shell.
    let nativePodcastSubscriptions = NativePodcastSubscriptionsPreference(
      defaults: UserDefaults.standard)
    let notificationIntent = PodcastNotificationPreference(defaults: UserDefaults.standard)
    let notificationLifecycle = RSSNotificationLifecycleCoordinator(
      ledger: RSSNotificationLedgerStore(database: database),
      scheduler: PodcastLocalNotificationCenter.shared)

    // The real `PodcastSettingsStore` when an account id is known (always true on this runtime
    // path), else the `NoOp` boundary. Built before `sharedServices` because that call needs it
    // to construct the shared `PodcastAutoDownloadCoordinator`.
    let podcastSettingsAccess: any (PodcastSettingsReading & PodcastSettingsWriting)
    if let accountId = account?.id {
      podcastSettingsAccess = PodcastSettingsStore(database: database, accountId: accountId)
    } else {
      podcastSettingsAccess = NoOpPodcastSettingsAccess()
    }

    // The account-scoped per-title speed store. Without an account there are no overrides, which
    // the no-op access reports correctly.
    let itemPlaybackSettingsAccess: any (ItemPlaybackSettingsReading & ItemPlaybackSettingsWriting)
    if let accountId = account?.id {
      let absPlaybackSettings = ItemPlaybackSettingsStore(
        database: database, accountId: accountId)
      let rssPlaybackSettings = RSSFeedSettingsStore(database: database)
      // One coordinator boundary, dispatching typed RSS identities to the device-owned
      // feed settings while retaining the account-scoped ABS store unchanged.
      itemPlaybackSettingsAccess = RoutingItemPlaybackSettingsAccess(
        abs: absPlaybackSettings, rss: rssPlaybackSettings)
    } else {
      itemPlaybackSettingsAccess = NoOpItemPlaybackSettingsAccess()
    }

    return DeviceServicesComposition(
      networkConditions: networkConditions,
      nativePodcastSubscriptions: nativePodcastSubscriptions,
      notificationIntent: notificationIntent,
      notificationLifecycle: notificationLifecycle,
      podcastSettingsAccess: podcastSettingsAccess,
      itemPlaybackSettingsAccess: itemPlaybackSettingsAccess)
  }
}
