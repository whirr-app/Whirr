import ABSApi
import AppModel
import DesignSystem
import Persistence
import PlayerCore
import ReaderCore
import SwiftUI
import SyncEngine

/// Every dependency composition hands `LibraryShellView`, in one value, grouped by where
/// `RootView` reads it: `AppDependencies`, then `AppEnvironment`'s own boundaries, then
/// `RootComposition`'s.
///
/// Models the shell composes (`HomeModel`, `PlaybackModel`, the download and item-action stores),
/// its `make*Model` factories and its presentation bindings stay explicit initializer parameters:
/// they are per-graph objects with identity, not dependency slots. No member here has a default,
/// so a dependency cannot arrive as a silent no-op.
struct LibraryShellDependencies {
  // MARK: environment.dependencies

  let library: any LibraryReading
  let nativePodcastShowsReading: any NativePodcastShowsReading
  /// The image the playing RSS episode declares; the players observe it through
  /// `playerEpisodeArtwork`.
  let rssEpisodeArtworkReading: any RSSEpisodeArtworkReading
  /// Drives the connectivity indicator's Retry. A probe is the whole action, since reachability
  /// recovering must never start audio on its own.
  let requestReachabilityProbe: @Sendable () -> Void
  let player: any PlaybackControlling
  let account: any AccountLifecycle
  /// Download/storage/resolution boundaries a screen strictly needs, threaded straight through
  /// from `AppEnvironment.dependencies` (`RootView`) and never rewired here.
  let downloadReading: any DownloadReading
  let downloadIntents: any DownloadIntents
  let downloadPreferences: any DownloadPreferences
  let serverAccountReading: any ServerAccountReading
  let librarySelectionReading: any LibrarySelectionReading
  let nativePodcastSubscriptionsReading: any NativePodcastSubscriptionsReading
  let nativePodcastSubscriptionsWriting: any NativePodcastSubscriptionsWriting
  let librarySelectionWriting: any LibrarySelectionWriting
  let sync: any SyncCoordinating
  let artworkCacheAccess: any ArtworkCacheAccess
  let storageReading: any StorageReading
  let rssDownloadsReading: any RSSDownloadsReading
  let deviceStorageCapacityReading: any DeviceStorageCapacityReading
  let resolutionCenterAccess: any ResolutionCenterAccess
  /// `ItemDetailView`'s Chapters/History tab boundaries.
  let extrasAccess: any ItemDetailExtrasAccess
  let historyAccess: any ListeningHistoryProviding
  let audioBookmarkIntents: any AudioBookmarkIntents
  /// `AuthorSeriesModel`'s boundary onto the live authors/series item-list fetch. Still
  /// `NoOpAuthorSeriesReading()` until the real `AuthorSeriesService` is wired into
  /// `AppEnvironment`.
  let authorSeriesReading: any AuthorSeriesReading
  /// The Collections mode's reads and fetch, and a list's screen.
  let libraryCollections: LibraryCollectionsAccess
  /// Reaches `.podcastSettings`/`.podcastShowSettings` and `SettingsView`'s Podcasts section.
  let podcastReading: any PodcastReading
  let podcastSettingsReading: any PodcastSettingsReading
  let nativePodcastSettingsAccess: (any (PodcastSettingsReading & PodcastSettingsWriting))?
  let podcastSettingsWriting: any PodcastSettingsWriting
  /// Show Settings' own on-demand item-detail fetch. The same boundary `makePodcastShowModel`
  /// closes over, so the screen can fill the server section when reached from Settings rather than
  /// from the show.
  let podcastRefreshing: any PodcastRefreshing
  let nativeFeedManaging: any NativeFeedManaging
  /// Show Settings' server automation editor (ADR 0017).
  let serverPodcastMutationCapabilityReading: any ServerPodcastMutationCapabilityReading
  let serverPodcastAutomationSettingsWriting: any ServerPodcastAutomationSettingsWriting

  // MARK: environment

  let problemReportSources: ProblemReportSources
  let problemReportExportDirectory: URL
  let coverClient: any ArtworkServing
  /// The account's palette service: every Home provider, the players, item detail and the
  /// background writers share it, so a colour any of them resolves reaches the others.
  let paletteService: CoverPaletteService
  let connectivityModel: ConnectivityModel?
  let storageCeilingSummaryReading: any StorageCeilingSummaryReading
  let requestLocalSessionUploadDrain: @concurrent @Sendable () async -> Void
  let readerStateReading: any ReaderStateReading
  let readerTableOfContents: any EPUBTableOfContentsReading
  let readerContentsAccess: any EbookTableOfContentsAccess
  /// Companion PDFs, read by item detail's supplement row and the player's overflow entry.
  let supplementReading: any ItemSupplementReading

  // MARK: composition

  let logoutPreflight: any LogoutPreflighting
}

/// The authenticated shell: tabs for Home, Library, Podcasts (see `showsPodcastsTab`) and Search,
/// each with its own `NavigationStack`. Settings is a sheet over the current tab, so it takes no
/// bottom-bar slot. `.sidebarAdaptable` gives a tab bar on iPhone and a sidebar on iPad.
struct LibraryShellView: View {
  let root: RootModel
  @Bindable var navigation: NavigationModel
  /// Whether the Podcasts tab exists. False only when `RootModel` has positive evidence that no
  /// accessible, included podcast library remains, so the tab would be provably empty. `RootModel`
  /// reroutes a user on the tab before flipping this.
  let showsPodcastsTab: Bool
  /// The Home tab's model, threaded straight through from `AppEnvironment.dependencies`/`RootView`.
  let homeModel: HomeModel
  let podcastListeningModel: HomeModel
  let podcastLatestModel: HomeMoreModel
  /// Home's listening-stats card and the Stats screen share this one instance.
  let listeningStatsModel: ListeningStatsModel
  /// The one model behind both the Podcasts root's Your Shows preview and the pushed
  /// `.podcastShows` all-shows page. `RootComposition` composes it once and `RootView` threads it
  /// through.
  let podcastShowsOrderedModel: PodcastShowsModel
  let nativePodcastShowsModel: NativePodcastShowsModel
  let addFeedModel: AddFeedModel
  let subscriptionOPMLModel: PodcastSubscriptionOPMLModel
  /// One value for every composition boundary this shell renders from; see
  /// `LibraryShellDependencies`. Models, stores and factories stay explicit parameters.
  let dependencies: LibraryShellDependencies
  let browseModel: LibraryBrowseModel
  let searchModel: SearchModel
  let playback: PlaybackModel
  /// The screen-wide download projection every browse/search/home row and context menu reads.
  /// Owned by `RootView` alongside `homeModel` so it is rebuilt on the same account/environment
  /// boundary, never per row or per render.
  let downloadStatus: DownloadStatusStore
  /// The screen-wide finished projection behind the browse rows' finished badges and item
  /// detail's cover checkmark. Owned by `RootView` beside `downloadStatus`, one per account.
  let finishedStatus: FinishedStatusStore
  /// The one item-action model behind every row's long-press menu, on every tab. Owned by
  /// `RootView` beside `downloadStatus`, one per account and never one per row.
  let actions: ItemActionsModel
  /// The shell-scoped owner of playback speed, threaded to the expanded player.
  let playbackRate: PlaybackRateCoordinator
  let serverAddressesModel: ServerAddressesModel?
  let podcastNotificationSettingsModel: PodcastNotificationSettingsModel
  /// The user's app appearance resolved against the device, independent of reader overrides.
  let effectiveAppColorScheme: ColorScheme
  @Binding var onPresentReader: ReaderPresentationItem?
  let makeHomeMoreModel: (HomeMoreSection, MediaFilter) -> HomeMoreModel
  /// The nil default keeps UI-harness compositions source-compatible; production supplies the
  /// account-scoped SavedShelfReading factory from RootView.
  let makeSavedListModel: @MainActor (MediaFilter) -> SavedForLaterListModel
  let makePodcastShowModel: (String, PodcastEpisodeFilter) -> PodcastShowModel
  /// The universal Up Next model's factory, threaded through to the expanded player, which is
  /// the only surface that opens the queue.
  let makeListeningQueueModel: () -> ListeningQueueModel
  /// The episode card's own model, keyed by ref. Composed like `makePodcastShowModel`, over the
  /// same `podcastReading`/`podcastEpisodeIntents` boundaries `RootModel` threads through.
  let makePodcastEpisodeCardModel: (String, String) -> PodcastEpisodeCardModel
  /// The shell's recovery indicator, beside connectivity's. `nil` in compositions that have no
  /// account to recover (setup). The credential sheet it opens is presented by `RootView`, one
  /// level above every tab.
  let authRecoveryPresentation: AuthRecoveryPresentation?
  let onLoggedOut: () -> Void

  /// One synchronous RSS artwork-source lookup for every player surface in this shell. It
  /// observes the followed-show projection for the shell's lifetime because playback bookmarks
  /// carry no artwork URLs and cannot answer the player's first-frame identity question.
  @State var followedShowArtworkSources: FollowedShowArtworkSources
  /// The image the playing RSS episode declares, observed once for the bar and the page.
  @State var playerEpisodeArtwork: PlayerEpisodeArtwork
  /// Which pushed screens are in multiselect edit mode. The shell owns the bottom accessory, so a
  /// selection screen anywhere in a tab's stack reports through this to take the mini-player down
  /// while its bulk actions hold the bottom bar. See `SelectionChromeModel`.
  @State var selectionChrome = SelectionChromeModel()
  /// What the system's accessory has actually been handed: the value `BottomAccessoryHost` enables
  /// it with, kept apart from the logical `effectiveAccessoryIsPresented` so a change can be
  /// applied inside an animation transaction, or without one, before the system sees it. Seeded
  /// without animation on first appearance.
  @State var showsAccessory = false
  /// The expanded cover renders this committed identity rather than live playback while the
  /// player-owned queue sheet is presenting or dismissing.
  @State var expandedPlayerPresentation = ExpandedPlayerPresentationModel()
  @Namespace private var bookZoomNamespace
  @State var bookZoomRegistry = BookZoomTransitionRegistry()
  @State var bookZoomRelay = BookZoomTransitionRelay()
  /// Where the mini player is, for collapsing the expanded player into it. Passed explicitly to
  /// the accessory and the presented page, neither of which inherits this view's environment.
  @State var playerMorphGeometry = PlayerMorphGeometry()
  /// The Library tab's callbacks, held behind a reference so `LibraryTabContent` can compare equal
  /// across shell body evaluations. See `LibraryTabRelay`.
  @State var libraryTabRelay = LibraryTabRelay()
  /// The covers currently allowed to carry a matched transition source. Membership is written
  /// on tap and cleared when the destination it fed has left its stack; see
  /// `BookZoomTransitionSourceModifier` for why the rest of the covers stay plain.
  @State var activeBookZoomSources: Set<BookZoomTransitionSource> = []
  @State var selectionTask: Task<Void, Never>?
  @State var artworkPreflight = LibrarySelectionArtworkPreflight()
  @State var librarySelectionEntry = LibrarySelectionEntry()
  /// Titles, Authors, and Series are Library browse modes, not bottom-bar destinations. Kept at
  /// shell lifetime so selection survives a trip to another tab. The Library filter is independent
  /// and remains available in the shared root toolbar for every mode.
  @State var libraryBrowseMode: LibraryBrowsePresentation.Mode = .titles
  @State var isAddFeedPresented = false
  /// A Read tapped inside the regular-width item-detail card, held until that card has gone. See
  /// `ReaderPresentationRelay`.
  @State var readerRelay = ReaderPresentationRelay()
  /// The system's reselect scroll stops at the top of the Library list's content, which leaves
  /// its browse chips and collapsed search drawer above the visible area. See
  /// `LibraryReselectRequests`.
  @State var libraryReselectRequests = LibraryReselectRequests()
  /// Keeps the `TabView` selection binding the same location across body evaluations.
  @State var tabSelectionRelay = LibraryTabSelectionRelay()
  @Environment(\.displayScale) var displayScale
  @Environment(\.smartLists) var smartLists
  @Environment(\.accessibilityReduceMotion) var reduceMotion
  /// The shell decides whether item detail pushes or is raised as a card (ADR 0008), so the
  /// size class is read here, once at the window, not inside item detail. A card's own content
  /// reports `.regular` regardless of the window, so the screen itself must not branch on it.
  @Environment(\.horizontalSizeClass) var horizontalSizeClass
  /// Read here and handed to the Settings sheet: this is where the app-level appearance
  /// preference has been resolved against the device, so "System" can be turned into the concrete
  /// scheme a presentation needs. See `AppAppearance.colorScheme(ambient:)`.
  @Environment(\.colorScheme) var colorScheme

  init(
    root: RootModel,
    navigation: NavigationModel,
    showsPodcastsTab: Bool = true,
    homeModel: HomeModel,
    podcastListeningModel: HomeModel,
    podcastLatestModel: HomeMoreModel,
    listeningStatsModel: ListeningStatsModel,
    podcastShowsOrderedModel: PodcastShowsModel,
    nativePodcastShowsModel: NativePodcastShowsModel,
    addFeedModel: AddFeedModel,
    subscriptionOPMLModel: PodcastSubscriptionOPMLModel,
    dependencies: LibraryShellDependencies,
    browseModel: LibraryBrowseModel,
    searchModel: SearchModel,
    playback: PlaybackModel,
    downloadStatus: DownloadStatusStore,
    finishedStatus: FinishedStatusStore,
    actions: ItemActionsModel,
    playbackRate: PlaybackRateCoordinator,
    serverAddressesModel: ServerAddressesModel? = nil,
    podcastNotificationSettingsModel: PodcastNotificationSettingsModel,
    effectiveAppColorScheme: ColorScheme,
    onPresentReader: Binding<ReaderPresentationItem?>,
    makeHomeMoreModel: @escaping (HomeMoreSection, MediaFilter) -> HomeMoreModel,
    makeSavedListModel: @escaping @MainActor (MediaFilter) -> SavedForLaterListModel = {
      SavedForLaterListModel(savedShelf: nil, filter: $0)
    },
    makePodcastShowModel: @escaping (String, PodcastEpisodeFilter) -> PodcastShowModel,
    makeListeningQueueModel: @escaping () -> ListeningQueueModel,
    makePodcastEpisodeCardModel: @escaping (String, String) -> PodcastEpisodeCardModel,
    authRecoveryPresentation: AuthRecoveryPresentation? = nil,
    onLoggedOut: @escaping () -> Void
  ) {
    #if PERF_INVESTIGATION
      let perfStart = ProcessInfo.processInfo.systemUptime
      defer {
        MicrostutterProbe.shared.note(
          "LibraryShellView.init", elapsed: ProcessInfo.processInfo.systemUptime - perfStart)
      }
    #endif
    self.root = root
    _navigation = Bindable(navigation)
    #if PERF_INVESTIGATION
      MicrostutterControl.register(navigation: navigation)
    #endif
    self.showsPodcastsTab = showsPodcastsTab
    self.homeModel = homeModel
    self.podcastListeningModel = podcastListeningModel
    self.podcastLatestModel = podcastLatestModel
    self.listeningStatsModel = listeningStatsModel
    self.podcastShowsOrderedModel = podcastShowsOrderedModel
    self.nativePodcastShowsModel = nativePodcastShowsModel
    self.addFeedModel = addFeedModel
    self.subscriptionOPMLModel = subscriptionOPMLModel
    self.dependencies = dependencies
    self.browseModel = browseModel
    self.searchModel = searchModel
    self.playback = playback
    self.downloadStatus = downloadStatus
    self.finishedStatus = finishedStatus
    self.actions = actions
    self.playbackRate = playbackRate
    self.serverAddressesModel = serverAddressesModel
    self.podcastNotificationSettingsModel = podcastNotificationSettingsModel
    self.effectiveAppColorScheme = effectiveAppColorScheme
    self._onPresentReader = onPresentReader
    self.makeHomeMoreModel = makeHomeMoreModel
    self.makeSavedListModel = makeSavedListModel
    self.makePodcastShowModel = makePodcastShowModel
    self.makeListeningQueueModel = makeListeningQueueModel
    self.makePodcastEpisodeCardModel = makePodcastEpisodeCardModel
    self.authRecoveryPresentation = authRecoveryPresentation
    self.onLoggedOut = onLoggedOut
    _playerEpisodeArtwork = State(
      initialValue: PlayerEpisodeArtwork(reading: dependencies.rssEpisodeArtworkReading))
    _followedShowArtworkSources = State(
      initialValue: FollowedShowArtworkSources(
        reading: dependencies.nativePodcastShowsReading,
        onSourceChanged: { itemID in
          dependencies.paletteService.sourceChanged(for: itemID)
        }))
  }

  private var effectiveAccessoryIsPresented: Bool {
    #if PERF_INVESTIGATION
      accessoryIsPresented && !MicrostutterAblation.noAccessory
    #else
      accessoryIsPresented
    #endif
  }

  /// The values the accessory's shown state is derived from, read together so a presence change
  /// that arrives in the same update as the player's own collapse still carries the player state it
  /// happened in. Only `BottomAccessoryPresenceHost` reads this: the shell's body must not depend on
  /// `navigation.playerPresentation`.
  fileprivate var accessoryPresentationInputs: AccessoryPresentationInputs {
    AccessoryPresentationInputs(
      isShown: effectiveAccessoryIsPresented,
      isSelecting: selectionChrome.isSelecting,
      isPlayerExpanded: navigation.playerPresentation == .expanded)
  }

  /// The relay's closures are refreshed on every body evaluation so they see the current copy of
  /// this view, while the environment value itself compares equal across evaluations. The relay
  /// is a plain class, not observed state, so writing it here is not a state mutation during
  /// update.
  private var bookZoomTransitionContext: BookZoomTransitionContext {
    bookZoomRelay.onSelectBook = { [self] item, source, artworkRole, displaySize in
      select(
        item, artworkRole: artworkRole, displaySize: displaySize,
        transitionSource: source)
    }
    bookZoomRelay.onDestinationDisappeared = { [self] source in
      // A child pushed on top, or a tab switch, also fires the destination's `onDisappear`; the
      // registry entry survives both, and the source with it.
      guard bookZoomRegistry.hasActiveEntry(for: source) == false else { return }
      activeBookZoomSources.remove(source)
    }
    return BookZoomTransitionContext(
      namespace: bookZoomNamespace,
      isEnabled: BookZoomTransitionPolicy.isAvailable && horizontalSizeClass == .compact
        && reduceMotion == false,
      relay: bookZoomRelay)
  }

  /// Refreshed on every body evaluation and read live when a morph starts, so a logout or a
  /// selection screen raised after this evaluation still slides.
  /// The relay's closure is unobserved, so writing it here is not a state mutation during update.
  private var refreshedPlayerMorphGeometry: PlayerMorphGeometry {
    playerMorphGeometry.canLand = { [self] in
      // The shown value, not the logical one: a morph needs a bar the system has mounted, and a
      // presence change leaves nothing to land on the moment it is applied.
      PlayerMorphGeometry.canLand(
        presentation: navigation.presentation,
        isAccessoryPresented: showsAccessory)
    }
    return playerMorphGeometry
  }

  /// The expanded player uses a UIKit-owned full-screen transition so the artwork-derived canvas
  /// can run edge to edge through the status-bar and home-indicator regions. A full-height `.sheet`
  /// is a card inset below the status bar, and no background modifier reaches past its own bounds.
  /// The transition owns pull-down dismissal while the player's controls retain their own gestures.
  var body: some View {
    #if PERF_INVESTIGATION
      let _ = MicrostutterProbe.shared.note("LibraryShellView.body")
      // Evaluated only under the flag: the ternary does not touch the property otherwise, so the
      // production default registers no presentation dependency here.
      let _ = MicrostutterAblation.inlineShellPresentation ? inlineShellPresentationFingerprint : 0
    #endif
    let morphGeometry = refreshedPlayerMorphGeometry
    tabs
      .environment(\.bookZoomTransitionContext, bookZoomTransitionContext)
      .environment(\.bookZoomActiveSources, activeBookZoomSources)
      #if PERF_INVESTIGATION
        .modifier(MicrostutterLiveTintAblation())
        .modifier(MicrostutterUnderlayAblation(navigation: navigation))
      #endif
      .environment(selectionChrome)
      .modifier(
        BottomAccessoryHost(
          isPresented: showsAccessory
        ) {
          MiniPlayerContainerView(
            playback: playback, connectivityModel: dependencies.connectivityModel, player: dependencies.player,
            library: dependencies.library, nativePodcastShowsReading: dependencies.nativePodcastShowsReading,
            coverClient: dependencies.coverClient,
            onExpand: { presentExpandedPlayer(seed: $0) },
            contentColorScheme: colorScheme,
            paletteService: dependencies.paletteService,
            followedShowArtworkSources: followedShowArtworkSources,
            episodeArtwork: playerEpisodeArtwork,
            metadataSeed: expandedPlayerPresentation.state.committed?.metadataSeed,
            playbackRate: playbackRate
          )
          .playerMorphAnchor(.bar)
          .playerMorphTarget()
          .environment(\.playerMorphGeometry, morphGeometry)
        }
      )
      .modifier(BottomAccessoryPresenceHost(shell: self, isShown: $showsAccessory))
      .modifier(ShellPresentationHost(shell: self))
      .modifier(
        PodcastsRootArrivalWarmup(
          isEnabled: showsPodcastsTab,
          showsModel: podcastShowsOrderedModel,
          nativeShowsModel: nativePodcastShowsModel,
          hasIncludedPodcastLibrary: root.hasIncludedPodcastLibrary,
          nativeSubscriptionsEnabled: root.nativeSubscriptionsEnabled,
          coverClient: dependencies.coverClient,
          service: dependencies.paletteService)
      )
      // Suspension is level-based across all three presentation states. Present edges raise the
      // level; each presentation's onDismiss releases it once the dismissal animation completes.
      // Recompute from current state so overlapping or stale callbacks cannot release work while
      // another presentation remains active.
      .onAppear {
        navigation.setItemDetailPresentation(resolvedItemDetailPresentation)
        updateEditorialWashSuspension()
        // A first appearance is the one presence change the system must not animate: a retained
        // title is simply already on screen.
        showsAccessory = effectiveAccessoryIsPresented
      }
      // A window that narrows mid-card (Split View, Slide Over, Stage Manager) returns to the
      // push, and `setItemDetailPresentation(.push)` drops the standing card so it cannot be
      // stranded at a width that has no card.
      .onChange(of: horizontalSizeClass) { _, _ in
        navigation.setItemDetailPresentation(resolvedItemDetailPresentation)
      }
      .onChange(of: playback.nowPlayingIdentity) { _, newValue in
        // Playing ends what the card was opened to do, and the mini-player arriving underneath a
        // standing modal conflicts with it (ADR 0008). Dropping it here catches every entry point
        // (Play, Resume, an episode row) without each knowing about the card.
        // `dismissItemDetail()` is a no-op when no card is up.
        if newValue != nil {
          navigation.dismissItemDetail()
        }
        guard navigation.playerPresentation == .expanded else { return }
        // A `nil` identity here means playback cleared (the retained title finished). The page
        // slides away; committing nothing would leave a transparent cover over the dimmed shell.
        if expandedPlayerPresentation.state.follow(liveIdentity: newValue) == .collapse {
          navigation.collapsePlayer(style: .slide)
        }
      }
  }
}

/// The three inputs behind the mini-player accessory's shown state, compared as one value by
/// `onChange`. A presence change that arrives in the same update as the player's collapse still
/// reports the player as expanded: the shell collapses it from an observer that runs after the body
/// evaluation reporting the cleared identity.
private struct AccessoryPresentationInputs: Equatable {
  let isShown: Bool
  let isSelecting: Bool
  let isPlayerExpanded: Bool
}

/// Applies each change of the accessory's presence inside an animation transaction when the system
/// should animate the bar in or out, and holds the value handed to `BottomAccessoryHost`.
///
/// A modifier of its own, not body code, because it reads `NavigationModel.playerPresentation`: in
/// the shell's body that dependency would rebuild the `TabView` and every retained tab offscreen on
/// each player open and close (see `ShellPresentationHost`).
private struct BottomAccessoryPresenceHost: ViewModifier {
  let shell: LibraryShellView
  @Binding var isShown: Bool

  func body(content: Content) -> some View {
    let inputs = shell.accessoryPresentationInputs
    return content.onChange(of: inputs) { oldValue, newValue in
      guard oldValue.isShown != newValue.isShown else { return }
      // Either copy saying "expanded" means the bar is covered: the old one when playback cleared
      // under the page, the new one when the page is already up.
      let isPlayerExpanded = oldValue.isPlayerExpanded || newValue.isPlayerExpanded
      if MiniPlayerAccessoryPresentation.animatesChange(
        selectionChanged: oldValue.isSelecting != newValue.isSelecting,
        isPlayerExpanded: isPlayerExpanded)
      {
        withAnimation(.smooth) { isShown = newValue.isShown }
      } else {
        isShown = newValue.isShown
      }
    }
  }
}

/// Uses SwiftUI's dynamic accessory API wherever it exists. The iOS 26.0 fallback attaches the
/// accessory conditionally, for deployment compatibility only. 26.1+ uses the single,
/// system-owned visibility path documented for `tabViewBottomAccessory(isEnabled:content:)`.
/// `isPresented` is the value the shell has already applied to the system
/// (`LibraryShellView.showsAccessory`), so its change is animated when it carries a transaction.
private struct BottomAccessoryHost<Accessory: View>: ViewModifier {
  let isPresented: Bool
  @ViewBuilder let accessory: () -> Accessory

  @ViewBuilder
  func body(content: Content) -> some View {
    if #available(iOS 26.1, *) {
      content.tabViewBottomAccessory(isEnabled: isPresented) { accessory() }
    } else if isPresented {
      content.tabViewBottomAccessory { accessory() }
    } else {
      content
    }
  }
}
