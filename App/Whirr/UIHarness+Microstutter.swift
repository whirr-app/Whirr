#if PERF_INVESTIGATION
  import AppModel
  import Foundation
  import DesignSystem
  import Persistence
  import SwiftUI
  import SyncEngine
  import UIKit

  /// A serverless shell fixture for the microstutter scenarios. It keeps the real Home,
  /// PodcastEpisodeCardSheet, and SettingsView in the same system-owned TabView presentation
  /// shape as production, while all data and actions come from UIHarnessSession.
  @MainActor
  struct MicrostutterFixtureView: View {
    let session: UIHarnessSession

    @State private var isSettingsPresented = false
    @State private var isEpisodeCardPresented = false
    @State private var episodeCallbackBox = EpisodeCallbackBox()
    /// The same two models `HarnessHomeScreen` owns, held here so this fixture's subscriptions also
    /// survive its re-renders.
    @State private var homeModels = HarnessHomeModels()

    private final class EpisodeCallbackBox {
      var action: ((String, String) -> Void)?
      lazy var callback: (String, String) -> Void = { [weak self] itemID, episodeID in
        self?.action?(itemID, episodeID)
      }
    }

    /// Equatable child boundary for isolating parent sheet-state updates. The dependency graph and
    /// callback box are both reference-stable; equality therefore leaves the mounted Home subtree
    /// alive while the outer presenter changes its sheet state. HomeView still observes its
    /// `HomeModel` and other model references inside this host.
    private struct MicrostutterHomeHost: View, Equatable {
      let session: UIHarnessSession
      let models: HarnessHomeModels
      let callbackBox: EpisodeCallbackBox

      static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session === rhs.session && lhs.models === rhs.models
          && lhs.callbackBox === rhs.callbackBox
      }

      private static let ignoreItem: (ItemSummary) -> Void = { _ in }
      private static let ignoreReader: (String, String, ItemMediaCategory) -> Void = { _, _, _ in }
      private static let ignoreResume: (String, String?) -> Void = { _, _ in }
      private static let ignoreString: (String) -> Void = { _ in }
      private static let ignoreRoute: (NavigationModel.Route) -> Void = { _ in }

      var body: some View {
        HomeView(
          model: models.home,
          latestEpisodesModel: models.latestEpisodes,
          coverClient: session.coverClient,
          paletteService: session.paletteService,
          playback: session.playback,
          actions: session.actions,
          onSelectItem: Self.ignoreItem,
          onPresentReader: Self.ignoreReader,
          onResumeListening: Self.ignoreResume,
          onSelectDownloadedPodcast: Self.ignoreItem,
          onSelectEpisode: callbackBox.callback,
          onOpenSection: Self.ignoreRoute,
          onSearch: Self.ignoreString
        )
      }
    }

    var body: some View {
      let tabs = TabView {
        Tab("Home", systemImage: "house") {
          NavigationStack {
            homeContent
              .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                  Button("Settings") { isSettingsPresented = true }
                }
              }
          }
        }
        Tab("Library", systemImage: "books.vertical") {
          NavigationStack { Color.clear.navigationTitle("Library") }
        }
      }
      .tabViewStyle(.sidebarAdaptable)
      .tabBarMinimizeBehavior(.never)

      Group {
        if MicrostutterAblation.minimalUnderlay {
          minimalUnderlay
        } else if MicrostutterAblation.blankUnderlay
          && (isSettingsPresented || isEpisodeCardPresented)
        {
          Color(uiColor: .systemBackground).ignoresSafeArea()
        } else {
          tabs
        }
      }
      .microstutterFixtureAccessory(
        isEnabled: !MicrostutterAblation.noAccessory && !MicrostutterAblation.minimalUnderlay,
        content: { fixtureAccessory }
      )
      .preferredColorScheme(MicrostutterAblation.fixtureLight ? .light : .dark)
      .overlay {
        if MicrostutterAblation.normalWindowTintAdjustment {
          MicrostutterWindowTintAdjustmentOverride()
        }
      }
      .onAppear {
        guard episodeCallbackBox.action == nil else { return }
        let episodePresentation = $isEpisodeCardPresented
        episodeCallbackBox.action = { _, _ in
          episodePresentation.wrappedValue = true
        }
      }
      .task {
        if MicrostutterAblation.playerPlaying || MicrostutterAblation.playerPaused {
          await session.playback.start(itemID: UIHarnessFixtures.itemID)
          if MicrostutterAblation.playerPaused { session.playback.togglePlayPause() }
        }
      }
      .onChange(of: isEpisodeCardPresented) { _, presented in
        if presented { session.paletteService.setCovered(true) }
      }
      .onChange(of: isSettingsPresented) { _, presented in
        if presented { session.paletteService.setCovered(true) }
      }
      .sheet(isPresented: $isEpisodeCardPresented, onDismiss: resumeWashIfUncovered) {
        PodcastEpisodeCardSheet(
          itemID: HarnessPodcastFixtures.longNotesShowID,
          episodeID: HarnessPodcastFixtures.longNotesEpisodeID,
          coverClient: session.coverClient,
          paletteService: session.paletteService,
          navigation: session.navigation,
          playback: session.playback,
          makeModel: {
            PodcastEpisodeCardModel(
              itemID: HarnessPodcastFixtures.longNotesShowID,
              episodeID: HarnessPodcastFixtures.longNotesEpisodeID,
              reading: HarnessPodcastReading(scenario: .offline))
          },
          host: PodcastEpisodeCardHost(openShow: { _ in }, search: { _ in })
        )
      }
      .sheet(isPresented: $isSettingsPresented, onDismiss: resumeWashIfUncovered) {
        NavigationStack {
          MicrostutterFixtureSettings(
            session: session,
            onDone: { isSettingsPresented = false }
          )
          .modifier(MicrostutterSheetAblation(onDismiss: { isSettingsPresented = false }))
          .adaptiveSheetPresentation(role: .large)
        }
      }
    }

    @ViewBuilder
    private var homeContent: some View {
      if MicrostutterAblation.staticHome {
        VStack(alignment: .leading, spacing: 24) {
          Button("Episode") { isEpisodeCardPresented = true }
            .accessibilityIdentifier("home.card.perf/episode")
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.section.newEpisodes")
        .navigationTitle("Home")
      } else if MicrostutterAblation.stableHomeHost {
        MicrostutterHomeHost(
          session: session, models: homeModels, callbackBox: episodeCallbackBox
        )
        .equatable()
      } else {
        HomeView(
          model: homeModels.home,
          latestEpisodesModel: homeModels.latestEpisodes,
          coverClient: session.coverClient,
          paletteService: session.paletteService,
          playback: session.playback,
          actions: session.actions,
          onSelectItem: { _ in },
          onSelectDownloadedPodcast: { _ in },
          onSelectEpisode: MicrostutterAblation.stableHomeCallback
            ? episodeCallbackBox.callback
            : { _, _ in isEpisodeCardPresented = true },
          onOpenSection: { _ in },
          onSearch: { _ in }
        )
      }
    }

    /// This stays constant before, during and after dismissal, avoiding the rebuild cost of
    /// the separate blank-underlay ablation. Only the two measured presentation controls remain.
    private var minimalUnderlay: some View {
      Color(uiColor: .systemBackground).ignoresSafeArea()
        .overlay(alignment: .top) {
          VStack(spacing: 32) {
            Button("Settings") { isSettingsPresented = true }
            Button("Episode") { isEpisodeCardPresented = true }
              .accessibilityIdentifier("home.card.perf/episode")
          }
          .padding(.top, 60)
          .accessibilityElement(children: .contain)
          .accessibilityIdentifier("home.section.newEpisodes")
        }
    }

    private func resumeWashIfUncovered() {
      session.paletteService.setCovered(isSettingsPresented || isEpisodeCardPresented)
    }

    @ViewBuilder
    private var fixtureAccessory: some View {
      if MicrostutterAblation.playerPlaying || MicrostutterAblation.playerPaused {
        MiniPlayerContainerView(
          playback: session.playback, connectivityModel: nil, player: session.player,
          library: session.library, nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
          coverClient: session.coverClient, onExpand: { _ in },
          contentColorScheme: .dark, paletteService: session.paletteService)
      } else {
        staticFixtureAccessory
      }
    }

    private var staticFixtureAccessory: some View {
      MiniPlayerView(
        title: UIHarnessFixtures.title,
        subtitle: UIHarnessFixtures.author,
        isPlaying: false,
        playPauseAccessibilityLabel: "Play",
        skipBackAccessibilityLabel: "Skip back",
        skipBackAccessibilityHint: "Skips backward.",
        skipBackSystemImage: "gobackward.15",
        skipForwardAccessibilityLabel: "Skip forward",
        skipForwardAccessibilityHint: "Skips forward.",
        skipForwardSystemImage: "goforward.30",
        progressAccessibilityValue: { "" },
        expandAccessibilityHint: "Opens the full player.",
        coverAccessibilityLabel: nil,
        isTitleMarqueeActive: false,
        contentColorScheme: .dark,
        cover: { Color.gray },
        onPlayPauseTap: {},
        onSkipBackTap: {},
        onSkipForwardTap: {},
        onExpandTap: {}
      )
      .accessibilityIdentifier("perf.fixture.miniPlayer")
    }
  }

  /// PERF-only public UIKit control for isolating automatic dimming at sheet handoff.
  /// The anchor records both inherited targets and restores them when removed from the window.
  /// Its readout is synchronous on the main actor and scoped to each measured sheet window.
  @MainActor
  struct MicrostutterWindowTintAdjustmentOverride: UIViewRepresentable {
    private static let readoutNames = ["P1", "P2", "S1", "S2", "P1T", "P2T", "S1T", "S2T"].map { label in
      CFNotificationName(
        rawValue: "com.remoteconcern.whirr.perf.read-tint.\(label)" as CFString)
    }

    func makeUIView(context: Context) -> WindowTintAnchor {
      let view = WindowTintAnchor()
      view.isUserInteractionEnabled = false
      view.isHidden = true
      return view
    }

    func updateUIView(_ uiView: WindowTintAnchor, context: Context) {
      uiView.applyIfNeeded()
    }

    @MainActor
    final class WindowTintAnchor: UIView {
      private weak var appliedWindow: UIWindow?
      private weak var appliedOwnerView: UIView?
      private var previousWindowMode: UIView.TintAdjustmentMode?
      private var previousOwnerMode: UIView.TintAdjustmentMode?
      nonisolated(unsafe) private var notificationObserver: UnsafeMutableRawPointer?
      private var isMutating = false

      override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
          unregisterReadout()
          restore()
        } else {
          registerReadout()
          applyIfNeeded()
        }
      }

      override func tintColorDidChange() {
        super.tintColorDidChange()
        applyIfNeeded()
      }

      func applyIfNeeded() {
        guard isMutating == false, let window,
          let ownerView = owningViewControllerView(in: window)
        else { return }
        isMutating = true
        defer { isMutating = false }
        if appliedWindow !== window || appliedOwnerView !== ownerView {
          restoreStoredModes()
          appliedWindow = window
          appliedOwnerView = ownerView
          previousWindowMode = window.tintAdjustmentMode
          previousOwnerMode = ownerView.tintAdjustmentMode
        }
        if window.tintAdjustmentMode != .normal {
          window.tintAdjustmentMode = .normal
        }
        if ownerView.tintAdjustmentMode != .normal {
          ownerView.tintAdjustmentMode = .normal
        }
      }

      private func owningViewControllerView(in window: UIWindow) -> UIView? {
        var responder: UIResponder? = self
        while let current = responder {
          if let viewController = current as? UIViewController { return viewController.view }
          responder = current.next
        }
        return window.rootViewController?.view
      }

      private func registerReadout() {
        guard notificationObserver == nil else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        notificationObserver = pointer
        let callback: CFNotificationCallback = { _, observer, name, _, _ in
          guard let observer, let name else { return }
          let anchor = Unmanaged<WindowTintAnchor>.fromOpaque(observer).takeUnretainedValue()
          let notification = name.rawValue as String
          let report = { @MainActor in anchor.reportReadout(notification: notification) }
          if Thread.isMainThread {
            MainActor.assumeIsolated { report() }
          } else {
            DispatchQueue.main.async(execute: report)
          }
        }
        for name in MicrostutterWindowTintAdjustmentOverride.readoutNames {
          CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), pointer, callback, name.rawValue, nil,
            .deliverImmediately)
        }
      }

      private func unregisterReadout() {
        guard let notificationObserver else { return }
        Self.removeReadoutObserver(notificationObserver)
        self.notificationObserver = nil
      }

      private func reportReadout(notification: String) {
        guard let window = appliedWindow, let ownerView = appliedOwnerView else {
          MicrostutterProbe.shared.note("tintReadout.invalid")
          return
        }
        let isNormal =
          window.tintAdjustmentMode == .normal && ownerView.tintAdjustmentMode == .normal
        MicrostutterProbe.shared.note(
          isNormal ? "tintReadout.normal" : "tintReadout.invalid")
      }

      nonisolated private static func removeReadoutObserver(_ observer: UnsafeMutableRawPointer) {
        for label in ["P1", "P2", "S1", "S2"] {
          let name = CFNotificationName(
            rawValue: "com.remoteconcern.whirr.perf.read-tint.\(label)" as CFString)
          CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), observer, name, nil)
        }
      }

      deinit {
        if let notificationObserver {
          Self.removeReadoutObserver(notificationObserver)
        }
      }

      private func restore() {
        guard isMutating == false else { return }
        isMutating = true
        defer { isMutating = false }
        restoreStoredModes()
      }

      /// Clears ownership before UIKit writes either value. `tintColorDidChange` can re-enter this
      /// anchor synchronously; the mutation guard then prevents a nested apply from capturing the
      /// just-restored mode as a new baseline.
      private func restoreStoredModes() {
        let ownerView = appliedOwnerView
        let ownerMode = previousOwnerMode
        let window = appliedWindow
        let windowMode = previousWindowMode
        appliedOwnerView = nil
        appliedWindow = nil
        previousOwnerMode = nil
        previousWindowMode = nil
        if let ownerView, let ownerMode { ownerView.tintAdjustmentMode = ownerMode }
        if let window, let windowMode { window.tintAdjustmentMode = windowMode }
      }
    }
  }

  private struct MicrostutterFixtureSettings: View {
    let session: UIHarnessSession
    let onDone: () -> Void

    var body: some View {
      SettingsView(
        account: HarnessAccountLifecycle(),
        downloadPreferences: NoOpDownloadPreferences(),
        resolutionCenterAccess: NoOpResolutionCenterAccess(),
        serverAccountReading: NoOpServerAccountReading(),
        librarySelectionReading: NoOpLibrarySelectionStore(),
        nativePodcastSubscriptionsReading: NoOpNativePodcastSubscriptionsReading(),
        nativePodcastSubscriptionsWriting: NoOpNativePodcastSubscriptionsWriting(),
        subscriptionOPMLModel: PodcastSubscriptionOPMLModel(),
        librarySelectionWriting: NoOpLibrarySelectionStore(),
        sync: SetupSyncCoordinator(),
        artworkCacheAccess: NoOpArtworkCacheAccess(),
        storageReading: NoOpStorageReading(),
        deviceStorageCapacityReading: NoOpDeviceStorageCapacityReading(),
        playbackRate: session.playbackRate,
        playback: session.playback,
        podcastSettingsReading: NoOpPodcastSettingsAccess(),
        podcastSettingsWriting: NoOpPodcastSettingsAccess(),
        podcastReading: NoOpPodcastReading(),
        podcastRefreshing: NoOpPodcastRefreshing(),
        nativeFeedManaging: NoOpNativeFeedManaging(),
        ambientColorScheme: .dark,
        manageDownloadsDestination: { Color.clear },
        resolutionCenterDestination: { Color.clear },
        onLoggedOut: {}
      )
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", role: .close, action: onDone)
        }
      }
    }
  }

  private struct MicrostutterFixtureAccessoryModifier<Accessory: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder let content: () -> Accessory

    @ViewBuilder
    func body(content: Content) -> some View {
      if isEnabled {
        content.tabViewBottomAccessory { self.content() }
      } else {
        content
      }
    }
  }

  extension View {
    fileprivate func microstutterFixtureAccessory<Accessory: View>(
      isEnabled: Bool, @ViewBuilder content: @escaping () -> Accessory
    ) -> some View {
      modifier(MicrostutterFixtureAccessoryModifier(isEnabled: isEnabled, content: content))
    }
  }
#endif
