import AppModel
import Foundation
import Persistence
import SyncEngine

/// Everything `RootView` renders from, composed as one unit: the `AppEnvironment` and the models
/// that depend only on it (unlike `browseModel`/`searchModel`, which wait on
/// `RootModel.resolveLibraryIfAuthenticated()`). `AppRuntime` owns it, composing the launch graph
/// once and replacing it at the two account boundaries, as `SyncEngine`/`CoverImageClient` bind to
/// a server config at construction.
///
/// Never build one from a view's `init` or a `@State` default: SwiftUI constructs `RootView` in
/// its render loop far more often than it keeps one (see `DeferredModel`), and each surplus graph
/// costs an `AVQueuePlayer`, a keychain read, `AccountDAO.fetch()`, a `SyncEngine` and the
/// synchronous main-thread launch-recovery writes in `OutboxStore.init` and `DownloadStore.init`.
/// `PlaybackHardware.shared`, the process-lifetime singleton, is not part of a composition.
@MainActor
final class RootComposition {
  let environment: AppEnvironment
  let root: RootModel
  /// Unlike `browseModel`/`searchModel` (`RootModel`, gated behind a resolved library id),
  /// `HomeModel` needs only `homeReading`/`sync`, both known as soon as `AppEnvironment` exists.
  let homeModel: HomeModel
  let podcastListeningModel: HomeModel
  let podcastLatestModel: HomeMoreModel
  /// One model behind both Home's card and the Stats screen, so opening the screen shows the
  /// figures the card already has while its refresh runs.
  let listeningStatsModel: ListeningStatsModel
  /// The one durable-order model shared by the Podcasts root's Your Shows preview and the pushed
  /// `.podcastShows` all-shows page. Composed once so the two surfaces never open separate
  /// observations and disagree about order.
  let podcastShowsOrderedModel: PodcastShowsModel
  /// The device-owned subscription collection shared by the Podcasts root and its all-shows page.
  let nativePodcastShowsModel: NativePodcastShowsModel
  /// One add-feed state machine for this account graph; its RSS subscriptions themselves remain
  /// device-owned and survive graph rebuilds and logout.
  let addFeedModel: AddFeedModel
  let subscriptionOPMLModel: PodcastSubscriptionOPMLModel
  let podcastNotificationSettingsModel: PodcastNotificationSettingsModel
  let rssNotificationRouteResolver: RSSNotificationRouteResolver
  /// The one download projection every browse/search/home row and context menu reads. Rebuilt
  /// with the rest of the composition on both account boundaries so it never outlives the
  /// database it observes.
  let downloadStatus: DownloadStatusStore
  /// The one finished-state projection every browse row and item-detail screen reads. Rebuilt on
  /// both account boundaries like `downloadStatus`, so it never outlives the database it observes.
  let finishedStatus: FinishedStatusStore
  /// The one item-action model behind every long-press menu.
  let actions: ItemActionsModel
  let logoutPreflight: any LogoutPreflighting
  /// The current account's AppModel facade for Siri playback controls. The process router holds
  /// this weakly, so the composition must retain it for exactly the authenticated graph's
  /// lifetime. Setup and interrupted-removal compositions keep it nil and explicitly unbind.
  let voicePlaybackActions: VoicePlaybackActions?
  /// The smart list widget's run starter, held here because the Siri router holds it weakly.
  let smartListPlayback: SmartListPlaybackAdapter?
  let companionPlaybackActions: CompanionPlaybackActions?
  let watchCataloguePublisher: WatchCataloguePublisher?
  /// The widget snapshot publisher for this account; nil for every graph that is not an
  /// authenticated runtime one, and in a test graph composed without a widget runtime.
  let widgetSnapshotPublisher: WidgetSnapshotPublisher?
  /// The shell recovery indicator/sheet's UI-side presentation. `nil` on the setup-only
  /// composition, where `environment.authRecoveryModel` is `nil` because no authenticated client
  /// exists yet. Composed once with `environment` so its `isSheetPresented`/`username` state
  /// survives `RootView`'s frequent reconstruction and resets only on a login/logout boundary.
  let authRecoveryPresentation: AuthRecoveryPresentation?
  let endpointSwitchCoordinator: EndpointSwitchCoordinator?
  let serverAddressesModel: ServerAddressesModel?
  /// The Smart Lists models, carried to every surface through the environment. Nil on the setup
  /// and removal compositions.
  let smartLists: SmartListsAccess?

  /// `database`/`applicationSupportDirectory` are forwarded straight to `AppEnvironment` and exist
  /// for the same reason they do there: tests compose this real graph against an isolated
  /// in-memory store and a temporary storage root.
  convenience init(
    hardware: PlaybackHardware,
    mode: AppEnvironment.Mode,
    database: AppDatabase,
    accountState: AccountLaunchState? = nil,
    applicationSupportDirectory: URL? = nil
  ) {
    self.init(
      hardware: hardware, mode: mode, database: database, accountState: accountState,
      applicationSupportDirectory: applicationSupportDirectory,
      watchCompanionRuntime: .shared, widgetRuntime: .shared)
  }

  init(
    hardware: PlaybackHardware,
    mode: AppEnvironment.Mode,
    database: AppDatabase,
    accountState: AccountLaunchState? = nil,
    applicationSupportDirectory: URL? = nil,
    watchCompanionRuntime: WatchCompanionRuntime?,
    widgetRuntime: WidgetRuntime? = nil,
    focusPlaybackSpeed: FocusPlaybackSpeedState? = nil
  ) {
    let environment = launchSpan("composition.environment") {
      AppEnvironment(
        hardware: hardware,
        mode: mode,
        database: database,
        accountState: accountState,
        applicationSupportDirectory: applicationSupportDirectory)
    }
    self.environment = environment
    endpointSwitchCoordinator = environment.endpointSwitchCoordinator
    serverAddressesModel = environment.serverAddressesModel
    hardware.setRemoteCommandsEnabled(environment.composition == .runtime)

    let dependencies = environment.dependencies
    // The Focus filter's speed outlives every graph, so each new rate coordinator starts under it
    // and then receives later deliveries.
    // Defaulted here rather than in the signature: a default argument is evaluated nonisolated.
    let focusPlaybackSpeed = focusPlaybackSpeed ?? .shared
    let root = launchSpan("composition.rootModel") {
      RootModel(dependencies: dependencies, focusSpeed: focusPlaybackSpeed.focusSpeed)
    }
    launchMark("composition.rootModel.end")
    self.root = root
    focusPlaybackSpeed.bind(root.playbackRate)
    // The lock screen and CarPlay share the process-lifetime remote-command adapter, so it is
    // pointed at this account's rate coordinator on each rebuild, as `AppEnvironment` does for the
    // stream-authorization renewer.
    hardware.bindPlaybackRateCoordinator(root.playbackRate)
    hardware.bindPlaybackAvailability(
      playback: root.playback, connectivityModel: environment.connectivityModel)
    hardware.bindVoiceBoostShows(
      settings: environment.voiceBoostShowSettings, playback: root.playback)
    if environment.composition == .runtime {
      let voicePlaybackActions = VoicePlaybackActions(
        playback: root.playback,
        player: dependencies.player,
        account: dependencies.account,
        bookmarkStore: dependencies.playbackBookmarkStoring)
      self.voicePlaybackActions = voicePlaybackActions
      // The router holds both weakly; this composition owns them.
      let smartListPlayback = environment.smartListServices.map { _ in
        SmartListPlaybackAdapter(playback: root.playback)
      }
      self.smartListPlayback = smartListPlayback
      hardware.siriPlaybackActionRouter.bind(voicePlaybackActions, smartLists: smartListPlayback)
    } else {
      voicePlaybackActions = nil
      smartListPlayback = nil
      hardware.siriPlaybackActionRouter.unbind()
    }
    let runtimeAccount: (record: AccountRecord, identity: AccountIdentity)? =
      environment.composition == .runtime
      ? (try? AccountDAO(database: database).fetch()).flatMap { record in
        AccountIdentity(record: record).map { (record, $0) }
      }
      : nil
    // Independent of the Watch: the widgets publish whether or not one is paired.
    if let runtimeAccount {
      widgetSnapshotPublisher = widgetRuntime?.bind(
        identity: runtimeAccount.identity, dependencies: dependencies, playback: root.playback,
        artwork: environment.artworkClient, smartLists: environment.smartListServices,
        applicationSupportDirectory: applicationSupportDirectory)
    } else {
      widgetSnapshotPublisher = nil
      widgetRuntime?.unbind(applicationSupportDirectory: applicationSupportDirectory)
    }
    if let runtime = watchCompanionRuntime, let runtimeAccount {
      let (record, identity) = runtimeAccount
      let actions = CompanionPlaybackActions(
        playback: root.playback, player: dependencies.player, account: dependencies.account)
      companionPlaybackActions = actions
      watchCataloguePublisher = runtime.bind(
        actions: actions, dependencies: dependencies, playback: root.playback, identity: identity,
        accountRecord: record, artwork: environment.artworkClient,
        audioActivationWasRefused: { [weak engine = hardware.engine] in
          guard let result = engine?.lastSessionActivation else { return false }
          return !result.configurationSucceeded || !result.activationSucceeded
        })
    } else {
      companionPlaybackActions = nil
      watchCataloguePublisher = nil
      watchCompanionRuntime?.unbind()
    }
    launchMark("composition.bindings.end")
    homeModel = HomeModel(
      home: dependencies.homeReading, sync: dependencies.sync,
      savedShelf: dependencies.savedShelfReading,
      nativeContinueListening: dependencies.nativeContinueListeningReading,
      nativeSubscriptions: dependencies.nativePodcastSubscriptionsReading)
    podcastListeningModel = HomeModel(
      home: dependencies.homeReading, sync: dependencies.sync, filter: .podcasts,
      savedShelf: dependencies.savedShelfReading,
      nativeContinueListening: dependencies.nativeContinueListeningReading,
      nativeSubscriptions: dependencies.nativePodcastSubscriptionsReading)
    podcastLatestModel = HomeMoreModel(
      section: .newEpisodes, filter: .podcasts,
      home: dependencies.homeReading, sync: dependencies.sync,
      nativeLatestEpisodes: dependencies.nativeLatestPodcastEpisodesReading,
      nativeSubscriptions: dependencies.nativePodcastSubscriptionsReading)
    listeningStatsModel = ListeningStatsModel(
      stats: dependencies.listeningStatsAccess,
      uploadDrain: { [drain = environment.requestLocalSessionUploadDrain] in await drain() })
    podcastShowsOrderedModel = PodcastShowsModel(
      ordering: dependencies.podcastShowOrdering, library: dependencies.library,
      sync: dependencies.sync)
    nativePodcastShowsModel = NativePodcastShowsModel(
      reading: dependencies.nativePodcastShowsReading,
      ordering: dependencies.nativePodcastShowOrdering,
      subscriptions: dependencies.nativePodcastSubscriptionsReading,
      recoveryReading: dependencies.nativeFeedRecoveryReading,
      unfollowing: root.nativePodcastUnfollowing)
    addFeedModel = AddFeedModel(
      previews: dependencies.feedPreviewProviding,
      following: dependencies.nativeFeedFollowing,
      directory: dependencies.podcastDirectorySearching)
    subscriptionOPMLModel = PodcastSubscriptionOPMLModel(
      previews: dependencies.feedPreviewProviding,
      following: dependencies.nativeFeedFollowing,
      exporter: dependencies.nativeSubscriptionOPMLExporter)
    podcastNotificationSettingsModel = PodcastNotificationSettingsModel(
      preference: NotificationIntentAccess(
        reading: dependencies.notificationIntentReading,
        writing: dependencies.notificationIntentWriting),
      authorizer: dependencies.localNotificationAuthorizer,
      lifecycle: dependencies.rssNotificationLifecycle)
    rssNotificationRouteResolver = RSSNotificationRouteResolver(database: database)
    let downloadStatus = DownloadStatusStore(downloadReading: dependencies.downloadReading)
    self.downloadStatus = downloadStatus
    finishedStatus = FinishedStatusStore(library: dependencies.library)
    actions = ItemActionsModel(
      downloadStatus: downloadStatus,
      downloadIntents: dependencies.downloadIntents,
      progressIntents: dependencies.itemProgressIntents,
      extrasAccess: dependencies.extrasAccess,
      listeningQueue: dependencies.listeningQueueStoring,
      episodeIntents: root.podcastEpisodeIntents,
      savedShelf: dependencies.savedShelfStoring,
      savedStatus: root.savedStatus,
      continueListeningVisibility: root.continueListeningVisibility,
      ebookDelivery: dependencies.ebookDelivery,
      activeSmartListName: { [run = root.smartListRun] in run.activeListName })
    logoutPreflight = PlaybackLogoutPreflight(
      playback: root.playback, hardware: hardware,
      notifications: dependencies.rssNotificationLifecycle,
      watchCompanionRuntime: watchCompanionRuntime, widgetRuntime: widgetRuntime)
    authRecoveryPresentation = environment.authRecoveryModel.map(AuthRecoveryPresentation.init)
    smartLists = environment.makeSmartListsAccess(playback: root.playback)
    // The stats widget redraws when Home or the Stats screen fetches; nothing fetches for it.
    widgetSnapshotPublisher?.observeStats(listeningStatsModel)
  }
}

/// App-side composition of the Core playback preflight with process-wide system integrations.
/// Settings invokes this once before `AccountLifecycle.logout()`; the model stops/quiesces first,
/// then this boundary clears Now Playing and detaches remote commands.
@MainActor
final class PlaybackLogoutPreflight: LogoutPreflighting {
  private let playback: PlaybackModel
  private let hardware: PlaybackHardware
  private let watchCompanionRuntime: WatchCompanionRuntime?
  private let widgetRuntime: WidgetRuntime?
  private let notifications: any RSSNotificationLifecycleHandling

  init(
    playback: PlaybackModel, hardware: PlaybackHardware,
    notifications: any RSSNotificationLifecycleHandling = NoOpRSSNotificationLifecycle(),
    watchCompanionRuntime: WatchCompanionRuntime? = nil,
    widgetRuntime: WidgetRuntime? = nil
  ) {
    self.playback = playback
    self.hardware = hardware
    self.watchCompanionRuntime = watchCompanionRuntime
    self.widgetRuntime = widgetRuntime
    self.notifications = notifications
  }

  func prepareForLogout() async {
    await playback.prepareForLogout()
    watchCompanionRuntime?.unbind()
    widgetRuntime?.unbind()
    hardware.prepareForLogout()
    await notifications.disarm(feedID: nil)
  }

  /// Called only once a sign-out has completed. The desired Watch set belongs to the account that
  /// asked for it, so its rows go and the next empty offer clears the Watch; doing this in
  /// `prepareForLogout` would delete them when a later `logout()` throws and the user is still
  /// signed in.
  func accountRemoved() async {
    await watchCompanionRuntime?.clearEpisodeSendForAccountChange()
  }
}
