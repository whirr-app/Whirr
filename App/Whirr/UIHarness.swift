#if DEBUG || PERF_INVESTIGATION
  import ABSApi
  import AppModel
  import DesignSystem
  import Foundation
  import MediaPlayer
  import Persistence
  import PlayerCore
  import ReaderCore
  import SwiftUI
  import SyncEngine
  import UIKit
  import os

  /// Debug-only UI harness (`WHIRR_UI_HARNESS=1` in the scheme/launch environment): presents the
  /// expanded player over fake playback dependencies so player UI can be exercised in a simulator
  /// with no server, no login, and no real audio. The real `PlayerController`/`PlayerReducer`
  /// drive state; only `AudioEngine` below is simulated. Never compiled into release builds.
  enum UIHarness {
    static var isActive: Bool {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS"] == "1"
    }

    /// The appearance every harness screen pins rather than following the simulator, so screenshots
    /// are reproducible. `WHIRR_UI_HARNESS_SCHEME=light` flips it.
    static var harnessColorScheme: ColorScheme {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_SCHEME"] == "light" ? .light : .dark
    }

    static var runsScrollScript: Bool {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_SCROLL"] == "1"
    }

    static var scrollScriptDelay: Duration {
      let seconds =
        ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_SCROLL_DELAY"]
        .flatMap(Double.init) ?? 5
      return .milliseconds(Int64(max(0, seconds) * 1_000))
    }

    static var includesMiniPlayer: Bool {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_MINI_PLAYER"] == "1"
    }

    static var usesStaticMiniPlayerTitle: Bool {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_STATIC_MINI_PLAYER"] == "1"
    }
  }

  struct UIHarnessRootView: View {
    /// `UIHarnessRootView` is reconstructed by SwiftUI during rendering. Keep the heavyweight
    /// dependency graph behind the same run-once boundary as `AppRuntime`'s launch composition,
    /// or every reconstruction opens fresh model observations and the harness becomes the source
    /// of the invalidation churn it is meant to measure.
    private static let sharedSession = UIHarnessSession()
    @State var session = Self.sharedSession
    /// The window's, published below for the same reason `RootView` publishes it: a harness sheet
    /// has to size itself the way the shipping one does, or the capture proves nothing.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
      let scenario = UIHarnessScenario.current
      Group {
        #if PERF_INVESTIGATION
          if MicrostutterAblation.fixture {
            MicrostutterFixtureView(session: session)
          } else {
            selectedScreen(scenario)
          }
        #else
          selectedScreen(scenario)
        #endif
      }
      .windowHorizontalSizeClass(horizontalSizeClass)
    }

    @ViewBuilder
    private func selectedScreen(_ scenario: UIHarnessScenario) -> some View {
      #if DEBUG
        if PodcastFilesDevelopmentProbeView.isRequested {
          NavigationStack { PodcastFilesDevelopmentProbeView() }
        } else {
          configuredScreen(scenario)
        }
      #else
        configuredScreen(scenario)
      #endif
    }

    @ViewBuilder
    private func configuredScreen(_ scenario: UIHarnessScenario) -> some View {
      switch scenario.screen {
      case .player:
        playerBody
      case .detail:
        detailBody
      case .storage:
        storageBody
      case .home:
        homeBody
      case .homeShell:
        homeShellBody
      case .podcasts:
        podcastsBody
      case .podcastsNotificationOffer:
        podcastsNotificationOfferBody
      case .playerReduceAdsOffer:
        playerReduceAdsOfferBody
      case .podcastShow:
        podcastShowBody
      case .episodeCard:
        episodeCardBody
      case .detailCard:
        detailCardBody
      case .search:
        searchBody
      case .reader:
        readerBody
      case .library:
        libraryBody
      case .homeSettings:
        homeSettingsBody
      }
    }

    /// Retained for the screen files that pin an appearance; `UIHarness.harnessColorScheme` is the
    /// one definition.
    static var harnessColorScheme: ColorScheme { UIHarness.harnessColorScheme }

    /// `WHIRR_UI_HARNESS_SCREEN=storage`: the shared Downloads screen in a `NavigationStack`.
    ///
    /// Scenario fake: the byte totals and item rows come from downloaded files on disk, which a
    /// serverless harness process does not have.
    private var storageBody: some View {
      NavigationStack {
        DownloadsView(
          makeHomeModel: {
            HomeMoreModel(
              section: .downloaded, filter: .all,
              home: session.homeReading, sync: session.homeSync,
              storageReading: session.storageReading)
          },
          makePodcastShowModel: { itemID, filter in
            PodcastShowModel(
              itemID: itemID, reading: HarnessPodcastReading(scenario: UIHarness.podcastScenario),
              episodeIntents: NoOpPodcastEpisodeIntents(), initialFilter: filter)
          },
          storageReading: session.storageReading,
          nativeSubscriptionsEnabled: false,
          downloadIntents: session.downloadIntents,
          coverClient: session.coverClient,
          paletteService: session.paletteService,
          playback: session.playback,
          actions: session.actions,
          onSelectItem: { _ in },
          onPresentReader: { _, _, _ in },
          onSearch: { _ in })
      }
      .preferredColorScheme(Self.harnessColorScheme)
    }

    private var harnessPlayer: some View {
      ExpandedPlayerView(
        itemID: UIHarnessFixtures.itemID,
        playback: session.playback,
        // The harness runs without a server, so it has no reachability to report. Passed
        // explicitly because a silent default is how the production player would lose this
        // wiring without anything failing.
        connectivityModel: nil,
        player: session.player,
        library: session.library,
        nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
        coverClient: session.coverClient,
        navigation: session.navigation,
        paletteService: session.paletteService,
        actions: session.actions,
        playbackRate: session.playbackRate,
        finishedStatus: session.finishedStatus,
        extrasAccess: session.extrasAccess,
        authorSeriesReading: NoOpAuthorSeriesReading(),
        makeListeningQueueModel: { UIHarness.makeListeningQueueModel() },
        makeItemHistoryModel: { itemID in
          ItemHistoryModel(
            itemId: itemID, category: .audiobook, history: session.historyAccess)
        },
        effectiveAppColorScheme: Self.harnessColorScheme
      )
    }

    /// Embeds the real player over a loud presenter so the full-bleed ambient canvas can be checked
    /// independently of `LibraryShellView`'s full-screen presentation.
    ///
    /// Scenario fake: the audio engine is simulated on purpose (`HarnessAudioEngine`), so transport
    /// and buffering states reproduce without real hardware, and the item's metadata is a fixture
    /// because there is no server to resolve it from.
    private var playerBody: some View {
      ZStack {
        Color(red: 0.05, green: 0.45, blue: 0.4).ignoresSafeArea()
        Text("APP BEHIND THE PLAYER")
          .font(.title.bold())
          .foregroundStyle(.white)

        if UIHarness.presentsPlayerInteractively == false {
          harnessPlayer
        }
      }
      .harnessInteractivePlayer(colorScheme: Self.harnessColorScheme) { harnessPlayer }
      .task {
        await session.playback.start(itemID: UIHarnessFixtures.itemID)
        guard ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_SCRIPT"] == "1" else { return }
        // Scripted transport exercise for headless verification: pause at t+4, resume at t+8,
        // skip forward one hour at t+12. Screenshots taken between steps assert the UI
        // re-renders live (play/pause icon, elapsed time, scrubber position).
        try? await Task.sleep(for: .seconds(4))
        session.playback.togglePlayPause()
        try? await Task.sleep(for: .seconds(4))
        session.playback.togglePlayPause()
        try? await Task.sleep(for: .seconds(4))
        session.playback.seek(toGlobalOffset: session.playback.currentTime + 3600)
      }
    }

    /// `WHIRR_UI_HARNESS_SCREEN=detail`: the item-detail screen in a `NavigationStack`, using the
    /// harness's pinned light/dark scheme as the app-level input to the adaptive cover canvas,
    /// driven by the same fakes the player mode uses plus the harness's no-op download fakes.
    /// `WHIRR_UI_HARNESS_ITEM=mixed` swaps in the mixed audiobook+EPUB fixture; the default stays
    /// the plain audiobook so existing captures remain reproducible.
    ///
    /// Scenario fakes: chapters, description, series/narrator and listening history are
    /// server-owned reads (`ItemDetailExtrasAccess`, `ListeningHistoryProviding`), and no account
    /// or network exists to answer them.
    private var detailBody: some View {
      NavigationStack {
        HarnessItemDetailView(session: session)
      }
      .preferredColorScheme(Self.harnessColorScheme)
    }

    /// Scenario fakes: the reader needs an EPUB file on disk and the real Readium renderer, neither
    /// of which a simulator harness process has. `UIHarnessReaderScenario` selects the AppModel
    /// states and the chrome instead.
    private var readerBody: some View {
      ReaderView(
        itemID: UIHarnessFixtures.readerItemID,
        title: UIHarnessFixtures.readerTitle,
        category: .ebook,
        stateReading: session.readerStateReading,
        progress: session.readerProgress,
        preferencesStore: session.readerPreferencesStore,
        downloadIntents: session.downloadIntents,
        renderer: session.readerRenderer,
        appLifecycle: session.appLifecycle,
        injectedTOC: UIHarnessReaderScenario.tocEntries,
        initialPanel: UIHarnessReaderScenario.current.initialPanel
      )
      .preferredColorScheme(Self.harnessColorScheme)
    }

    /// `WHIRR_UI_HARNESS_SCREEN=home-settings`: Settings' Home editor in a `NavigationStack`.
    /// It reads and writes `@AppStorage` directly, so the harness only supplies the stack that
    /// gives it a navigation title and a back chevron.
    private var homeSettingsBody: some View {
      NavigationStack {
        HomeSettingsView()
      }
      .preferredColorScheme(Self.harnessColorScheme)
    }
  }

  /// Immutable fixture data is independent of the harness UI's main-actor state so
  /// nonisolated fakes can read it without crossing an actor boundary in Swift 6.
  nonisolated enum UIHarnessFixtures {
    static let itemID = "harness-item"
    static let title =
      "The 39 Steps and Other Richard Hannay Adventures: A BBC Radio Collection of Full-Cast Dramatisations"
    static let author = "John Buchan"
    /// Mirrors the series/narrator the detail extras fixture already returns, so the hero's credit
    /// block and the Chapters tab describe the same book.
    static let seriesName = "Richard Hannay Adventures #1"
    static let narratorName = "Full-Cast Ensemble, David Thorpe"
    static let duration: Double = 36_960
    /// Multi-track split for the harness: 4 files of 9240s each (see `HarnessPlaybackSyncing`).
    static let trackCount = 4
    static let trackLength: Double = 36_960 / 4
    static let readerItemID = "harness-reader-item"
    static let readerTitle = "A Harness EPUB"
    static let mixedItemID = "harness-mixed-item"
    static let mixedTitle = "A Mixed-Format Harness Item"
    static let mixedAuthor = "Harness Author"
    static let mixedNumAudioFiles = 4
    static let mixedEbookFormat = "epub"
    static let mixedCategory = ItemMediaCategory.derive(
      mediaKind: "book", numAudioFiles: mixedNumAudioFiles, ebookFormat: mixedEbookFormat)
    static let mixedHasReadableEbook = ItemMediaCategory.hasReadableEbook(ebookFormat: mixedEbookFormat)
    /// Screenshot-review fixtures: a short-titled series audiobook, an audiobook with no series at
    /// all, and an ebook-only item. The default fixture is long-titled and serialised, so on its
    /// own it cannot show what the hero does when a title fits on one line or when the credit
    /// block loses its series row.
    static let shortSeriesItemID = "harness-short-series-item"
    static let shortSeriesTitle = "Leviathan Wakes"
    static let shortSeriesAuthor = "James S. A. Corey"
    static let shortSeriesName = "The Expanse #1"
    static let shortSeriesNarrator = "Jefferson Mays"
    static let noSeriesItemID = "harness-no-series-item"
    static let noSeriesTitle = "Project Hail Mary"
    static let noSeriesAuthor = "Andy Weir"
    static let noSeriesNarrator = "Ray Porter"
    static let ebookItemID = "harness-ebook-item"
    static let ebookTitle = "The Left Hand of Darkness"
    static let ebookAuthor = "Ursula K. Le Guin"
    static let ebookFormat = "epub"
    static let ebookCategory = ItemMediaCategory.derive(
      mediaKind: "book", numAudioFiles: 0, ebookFormat: ebookFormat)
    static let ebookHasReadableEbook = ItemMediaCategory.hasReadableEbook(ebookFormat: ebookFormat)
  }

  /// One harness process's shared state: the app's own composition, the simulated audio hardware
  /// and the fixtures more than one screen reads. Screen-specific fixtures and models live in
  /// `UIHarness+<Screen>.swift`.
  ///
  /// `UIHarnessRootView` is reconstructed by SwiftUI during rendering, so this is held behind the
  /// same run-once boundary as `AppRuntime`'s launch composition: one `RootComposition`, one
  /// `PlayerController`, one palette service, and one subscription per shared model for the life of
  /// the process.
  @MainActor
  @Observable
  final class UIHarnessSession {
    /// The app's graph, built by the same `RootComposition` initializer `AppRuntime`'s factory calls.
    /// Built on first use, not in `init`: a hosted player test constructs a session for its fixtures
    /// alone and must not pay for an `AppEnvironment`.
    ///
    /// It runs against an isolated store (in-memory database, temporary support directory) and the
    /// setup composition, because the harness has no account. Nothing it owns reaches the user's
    /// database, keychain items or downloads; the one node the screens read, `paletteService`, is
    /// the app's own service over that isolated store, so palette extraction shares the app's record
    /// store and admission rather than being a second writer.
    var composition: RootComposition {
      if let storedComposition { return storedComposition }
      let built = Self.makeComposition()
      storedComposition = built
      return built
    }

    private var storedComposition: RootComposition?

    let navigation = NavigationModel(presentation: .shell)
    let library: any LibraryReading = HarnessLibraryReading()
    let downloadReading: any DownloadReading = HarnessDownloadReading()
    let downloadIntents: any DownloadIntents = HarnessDownloadIntents()
    let storageReading: any StorageReading = HarnessStorageReading()
    let extrasAccess: any ItemDetailExtrasAccess = HarnessItemDetailExtrasAccess()
    let historyAccess: any ListeningHistoryProviding = HarnessListeningHistoryProviding()
    let readerStateReading: any ReaderStateReading
    let readerTableOfContents: any EPUBTableOfContentsReading = HarnessEPUBTableOfContentsReading()
    let readerProgress: any ReaderProgressAccessing
    let readerPreferencesStore: any ReaderPreferencesStoring
    let readerRenderer: UIHarnessFakeEPUBRendering
    let appLifecycle: any AppLifecycle = HarnessAppLifecycle()
    let homeReading: any HomeReading = HarnessHomeReading()
    let homeSavedShelf: any SavedShelfReading = HarnessSavedShelfReading()
    let homeSync: any SyncCoordinating = HarnessSyncCoordinating()
    let coverClient: CoverImageClient
    let player: PlayerController
    let playback: PlaybackModel
    let playbackRate: PlaybackRateCoordinator
    /// The app's one palette service for this process, over the composition's isolated record
    /// store, as production composes one per account. Not a second writer over a separate store.
    var paletteService: CoverPaletteService { composition.environment.paletteService }
    /// The harness's own screen-wide download projection. Held here so the one subscription
    /// survives re-renders, as `homeModel` does.
    let downloadStatus: DownloadStatusStore
    /// The harness's own finished-state projection, held for the same reason as `downloadStatus`.
    let finishedStatus: FinishedStatusStore
    /// The harness's own screen-scoped item-action model.
    let actions: ItemActionsModel

    init() {
      // A local catch-all image server (if one is running on 9977) makes cover fetches succeed so
      // the cover-driven ambient background is exercised; with nothing listening, fetches fail
      // fast and the placeholder renders instead.
      #if PERF_INVESTIGATION
        if MicrostutterAblation.coldArtwork {
          // A memory-only client and its own scope isolate this fixture process. The live
          // disposable cache and account state are never opened, cleared, or touched.
          coverClient = CoverImageClient(
            server: try! ABSServerConfig(url: URL(string: "http://127.0.0.1:9977")!),
            artworkScope: MicrostutterArtworkFixture.scope)
        } else {
          coverClient = CoverImageClient(
            server: try! ABSServerConfig(url: URL(string: "http://127.0.0.1:9977")!))
        }
      #else
        coverClient = CoverImageClient(
          server: try! ABSServerConfig(url: URL(string: "http://127.0.0.1:9977")!))
      #endif
      // The app's shared admission, so the probes measure the extraction queue the app runs.
      let engine = HarnessAudioEngine()
      player = PlayerController(engine: engine, clock: SystemPlaybackClock())
      // Serverless like the rest of the harness: no account database, so the no-op access reports
      // no overrides and every title resolves to the default.
      let playbackRate = PlaybackRateCoordinator(
        reading: NoOpItemPlaybackSettingsAccess(),
        writing: NoOpItemPlaybackSettingsAccess(),
        preferences: UserDefaultsPlaybackPreferences(),
        player: player)
      self.playbackRate = playbackRate
      playback = PlaybackModel(
        sync: HarnessPlaybackSyncing(),
        player: player,
        account: HarnessAccountLifecycle(),
        appLifecycle: HarnessAppLifecycle(),
        rateCoordinator: playbackRate
      )
      let readerScenario = UIHarnessReaderScenario.current
      readerRenderer = UIHarnessFakeEPUBRendering(scenario: readerScenario)
      readerStateReading = HarnessReaderStateReading(scenario: readerScenario)
      readerProgress = HarnessReaderProgressAccess()
      readerPreferencesStore = HarnessReaderPreferencesStore(scenario: readerScenario)
      let downloadStatus = DownloadStatusStore(downloadReading: downloadReading)
      self.downloadStatus = downloadStatus
      finishedStatus = FinishedStatusStore(library: library)
      actions = ItemActionsModel(
        downloadStatus: downloadStatus,
        downloadIntents: downloadIntents,
        progressIntents: NoOpItemProgressIntents(),
        extrasAccess: extrasAccess)
    }

    /// The app's own factory, from the initializer `AppRuntime`'s `makeComposition` calls, with the
    /// inputs a harness can supply: isolated storage, a temporary support root, and a hardware stack
    /// whose remote-command centre is a no-op so it cannot register a second set of handlers on the
    /// process-wide `MPRemoteCommandCenter`. `mode: .automatic` with no account composes the
    /// setup-only graph, so no account, sync or network service starts.
    private static func makeComposition() -> RootComposition {
      let directory = FileManager.default.temporaryDirectory.appending(
        path: "whirr-ui-harness-\(UUID().uuidString)", directoryHint: .isDirectory)
      return RootComposition(
        hardware: PlaybackHardware(
          remoteCommandCenter: HarnessRemoteCommandCenter(), defaults: HarnessPreferences.defaults),
        mode: .automatic,
        database: try! AppDatabase.inMemory(),
        applicationSupportDirectory: directory,
        watchCompanionRuntime: nil,
        widgetRuntime: nil)
    }
  }
#endif
