import Observation
import Persistence
import PlayerCore
import SyncEngine

/// Root observable the app shell binds to, and its coordination point.
/// `resolveLibraryIfAuthenticated()` decides from `AppDependencies` alone when library selection is
/// configured. Anything needing concrete `ABSApi`/`Persistence` types (the database, `ABSClient`,
/// recomposing after login) stays in the App target's `AppEnvironment`/`RootView`, since AppModel
/// may not import ABSApi (ARCHITECTURE.md §1).
@MainActor @Observable
public final class RootModel {
  public static let displayName = "ABS"

  public var displayName: String { Self.displayName }

  public let navigation: NavigationModel
  public let setupFlow: SetupFlowModel
  /// The one shared playback coordinator for the whole shell (ARCHITECTURE.md §6): browse, item
  /// detail, and search all drive this instance, and it survives every section change since it is
  /// constructed here rather than inside `resolveLibraryIfAuthenticated()`.
  public let playback: PlaybackModel
  /// The active smart list run, for the Up Next sheet and the Play Next copy. Reports no run when
  /// composition supplies none.
  public let smartListRun: SmartListRunModel
  /// The one owner of playback speed, per-title and default alike. The player's menu and sheet, a
  /// show's settings screen, and the lock screen must all edit the same value, and none may write
  /// to the store directly.
  public let playbackRate: PlaybackRateCoordinator
  /// The one saved-membership projection for the whole account graph. Every consumer shares this
  /// instance so `hasResolvedMembership` has one answer and membership never flashes per screen.
  public let savedStatus: SavedStatusStore?
  /// The one shared Continue Listening visibility projection for the whole account graph. Every
  /// consumer shares this instance so menus and rows agree about hidden membership.
  public let continueListeningVisibility: ContinueListeningVisibilityStore
  /// Shared by show detail and the native Your Shows grid so both entry points stop matching
  /// playback before deleting the device-owned feed cascade.
  public let nativePodcastUnfollowing: any NativePodcastUnfollowing
  public let podcastEpisodeIntents: any PodcastEpisodeIntents
  public private(set) var browseModel: LibraryBrowseModel?
  public private(set) var searchModel: SearchModel?
  /// True while an authenticated account has no included accessible library. This is distinct
  /// from the short interval before library resolution completes, so the shell always retains a
  /// retry and confirmed sign-out escape hatch.
  public private(set) var isNoAccessibleLibrary = false
  /// True when recovery can offer the saved library-selection screen. A library can be
  /// accessible while excluded on this device, which is distinct from an account for which the
  /// server currently exposes no libraries at all.
  public private(set) var canChooseLibraries = false
  /// Whether any accessible, included library is a podcast library; when false the shell hides the
  /// Podcasts tab, which is then provably empty. Starts `true` so the tab never flashes away, and
  /// hides only on evidence from the first selection snapshot.
  public private(set) var hasIncludedPodcastLibrary = true
  /// Device-owned native-feed availability, observed independently of account library selection.
  public private(set) var nativeSubscriptionsEnabled = true
  /// The Podcasts tab exists while either the selected server libraries or native subscriptions
  /// can provide content. Both inputs default on to avoid a cold-launch tab flash.
  public private(set) var showsPodcastsTab = true

  private let dependencies: AppDependencies

  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var selectionObservationTask: Task<Void, Never>?
  @ObservationIgnored private var nativeSubscriptionsObservationTask: Task<Void, Never>?
  @ObservationIgnored private var rssFeedRefreshLifecycleTask: Task<Void, Never>?
  @ObservationIgnored private var rssFeedRefreshTriggerTask: Task<Void, Never>?
  /// Settings keeps the shell mounted while its sheet is animating away. Selection observation
  /// continues during that interval, but its application is held so the tab bar cannot rebuild
  /// underneath the sheet.
  @ObservationIgnored private var isSettingsPresentationSuspended = false
  /// Whether this graph has already asked for its one first-resolution catalogue pull. Separate
  /// from `browseModel == nil` because `init` builds those models itself, so their existence does
  /// not mean a pull was issued. `rebuildComposition()` after login or an endpoint switch calls
  /// `resolveLibraryIfAuthenticated()` on a graph whose models already exist, and keying the pull
  /// on them would skip it and leave a fresh login unsynced.
  @ObservationIgnored private var hasRequestedFirstCataloguePull = false
  @ObservationIgnored private(set) var pendingSelectionSnapshot: LibrarySelectionSnapshot?

  /// `focusSpeed` is the Focus filter's speed as the App holds it across rebuilds; this graph's
  /// rate coordinator starts under it.
  public init(dependencies: AppDependencies, focusSpeed: FocusSpeed? = nil) {
    self.dependencies = dependencies
    // Every input this decision needs is synchronous (account restoration, the selection mode,
    // the removal journal), so the launch presentation is settled here rather than a scheduling
    // hop into the shell. A surviving removal wins outright: it gates login and setup alike, and
    // the async `resumePendingRemovalIfNeeded()` below performs the resume.
    navigation = NavigationModel(presentation: Self.launchPresentation(dependencies))
    setupFlow = SetupFlowModel(
      accountLifecycle: dependencies.account, libraryDiscovery: dependencies.librarySelectionDiscovery,
      librarySelectionWriting: dependencies.librarySelectionWriting,
      notificationLifecycle: dependencies.rssNotificationLifecycle)
    // Built before `PlaybackModel` because `start` resolves a title's speed through it before it
    // can send `.load`. Account-scoped like the rest of this container, and rebuilt with it.
    let playbackRate = PlaybackRateCoordinator(
      reading: dependencies.itemPlaybackSettingsReading,
      writing: dependencies.itemPlaybackSettingsWriting,
      preferences: dependencies.playbackPreferences,
      player: dependencies.player,
      focusSpeed: focusSpeed)
    self.playbackRate = playbackRate
    savedStatus = dependencies.savedShelfReading.map { SavedStatusStore(savedShelf: $0) }
    continueListeningVisibility = ContinueListeningVisibilityStore(library: dependencies.library)
    let playback = PlaybackModel(
      sync: dependencies.playbackSync, player: dependencies.player, account: dependencies.account,
      appLifecycle: dependencies.appLifecycle, bookmarkStore: dependencies.playbackBookmarkStoring,
      nativePodcastSubscriptions: dependencies.nativePodcastSubscriptionsReading,
      listeningQueue: dependencies.listeningQueueStoring, rateCoordinator: playbackRate,
      requestReachabilityProbe: dependencies.requestReachabilityProbe,
      downloadReading: dependencies.downloadReading, skipRanges: dependencies.skipRanges,
      timeSaved: dependencies.timeSaved, trim: dependencies.trim, continuation: dependencies.playbackContinuation)
    self.playback = playback
    smartListRun = dependencies.smartListRun ?? SmartListRunModel()
    nativePodcastUnfollowing = NativePodcastUnfollowAction(
      feedManaging: dependencies.nativeFeedManaging,
      stopPlayback: { [playback] itemID in
        try await playback.stopForNativeFeedUnfollow(itemID: itemID)
      })
    podcastEpisodeIntents =
      dependencies.makePodcastEpisodeIntents?(playback)
      ?? PlaybackPodcastEpisodeIntents(
        playback: playback,
        queue: dependencies.listeningQueueStoring,
        downloadIntents: dependencies.downloadIntents,
        progress: ABSEpisodeProgressBackend(progressIntents: dependencies.itemProgressIntents),
        savedShelf: dependencies.savedShelfStoring)
    observeSelectionReadiness()
    observeNativeSubscriptions()
    observeForegroundRSSRefresh()
    // Build browse/search now so the first frame is the shell, not "Loading your library…"; neither
    // does a synchronous database read. No pull here: on a cold launch the scene's first `.active`
    // reaches `SyncEngine` as a real `.foreground`. `RootView`'s `.task` calls it again, a no-op
    // unless a failed read left the models unbuilt.
    resolveLibraryAtColdLaunch()
  }

  /// The launch presentation, decided from synchronous boundaries only. A pending selection stays
  /// in setup; a removal that survived to this launch outranks both.
  private static func launchPresentation(_ dependencies: AppDependencies) -> NavigationModel.Presentation {
    if dependencies.isRemovalPendingSynchronously() { return .removalPending }
    guard dependencies.account.isAuthenticated, dependencies.isLibrarySelectionPending() == false
    else { return .setup }
    return .shell
  }

  deinit {
    refreshTask?.cancel()
    selectionObservationTask?.cancel()
    nativeSubscriptionsObservationTask?.cancel()
    rssFeedRefreshLifecycleTask?.cancel()
    rssFeedRefreshTriggerTask?.cancel()
  }

  public func makePodcastShowModel(
    itemID: String, initialFilter: PodcastEpisodeFilter = .all
  ) -> PodcastShowModel {
    PodcastShowModel(
      itemID: itemID,
      reading: dependencies.podcastReading,
      nativeEpisodeIDResolving: dependencies.nativeEpisodeIDResolving,
      refreshing: dependencies.podcastRefreshing,
      episodeIntents: podcastEpisodeIntents,
      savedStatus: savedStatus,
      continueListeningVisibility: continueListeningVisibility,
      settingsReading: dependencies.podcastSettingsReading,
      nativePodcastUnfollowing: nativePodcastUnfollowing,
      nativeFeedManaging: dependencies.nativeFeedManaging,
      nativeFeedRecoveryReading: dependencies.nativeFeedRecoveryReading,
      nativeEpisodeServerSaving: dependencies.nativeEpisodeServerSaving,
      nativeEpisodeServerSaveBatchSaving: dependencies.nativeEpisodeServerSaveBatchSaving,
      nativeEpisodeServerSaveRecovering: dependencies.nativeEpisodeServerSaveRecovering,
      nativeEpisodeServerSaveStatusReading: dependencies.nativeEpisodeServerSaveStatusReading,
      serverPodcastMutationCapabilityReading: dependencies.serverPodcastMutationCapabilityReading,
      nativePodcastSubscriptionsReading: dependencies.nativePodcastSubscriptionsReading,
      accountIdentityReading: dependencies.accountIdentityReading,
      librarySyncRequester: CoordinatorLibrarySyncRequester(sync: dependencies.sync),
      nativeShowsReading: dependencies.nativePodcastShowsReading,
      serverPodcastAutomationSettingsWriting: dependencies.serverPodcastAutomationSettingsWriting,
      initialFilter: initialFilter,
      activeSmartListName: { [run = smartListRun] in run.activeListName })
  }

  /// A Podcasts-tab selection is an explicit foreground correctness trigger. The coordinator
  /// coalesces this with a simultaneous lifecycle trigger and applies its own feed/time budgets.
  public func podcastsTabSelected() {
    let coordinator = dependencies.rssFeedRefreshCoordinator
    rssFeedRefreshTriggerTask = Task { _ = await coordinator.run(.foreground) }
  }

  /// The universal Up Next model. A factory rather than a stored property, so the observation
  /// over account-owned rows opens only when something presents it (the expanded player's sheet).
  public func makeListeningQueueModel() -> ListeningQueueModel {
    ListeningQueueModel(
      reading: dependencies.listeningQueueReading,
      storing: dependencies.listeningQueueStoring)
  }

  /// The episode card's own model, keyed by ref rather than by show. Takes the same dependencies
  /// as `makePodcastShowModel` plus the shared saved-membership projection, so the card cannot
  /// disagree with the show screen about an episode's state.
  public func makePodcastEpisodeCardModel(
    itemID: String, episodeID: String
  ) -> PodcastEpisodeCardModel {
    PodcastEpisodeCardModel(
      itemID: itemID,
      episodeID: episodeID,
      reading: dependencies.podcastReading,
      nativeEpisodeIDResolving: dependencies.nativeEpisodeIDResolving,
      episodeIntents: podcastEpisodeIntents,
      savedStatus: savedStatus,
      continueListeningVisibility: continueListeningVisibility,
      nativeEpisodeServerSaving: dependencies.nativeEpisodeServerSaving,
      nativeEpisodeServerSaveStatusReading: dependencies.nativeEpisodeServerSaveStatusReading,
      serverPodcastMutationCapabilityReading: dependencies.serverPodcastMutationCapabilityReading,
      nativeFeedManaging: dependencies.nativeFeedManaging,
      nativePodcastSubscriptionsReading: dependencies.nativePodcastSubscriptionsReading,
      accountIdentityReading: dependencies.accountIdentityReading,
      librarySyncRequester: CoordinatorLibrarySyncRequester(sync: dependencies.sync),
      activeSmartListName: { [run = smartListRun] in run.activeListName })
  }

  public func makeHomeMoreModel(section: HomeMoreSection, filter: MediaFilter) -> HomeMoreModel {
    HomeMoreModel(
      section: section, filter: filter, home: dependencies.homeReading, sync: dependencies.sync,
      nativeLatestEpisodes: dependencies.nativeLatestPodcastEpisodesReading,
      nativeContinueListening: dependencies.nativeContinueListeningReading,
      nativeSubscriptions: dependencies.nativePodcastSubscriptionsReading,
      storageReading: dependencies.storageReading)
  }

  public func makeSavedForLaterListModel(filter: MediaFilter) -> SavedForLaterListModel {
    SavedForLaterListModel(savedShelf: dependencies.savedShelfReading, filter: filter)
  }

  /// Call when `setupFlow.state` reaches `.authenticated` and after an endpoint switch. A no-op
  /// while signed out; without an included accessible library it publishes `isNoAccessibleLibrary`
  /// and stays in the shell for recovery. Never replaces built browse/search models or navigates
  /// away from a screen the user has moved to.
  ///
  /// Issues the first catalogue pull itself because the `ScenePhase` adapter is process-wide
  /// (`AppEnvironment.sharedLifecycle`): its phase is already `.active` when a rebuilt graph
  /// subscribes, and `ScenePhaseLifecycleMapper` maps `.active → .active` to no transition, so no
  /// `.foreground` ever arrives.
  public func resolveLibraryIfAuthenticated() {
    resolveLibraryIfAuthenticated(refreshOnFirstResolution: true)
  }

  /// The cold-launch entry: resolves as above without pulling. The scene's first `.active` is a
  /// real transition that `SyncEngine` hears (it subscribes synchronously at construction, before
  /// `RootView` runs), and an extra `.explicit` pull would cost a second full traversal, since it
  /// neither joins a running foreground traversal nor respects the minimum foreground interval.
  public func resolveLibraryAtColdLaunch() {
    resolveLibraryIfAuthenticated(refreshOnFirstResolution: false)
  }

  /// Re-runs library discovery, resolves selection again, and pulls the catalogue if this is the
  /// first successful resolution. The pull is needed because discovery only reconciles the library
  /// list, and nothing else triggers it here: otherwise the models stay over an empty catalogue
  /// until the next foreground. Settings inclusion goes through `librarySelectionDidIncludeLibrary`
  /// instead.
  public func retryLibraryResolution() async {
    guard dependencies.account.isAuthenticated else {
      isNoAccessibleLibrary = false
      return
    }
    _ = await dependencies.sync.refreshLibraryDiscovery()
    resolveLibraryIfAuthenticated(refreshOnFirstResolution: true)
  }

  /// The confirmed logout action used by the zero-library escape surface. The App target runs
  /// the same `LogoutPreflighting` boundary as Settings immediately before calling this method.
  /// The lifecycle swallows a failed remote confirmation only after local removal completes,
  /// matching `SettingsModel.confirmLogout()`; every thrown failure leaves the surface available.
  @discardableResult
  public func confirmLogout() async -> Bool {
    do {
      try await dependencies.account.logout()
      return true
    } catch {
      return false
    }
  }

  /// Holds library-selection application for the lifetime of the settings presentation. This is
  /// idempotent: a present edge and any repeated state reconciliation may both
  /// observe the same presentation without changing the queued snapshot.
  public func beginSettingsPresentation() {
    isSettingsPresentationSuspended = true
  }

  /// Releases the settings hold after the sheet's dismissal has completed. The navigation-state
  /// guard is the ABA protection for a stale dismissal callback: a new sheet may already be up
  /// when the old sheet's callback arrives. Only the newest snapshot observed while suspended is
  /// applied, and it is applied at most once for that suspension.
  public func finishSettingsPresentation() {
    guard navigation.settingsPresentation == .dismissed else { return }
    guard isSettingsPresentationSuspended else { return }

    isSettingsPresentationSuspended = false
    guard let pendingSelectionSnapshot else { return }
    self.pendingSelectionSnapshot = nil
    applySelectionSnapshot(pendingSelectionSnapshot)
  }

  /// Clears account-scoped selection-application state before resetting navigation for logout.
  /// The explicit wrapper matters when logout removes the shell before a sheet's `onDismiss` can
  /// run.
  public func resetForLogout() {
    isSettingsPresentationSuspended = false
    pendingSelectionSnapshot = nil
    navigation.resetForLogout()
  }

  private func resolveLibraryIfAuthenticated(refreshOnFirstResolution: Bool) {
    // A removal-pending launch gates the whole shell, including a re-entry that would otherwise
    // resolve the about-to-be-removed library right back into it.
    guard navigation.presentation != .removalPending else { return }
    guard dependencies.account.isAuthenticated else {
      isNoAccessibleLibrary = false
      return
    }
    guard dependencies.isLibrarySelectionPending() == false else {
      navigation.enterSetup()
      return
    }
    guard dependencies.hasConfiguredIncludedLibrary() else {
      isNoAccessibleLibrary = true
      navigation.enterShell()
      return
    }

    isNoAccessibleLibrary = false

    if browseModel == nil || searchModel == nil {
      browseModel = LibraryBrowseModel(library: dependencies.library, sync: dependencies.sync)
      searchModel = SearchModel(
        library: dependencies.library, searchReading: dependencies.searchReading,
        sync: dependencies.sync, recentSearchStore: dependencies.recentSearchStore)
    }

    // First resolution for a graph that gets no `.foreground` (login, endpoint switch, the recovery
    // Retry, API-CONVENTIONS rule 20), so nothing else issues its first pull. Cold launch skips
    // this; its foreground transition does arrive. Gated on its own flag because a rebuilt graph's
    // models already exist when it runs.
    if refreshOnFirstResolution, hasRequestedFirstCataloguePull == false {
      hasRequestedFirstCataloguePull = true
      let sync = dependencies.sync
      refreshTask?.cancel()
      refreshTask = Task { await sync.refresh() }
    }

    // Idempotent, and leaves the section and its path alone, so re-resolving the same library
    // cannot re-navigate a user who has moved to search/settings or pushed an item detail.
    navigation.enterShell()
  }

  /// Selection reconciliation and Settings writes can happen while the runtime shell is already
  /// visible. Keeping this observation at the shell boundary means loss (or restoration) of the
  /// last live included library changes the recovery state immediately, without requiring a
  /// foreground transition or a relaunch.
  private func observeSelectionReadiness() {
    let reading = dependencies.librarySelectionReading
    selectionObservationTask = Task { [weak self] in
      for await snapshot in reading.observeSelection() {
        guard Task.isCancelled == false, let self else { return }
        if self.isSettingsPresentationSuspended {
          self.pendingSelectionSnapshot = snapshot
        } else {
          self.applySelectionSnapshot(snapshot)
        }
      }
    }
  }

  private func applySelectionSnapshot(_ snapshot: LibrarySelectionSnapshot) {
    canChooseLibraries = snapshot.libraries.contains(where: \.isAccessible)
    updatePodcastAvailability(from: snapshot)
    resolveLibraryIfAuthenticated(refreshOnFirstResolution: false)
  }

  /// Applies one selection snapshot to the Podcasts tab's visibility. When the last accessible,
  /// included podcast library disappears, a user standing on that tab is moved to Home before
  /// the tab is removed (otherwise `TabView` picks a fallback itself), and the hidden section's
  /// stack is cleared so re-including the library later cannot restore a stale show from a
  /// library the user had excluded.
  private func updatePodcastAvailability(from snapshot: LibrarySelectionSnapshot) {
    let hasIncludedPodcastLibrary = snapshot.hasIncludedPodcastLibrary
    let showsPodcastsTab = hasIncludedPodcastLibrary || nativeSubscriptionsEnabled
    prepareForPodcastTabRemoval(ifShowing: showsPodcastsTab)
    self.hasIncludedPodcastLibrary = hasIncludedPodcastLibrary
    self.showsPodcastsTab = showsPodcastsTab
  }

  private func observeNativeSubscriptions() {
    let reading = dependencies.nativePodcastSubscriptionsReading
    nativeSubscriptionsObservationTask = Task { [weak self] in
      for await enabled in reading.observeEnabled() {
        guard Task.isCancelled == false, let self else { return }
        let wasEnabled = self.nativeSubscriptionsEnabled
        if wasEnabled && enabled == false {
          self.truncateNativePodcastDestinations()
          self.rssFeedRefreshTriggerTask?.cancel()
          let coordinator = self.dependencies.rssFeedRefreshCoordinator
          self.rssFeedRefreshTriggerTask = Task {
            for trigger in RSSFeedRefreshTrigger.allCases {
              await coordinator.cancel(trigger)
            }
          }
        }
        let showsPodcastsTab = self.hasIncludedPodcastLibrary || enabled
        self.prepareForPodcastTabRemoval(ifShowing: showsPodcastsTab)
        self.nativeSubscriptionsEnabled = enabled
        self.showsPodcastsTab = showsPodcastsTab
      }
    }
  }

  private func observeForegroundRSSRefresh() {
    let transitions = dependencies.appLifecycle.transitions
    let coordinator = dependencies.rssFeedRefreshCoordinator
    rssFeedRefreshLifecycleTask = Task {
      for await transition in transitions {
        guard Task.isCancelled == false else { return }
        guard transition == .foreground else { continue }
        _ = await coordinator.run(.foreground)
      }
    }
  }

  /// Removing the final source moves Podcasts to Home before the tab disappears, preventing
  /// `TabView` from choosing an arbitrary fallback and clearing content that is no longer valid.
  private func prepareForPodcastTabRemoval(ifShowing showsPodcastsTab: Bool) {
    guard self.showsPodcastsTab, showsPodcastsTab == false else { return }
    if navigation.section == .podcasts {
      navigation.section = .home
    }
    navigation[pathFor: .podcasts] = []
  }

  /// Native routes are device-owned and cannot remain visible after their feature is disabled.
  /// Truncating at the first native destination also removes anything pushed from it while
  /// preserving earlier ABS destinations on the same stack.
  private func truncateNativePodcastDestinations() {
    let path = navigation[pathFor: .podcasts]
    guard let nativeIndex = path.firstIndex(where: Self.isNativePodcastDestination) else { return }
    navigation[pathFor: .podcasts] = Array(path.prefix(upTo: nativeIndex))
  }

  private static func isNativePodcastDestination(_ route: NavigationModel.Route) -> Bool {
    switch route {
    case .nativePodcastShows:
      true
    case .podcastShow(let itemID, _, _):
      if PodcastSourceIdentity(itemId: itemID)?.rssFeedId != nil { true } else { false }
    default:
      false
    }
  }

  // MARK: - Removal-pending launch gate

  /// Call once at launch, before `resolveLibraryIfAuthenticated()`. A no-op unless
  /// `AccountLifecycle.isRemovalPending()` reports a removal that survived a crash. Until the
  /// resume succeeds (landing at the setup gate, like a logout) or fails, the whole shell stays
  /// behind `NavigationModel.Presentation.removalPending`. A failure
  /// (`AccountRemovalError.deletionFailed`) is not thrown: the gate stays up and calling again
  /// retries the idempotent resume.
  public func resumePendingRemovalIfNeeded() async {
    guard (try? await dependencies.account.isRemovalPending()) == true else { return }
    navigation.enterRemovalPendingGate()
    guard (try? await dependencies.account.resumeRemovalIfNeeded()) != nil else { return }
    resetForLogout()
  }
}
