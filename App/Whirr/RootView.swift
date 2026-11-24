import AppModel
import Combine
import DesignSystem
import Persistence
import ReaderCore
import SwiftUI
import SyncEngine
import UIKit
import WidgetProtocol

#if PERF_INVESTIGATION
  import QuartzCore
#endif

/// The app's one root view (ARCHITECTURE.md §1: the app target holds no conditional logic worth
/// testing). The only branching is a plain switch over already-tested model state
/// (`RootModel.navigation`'s presentation gate, `RootModel.setupFlow.state`, the no-library
/// recovery state). Coordination lives in `RootModel` (`RootModelTests`); this view re-runs it and
/// rebuilds `AppEnvironment` at the composition boundaries needing a concrete `ABSApi`/
/// `Persistence` type, which AppModel may never import: after login (so `SyncEngine` binds to the
/// real server), after logout, and after an endpoint switch.
struct RootView: View {
  /// The only stored dependency-graph reference, and it points at the process owner rather than a
  /// graph: SwiftUI reconstructs `RootView` inside its render loop, and every construction
  /// re-evaluates this. `AppRuntime` composes nothing until its `composition` is first read, and
  /// login/logout replace the graph there, which re-renders the shell.
  private let runtime: AppRuntime
  private var composition: RootComposition { runtime.composition }

  /// A default argument is evaluated nonisolated, so the process runtime is resolved here.
  init(runtime: AppRuntime? = nil) {
    self.runtime = runtime ?? .shared
  }

  /// Not `@AppStorage`: that invalidates on any `UserDefaults` write, and this is the root of the
  /// view tree. See `AppAppearanceStore`.
  private let appearanceStore = AppAppearanceStore.shared
  /// The reader is a full-screen cover rather than a navigation route. Nil keeps the window
  /// resolution unchanged.
  @State private var presentedReaderTheme: DesignSystem.ReaderTheme? = nil
  @State private var presentedReader: ReaderPresentationItem?
  /// The device's own light/dark setting, reported by the window scene rather than inferred from
  /// the environment this view overrides. `nil` only before the scene has reported once.
  @State private var deviceInterfaceStyle: ColorScheme?
  @State private var isLibrarySelectionPresented = false
  @State private var deferredNoLibrarySelection = DeferredModel<LibrarySelectionSettingsModel>()
  @State private var widgetTaps = WidgetTapInbox()
  /// This window's identity in `SceneRegistry`; `@State` scopes it to the scene.
  @State private var sceneID = SceneRegistry.SceneID(role: .phone, session: UUID().uuidString)
  @Environment(\.displayScale) private var displayScale
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.colorScheme) private var deviceColorScheme
  /// Read here because here it is still the window's; inside a sheet the same key describes the
  /// sheet. Published below so every presentation raised under this root can size itself from the
  /// window rather than from itself.
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass

  // The `PlayerController`/`AVQueuePlayer`/remote-command-registration singleton: one for the
  // process's lifetime, never part of a `RootComposition`. See `PlaybackHardware` for why it must
  // not be rebuilt alongside `environment`.
  private var hardware: PlaybackHardware { .shared }
  private var environment: AppEnvironment { composition.environment }
  private var root: RootModel { composition.root }
  private var homeModel: HomeModel { composition.homeModel }
  private var podcastListeningModel: HomeModel { composition.podcastListeningModel }
  private var podcastLatestModel: HomeMoreModel { composition.podcastLatestModel }
  private var podcastShowsOrderedModel: PodcastShowsModel { composition.podcastShowsOrderedModel }
  private var downloadStatus: DownloadStatusStore { composition.downloadStatus }
  private var finishedStatus: FinishedStatusStore { composition.finishedStatus }
  private var actions: ItemActionsModel { composition.actions }
  private var authRecoveryPresentation: AuthRecoveryPresentation? { composition.authRecoveryPresentation }
  /// Resolve System from the device rather than the window, which the reader may override.
  /// The environment is only a startup fallback until the scene reports its own style.
  private var effectiveAppColorScheme: ColorScheme {
    appearanceStore.appearance
      .colorScheme(ambient: deviceInterfaceStyle ?? deviceColorScheme)
  }
  private var noLibrarySelectionModel: LibrarySelectionSettingsModel {
    deferredNoLibrarySelection.resolve {
      LibrarySelectionSettingsModel(
        reading: environment.dependencies.librarySelectionReading,
        writing: environment.dependencies.librarySelectionWriting,
        sync: environment.dependencies.sync)
    }
  }

  var body: some View {
    let _ = launchMark("rootView.body presentation=\(root.navigation.presentation)")
    Group {
      switch root.navigation.presentation {
      case .setup:
        SetupFlowView(model: root.setupFlow)
      case .shell:
        if root.isNoAccessibleLibrary {
          NoAccessibleLibraryView(
            canChooseLibraries: root.canChooseLibraries,
            onRetry: { await root.retryLibraryResolution() },
            onChooseLibraries: { isLibrarySelectionPresented = true },
            onSignOut: { await signOutFromNoLibrary() }
          )
          .sheet(isPresented: $isLibrarySelectionPresented) {
            NavigationStack {
              LibrarySelectionSettingsView(model: noLibrarySelectionModel)
                .toolbar {
                  ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) {
                      isLibrarySelectionPresented = false
                    }
                  }
                }
            }
            .adaptiveSheetPresentation(role: .large)
          }
        } else if let browseModel = root.browseModel, let searchModel = root.searchModel {
          LibraryShellView(
            root: root,
            navigation: root.navigation,
            showsPodcastsTab: root.showsPodcastsTab,
            homeModel: homeModel,
            podcastListeningModel: podcastListeningModel,
            podcastLatestModel: podcastLatestModel,
            listeningStatsModel: composition.listeningStatsModel,
            podcastShowsOrderedModel: podcastShowsOrderedModel,
            nativePodcastShowsModel: composition.nativePodcastShowsModel,
            addFeedModel: composition.addFeedModel,
            subscriptionOPMLModel: composition.subscriptionOPMLModel,
            dependencies: LibraryShellDependencies(
              library: environment.dependencies.library,
              nativePodcastShowsReading: environment.dependencies.nativePodcastShowsReading,
              rssEpisodeArtworkReading: environment.dependencies.rssEpisodeArtworkReading,
              requestReachabilityProbe: environment.dependencies.requestReachabilityProbe,
              player: environment.dependencies.player,
              account: environment.dependencies.account,
              downloadReading: environment.dependencies.downloadReading,
              downloadIntents: environment.dependencies.downloadIntents,
              downloadPreferences: environment.dependencies.downloadPreferences,
              serverAccountReading: environment.dependencies.serverAccountReading,
              librarySelectionReading: environment.dependencies.librarySelectionReading,
              nativePodcastSubscriptionsReading:
                environment.dependencies.nativePodcastSubscriptionsReading,
              nativePodcastSubscriptionsWriting:
                environment.dependencies.nativePodcastSubscriptionsWriting,
              librarySelectionWriting: environment.dependencies.librarySelectionWriting,
              sync: environment.dependencies.sync,
              artworkCacheAccess: environment.dependencies.artworkCacheAccess,
              storageReading: environment.dependencies.storageReading,
              rssDownloadsReading: environment.dependencies.rssDownloadsReading,
              deviceStorageCapacityReading: environment.dependencies.deviceStorageCapacityReading,
              resolutionCenterAccess: environment.dependencies.resolutionCenterAccess,
              extrasAccess: environment.dependencies.extrasAccess,
              historyAccess: environment.dependencies.historyAccess,
              audioBookmarkIntents: environment.dependencies.audioBookmarkIntents,
              authorSeriesReading: environment.dependencies.authorSeriesReading,
              libraryCollections: environment.dependencies.libraryCollections,
              podcastReading: environment.dependencies.podcastReading,
              podcastSettingsReading: environment.dependencies.podcastSettingsReading,
              nativePodcastSettingsAccess: environment.dependencies.nativePodcastSettingsAccess,
              podcastSettingsWriting: environment.dependencies.podcastSettingsWriting,
              podcastRefreshing: environment.dependencies.podcastRefreshing,
              nativeFeedManaging: environment.dependencies.nativeFeedManaging,
              serverPodcastMutationCapabilityReading:
                environment.dependencies.serverPodcastMutationCapabilityReading,
              serverPodcastAutomationSettingsWriting:
                environment.dependencies.serverPodcastAutomationSettingsWriting,
              problemReportSources: environment.problemReportSources,
              problemReportExportDirectory: environment.diagnosticsExportDirectory,
              coverClient: environment.artworkClient,
              paletteService: environment.paletteService,
              connectivityModel: environment.connectivityModel,
              storageCeilingSummaryReading: environment.storageCeilingSummaryReading,
              requestLocalSessionUploadDrain: environment.requestLocalSessionUploadDrain,
              readerStateReading: environment.readerStateReading,
              readerTableOfContents: environment.readerTableOfContents,
              readerContentsAccess: environment.readerContentsAccess,
              supplementReading: environment.supplementReading,
              logoutPreflight: composition.logoutPreflight),
            browseModel: browseModel,
            searchModel: searchModel,
            playback: root.playback,
            downloadStatus: downloadStatus,
            finishedStatus: finishedStatus,
            actions: actions,
            playbackRate: root.playbackRate,
            serverAddressesModel: composition.serverAddressesModel,
            podcastNotificationSettingsModel: composition.podcastNotificationSettingsModel,
            effectiveAppColorScheme: effectiveAppColorScheme,
            onPresentReader: $presentedReader,
            makeHomeMoreModel: root.makeHomeMoreModel(section:filter:),
            makeSavedListModel: root.makeSavedForLaterListModel(filter:),
            makePodcastShowModel: root.makePodcastShowModel(itemID:initialFilter:),
            makeListeningQueueModel: root.makeListeningQueueModel,
            makePodcastEpisodeCardModel: root.makePodcastEpisodeCardModel(itemID:episodeID:),
            authRecoveryPresentation: authRecoveryPresentation,
            onLoggedOut: handleLoggedOut
          )
          // One shell per graph. A rebuild that keeps the user's location hands the fresh shell the
          // same routes, and without a new identity SwiftUI would keep the pushed destinations'
          // own state, with models built from the graph that was just shut down.
          .id(ObjectIdentifier(composition))
          .modifier(AuthRecoverySheetPresenter(authRecoveryPresentation: authRecoveryPresentation))
          // Read by the Up Next sheet, which is raised from inside this hierarchy.
          .environment(root.smartListRun)
          .environment(\.smartLists, composition.smartLists)
          .environment(\.timeSaved, TimeSavedComposition.store)
          .environment(\.watchCopies, WatchCopies.shared)
          .environment(
            \.showPlaybackEffects,
            environment.trimSilencesShowSettings.flatMap { trim in
              environment.voiceBoostShowSettings.map { voiceBoost in
                ShowPlaybackEffectsAccess(
                  trimSettings: trim, trimDefaults: PauseTrimComposition.preferences,
                  voiceBoostSettings: voiceBoost, voiceBoostDefault: UserDefaultsVoiceBoostDefault(),
                  playback: root.playback)
              }
            })
        } else {
          LoadingStateView(message: "Loading your library…")
        }
      case .removalPending:
        RemovalPendingView(onRetry: { await root.resumePendingRemovalIfNeeded() })
      }
    }
    .playbackStartFailureAlert(root.playback)
    // The Look Back tip's trigger, recorded durably the moment a sleep timer pauses a book: the
    // app may not come to the foreground again before the system ends it. Rebound per container.
    .task(id: ObjectIdentifier(root.playback)) {
      root.playback.onBookSleepTimerPause = { LookBackTipTrigger.recordSleepTimerPause() }
    }
    .playbackRateWriteFailureAlert(root.playbackRate)
    .fullScreenCover(
      item: $presentedReader,
      onDismiss: {
        presentedReaderTheme = nil
      }
    ) { reader in
      ReaderView(
        itemID: reader.itemID,
        title: reader.title,
        category: reader.category,
        stateReading: environment.readerStateReading,
        progress: environment.readerProgress,
        extrasAccess: environment.dependencies.extrasAccess,
        preferencesStore: environment.readerPreferencesStore,
        downloadIntents: environment.dependencies.downloadIntents,
        renderer: environment.dependencies.reader,
        appLifecycle: environment.dependencies.appLifecycle,
        playback: root.playback,
        onThemeChange: { theme in presentedReaderTheme = theme },
        initialTarget: reader.initialTarget
      )
    }
    // App appearance owns navigation and player chrome. Only the reader has an independent theme.
    .preferredColorScheme(
      CoverAmbientPresentation.windowColorScheme(
        appPreference: appearanceStore.appearance.preferredColorScheme,
        presentedReaderTheme: presentedReaderTheme)
    )
    .onAppear {
      launchMark("rootView.onAppear")
      launchMarkCommit("firstCommit")
      hardware.updateDisplayScale(displayScale)
      // Not only `.onChange`: a background App Intent can have started this process with no scene
      // at all and claimed the backgrounded tick cadence for it (`noteHeadlessEntry`). The phase
      // this scene launches with is not a change, so this is the only place that undoes it.
      SceneRegistry.shared.report(scenePhase, for: sceneID)
    }
    .onChange(of: displayScale) { _, newScale in
      hardware.updateDisplayScale(newScale)
    }
    .onChange(of: scenePhase) { _, newPhase in
      #if PERF_INVESTIGATION
        let isActivation = newPhase == .active
        let activeStart = isActivation ? CACurrentMediaTime() : 0
      #endif
      SceneRegistry.shared.report(newPhase, for: sceneID)
      #if PERF_INVESTIGATION
        if isActivation {
          MicrostutterProbe.shared.noteActivation(
            "RootView.scenePhase.active-callbacks",
            elapsed: CACurrentMediaTime() - activeStart,
            startedAt: activeStart)
        }
      #endif
    }
    .background {
      DeviceInterfaceStyleReader { style in
        deviceInterfaceStyle = style
      }
      .frame(width: 0, height: 0)
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
      PreparedArtworkCache.shared.removeAll()
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: PodcastNotificationRouteMailbox.receivedNotification)
    ) { _ in
      Task { await processPendingPodcastNotificationRoute() }
    }
    .task(id: root.navigation.presentation) {
      await processPendingPodcastNotificationRoute()
    }
    .onOpenURL { url in
      // Only the widgets' own links are accepted; any other URL, including the sign-in
      // callback's scheme, is ignored without being logged (SECURITY.md rules 10 and 21).
      guard let destination = WidgetTapDestination(url: url) else { return }
      widgetTaps.receive(destination)
      processWidgetTap()
    }
    .onChange(of: isLibraryShellMounted, initial: true) { _, _ in
      processWidgetTap()
    }
    .onChange(of: root.setupFlow.state) { _, newValue in
      if case .authenticated = newValue {
        rebuildComposition()
      }
    }
    .task {
      if let screen = SystemScreenBrightness() {
        ReaderBrightnessController(
          screen: screen,
          store: DefaultsReaderBrightnessStore()
        ).recoverStrandedBrightness()
      }
      WatchCopies.shared.start()
      runtime.start()
    }
    .onChange(of: runtime.generation) { _, _ in
      // A replacement the runtime made itself (an endpoint switch, or a removal completing at
      // launch) reaches this scene only here. A held widget tap's token belongs to the outgoing
      // graph.
      widgetTaps.clear()
    }
    .windowHorizontalSizeClass(horizontalSizeClass)
  }

  private func signOutFromNoLibrary() async -> Bool {
    // Reuse the App-composed preflight used by Settings before invoking the confirmed lifecycle
    // removal. This keeps the zero-library escape path from bypassing playback/system cleanup.
    await composition.logoutPreflight.prepareForLogout()
    guard await root.confirmLogout() else { return false }
    handleLoggedOut()
    return true
  }

  /// The scene's half of a graph replacement; `AppRuntime.rebuild` owns the rest.
  private func rebuildComposition() {
    // The account changed: a held widget tap's token belongs to the old graph.
    widgetTaps.clear()
    runtime.rebuild()
  }

  private func handleLoggedOut() {
    widgetTaps.clear()
    runtime.resetAfterLogout()
  }

  /// The `.shell` branch of `body` draws the library shell only in this state; before it, a
  /// loading or no-library screen stands in, and navigation applied then would surface later.
  private var isLibraryShellMounted: Bool {
    root.navigation.presentation == .shell && !root.isNoAccessibleLibrary
      && root.browseModel != nil && root.searchModel != nil
  }

  /// Context is read from the current composition when the tap is processed, never captured when
  /// it arrived.
  private func processWidgetTap() {
    guard let destination = widgetTaps.take(isLibraryShellMounted: isLibraryShellMounted) else { return }
    let runtime = WidgetRuntime.shared
    let action = WidgetTapRouter.action(
      for: destination, selection: { runtime.selection(for: $0) },
      listSelection: { runtime.listSelection(for: $0) }, listName: { runtime.smartListName(id: $0) })
    WidgetTapRouter.apply(
      action, to: root.navigation,
      context: WidgetTapContext(
        hasNowPlaying: root.playback.nowPlayingIdentity != nil, homeFilter: homeModel.filter,
        showsPodcastsTab: root.showsPodcastsTab))
  }

  private func processPendingPodcastNotificationRoute() async {
    guard root.navigation.presentation == .shell,
      let pending = PodcastNotificationRouteMailbox.shared.peek(),
      let resolved = try? await composition.rssNotificationRouteResolver.resolve(pending.route)
    else { return }
    // Consume only the entry this task resolved. Logout clears it; a later tap has a new identity,
    // so a task returning from the old account graph cannot remove or navigate that newer route.
    guard PodcastNotificationRouteMailbox.shared.consume(pending) else { return }
    root.navigation.navigate(to: resolved)
  }
}

/// Presents auth recovery's credential sheet over whatever the shell is showing.
///
/// The recovery state is the navigation bar's glyph in `LibraryShellView`'s toolbar; a banner would
/// cover the toolbar, so Settings, the only way to sign out of a stale account, could not be
/// tapped. Declared here because the sheet covers the whole shell, above any tab.
private struct AuthRecoverySheetPresenter: ViewModifier {
  let authRecoveryPresentation: AuthRecoveryPresentation?

  func body(content: Content) -> some View {
    content
      .sheet(
        isPresented: Binding(
          get: { authRecoveryPresentation?.isSheetPresented ?? false },
          set: { isPresented in
            guard let authRecoveryPresentation else { return }
            // The system calls this with `false` on an interactive swipe-down dismiss, which is
            // indistinguishable here from tapping Cancel (as in `PlayerPresentationBinding`).
            if isPresented == false { authRecoveryPresentation.cancel() }
          }
        )
      ) {
        if let authRecoveryPresentation {
          AuthRecoverySheetView(
            model: authRecoveryPresentation.model, presentation: authRecoveryPresentation
          )
          .adaptiveSheetPresentation(role: .large)
        }
      }
  }
}
