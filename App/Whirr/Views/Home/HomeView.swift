import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI
import SyncEngine

/// Root orchestration for the Home tab. Presentation derivation lives in `HomeViewPresentation`;
/// shelf layout and cards are standalone child views. This type retains ownership of
/// the single List, filter geometry, loading overlay, refresh, and screen-lifetime artwork state.
struct HomeView: View {
  @Bindable var model: HomeModel
  /// The same instance rendered by Podcasts and the pushed Latest Episodes list.
  @Bindable var latestEpisodesModel: HomeMoreModel
  /// `nil` in harness compositions, which leaves the listening-stats card out entirely.
  let listeningStatsModel: ListeningStatsModel?
  let coverClient: any ArtworkServing
  let playback: PlaybackModel
  /// One screen-scoped model behind every card's long-press menu.
  let actions: ItemActionsModel
  /// Resolves a server title to its catalogue row, for the stats split's book/podcast sides.
  let catalogued: (String) -> ItemSummary?
  let onSelectItem: (ItemSummary) -> Void
  let onPresentReader: (String, String, ItemMediaCategory) -> Void
  let onResumeListening: (String, String?) -> Void
  let onSelectDownloadedPodcast: (ItemSummary) -> Void
  let onSelectEpisode: (String, String) -> Void
  let onOpenSection: (NavigationModel.Route) -> Void
  let onSearch: (String) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.displayScale) private var displayScale
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.smartLists) private var smartLists
  @Environment(\.timeSaved) private var timeSaved

  /// Not `@AppStorage`: this is a tab root, and that invalidates on any `UserDefaults` write.
  /// See `HomeSectionPreferencesStore`.
  private let sectionPreferences = HomeSectionPreferencesStore.shared

  /// Measured because the filter row moves with Dynamic Type and the placeholder fills the rest.
  @State private var filterRowHeight: CGFloat = 0
  @State private var availableWidth: CGFloat = 0
  /// False until Home has been `.loading` for `HomeViewPresentation.loadingPlaceholderDelay`, so a
  /// launch that resolves promptly never paints a spinner over already-correct chrome.
  @State private var hasWaitedForContent = false
  /// Held for the duration of a pull-to-refresh. A shelf change animated while the refresh control
  /// retracts animates the safe-area inset without carrying `contentOffset` with it, which parks
  /// the scroll view in overscroll.
  @State private var isRefreshing = false
  @State private var smartListEditorRequest: SmartListEditorRequest?
  @State private var artworkPrefetchController: HomeArtworkPrefetchController
  @State private var homeWashProvider: HomeWashProvider

  static let cardCoverSize: CGFloat = 140
  /// Compact shelves retain this existing minimum-sized card; regular shelves resolve their width
  /// from the measured viewport while keeping the request tier above unchanged.
  static let cardWidth: CGFloat = cardCoverSize + 2 * WhirrSpacing.small

  init(
    model: HomeModel,
    latestEpisodesModel: HomeMoreModel,
    listeningStatsModel: ListeningStatsModel? = nil,
    coverClient: any ArtworkServing,
    paletteService: CoverPaletteService,
    playback: PlaybackModel,
    actions: ItemActionsModel,
    catalogued: @escaping (String) -> ItemSummary? = { _ in nil },
    onSelectItem: @escaping (ItemSummary) -> Void,
    onPresentReader: @escaping (String, String, ItemMediaCategory) -> Void = { _, _, _ in },
    onResumeListening: @escaping (String, String?) -> Void = { _, _ in },
    onSelectDownloadedPodcast: @escaping (ItemSummary) -> Void,
    onSelectEpisode: @escaping (String, String) -> Void,
    onOpenSection: @escaping (NavigationModel.Route) -> Void,
    onSearch: @escaping (String) -> Void
  ) {
    #if PERF_INVESTIGATION
      let perfInitStart = ProcessInfo.processInfo.systemUptime
      defer {
        MicrostutterProbe.shared.note(
          "HomeView.init", elapsed: ProcessInfo.processInfo.systemUptime - perfInitStart)
      }
    #endif
    _model = Bindable(model)
    _latestEpisodesModel = Bindable(latestEpisodesModel)
    self.listeningStatsModel = listeningStatsModel
    self.coverClient = coverClient
    self.playback = playback
    self.actions = actions
    self.catalogued = catalogued
    self.onSelectItem = onSelectItem
    self.onPresentReader = onPresentReader
    self.onResumeListening = onResumeListening
    self.onSelectDownloadedPodcast = onSelectDownloadedPodcast
    self.onSelectEpisode = onSelectEpisode
    self.onOpenSection = onOpenSection
    self.onSearch = onSearch
    _artworkPrefetchController = State(initialValue: HomeArtworkPrefetchController())
    _homeWashProvider = State(
      initialValue: HomeWashProvider(
        service: paletteService,
        displaySize: Self.cardCoverSize,
        displayScale: 1,
        artworkRole: .homeCard))
  }

  var body: some View {
    #if PERF_INVESTIGATION
      let _ = MicrostutterAblation.logViewChanges ? Self._logChanges() : ()
      let _ = MicrostutterProbe.shared.note("HomeView.body")
    #endif
    CleanRoomPerformanceSignposts.withInterval("HomeView.body") {
      content.itemActionErrorAlert(actions)
        #if PERF_INVESTIGATION
          .modifier(MicrostutterHomeGeometryAblation())
        #endif
    }
  }

  /// The filter and all shelves stay in one eager stack, not a `List` or lazy stack. The page is
  /// bounded (one row per shelf kind) and each shelf's cards are already lazy; a lazy page rebuilds
  /// a shelf that left range and re-measures its strip, which ran in every Home scroll hitch.
  ///
  /// A `List` cell lays out its whole SwiftUI subtree on nearly every scroll frame, and its single
  /// context-menu interaction would swallow every card's menu unless each shelf were wrapped in a
  /// nested `UIHostingController`: at ten times the shipping fixture size, ~2,350 hosted layout
  /// passes and ~400 ms of layout in a 7.9-second scroll, 99.5% at unchanged bounds. On iOS 27 such
  /// a nested menu doesn't present at all, which is why Podcasts is a stack too. A stack has no
  /// cells, so each card owns its menu.
  private var content: some View {
    let elements = contentElements
    let firstShelfID = elements.first(where: { $0.section != nil })?.id
    let washPreloadSubjects = elements.compactMap(\.section).flatMap {
      HomeArtworkPrefetching.washSubjects(for: $0.content)
    }

    return ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(elements.enumerated()), id: \.element.id) { index, element in
          let isLast = index == elements.count - 1
          let bottom = HomeViewPresentation.rowBottomSpacing(for: element.kind, isLast: isLast)
          switch element.kind {
          case .filter:
            filterPicker
              .onGeometryChange(for: CGFloat.self) {
                $0.size.height
              } action: {
                filterRowHeight = $0
              }
              .padding(.top, HomePodcastsBrowseLayout.filterRowTopSpacing)
              .padding(.bottom, bottom)
          case .section:
            if let section = element.section {
              sectionView(section)
                .transition(.opacity)
                .padding(
                  .top,
                  HomePodcastsBrowseLayout.shelfTopSpacing(isFirst: element.id == firstShelfID)
                )
                .padding(.bottom, bottom)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // Scoped to the content, never the container. On the ScrollView this also animated the
      // scroll view's own geometry, so a shelf change landing as a pull-to-refresh closed
      // overrode the bounce-back and left contentOffset parked in overscroll.
      .animation(elementMotion, value: elements.map(\.id))
    }
    .scrollContentBackground(.hidden)
    .scrollIndicators(.hidden, axes: .vertical)
    .background(WhirrColorToken.editorialBackground.color.ignoresSafeArea())
    .onGeometryChange(for: CGFloat.self) { geometry in
      geometry.size.width
    } action: { _, width in
      availableWidth = width
    }
    .primaryScrollEdgeEffect()
    .onScrollPhaseChange { _, phase in
      homeWashProvider.setScrollInteractionActive(
        phase, source: homeWashProvider.scrollSource(for: .homeOuter))
    }
    // Keyed on the ID set so shelf reorder and progress ticks do not repeat records-only warming.
    .task(id: Set(washPreloadSubjects)) {
      await homeWashProvider.preloadCachedWashes(washPreloadSubjects)
    }
    .overlay {
      if let placeholder = HomeViewPresentation.placeholder(
        for: pageState, hasWaitedForContent: hasWaitedForContent)
      {
        placeholderView(placeholder)
          .padding(.top, filterRowHeight)
          .allowsHitTesting(false)
      }
    }
    // Restarted whenever the page state changes, so each distinct wait is timed from its own
    // start rather than from the screen's first appearance. Cancellation on state change is what
    // stops a load that resolved inside the delay from ever raising the spinner.
    .task(id: pageState) {
      if pageState != .loading { launchMark("populated") }
      guard pageState == .loading else {
        hasWaitedForContent = false
        return
      }
      hasWaitedForContent = false
      guard (try? await Task.sleep(for: HomeViewPresentation.loadingPlaceholderDelay)) != nil
      else { return }
      hasWaitedForContent = true
    }
    .navigationTitle("Home")
    // Appearance refreshes are throttled by the coordinator. Keyed so switching back to All, or
    // showing the section again in Settings, asks once more.
    .task(id: showsListeningStats) {
      guard showsListeningStats, let listeningStatsModel else { return }
      await listeningStatsModel.refresh(trigger: .appearance)
    }
    .refreshable {
      isRefreshing = true
      async let stats: Void = refreshListeningStatsExplicitly()
      await model.refresh()
      await stats
      isRefreshing = false
    }
    .onDisappear {
      homeWashProvider.retireAllScrollSources()
      artworkPrefetchController.cancelAll()
    }
  }

  @ViewBuilder
  private func sectionView(_ section: HomeViewPresentation.Section) -> some View {
    if case .listeningStats(let summary?) = section.content {
      let washSubject = ListeningStatsScreenPresentation.homeCardWashSubject(
        continueListening: model.continueListening)
      HomeListeningStatsSection(
        summary: summary,
        timeSaved: timeSaved?.totals ?? .zero,
        wash: washSubject.map { homeWashProvider.wash(for: $0) } ?? .neutral,
        horizontalInset: pageInset,
        catalogued: catalogued,
        onOpen: {
          onOpenSection(
            HomeViewPresentation.detailRoute(for: .listeningStats, selectedFilter: model.filter))
        }
      )
      // Continue Listening usually asked already; this covers it being hidden in Settings.
      .task(id: washSubject) {
        guard let washSubject else { return }
        homeWashProvider.request([washSubject])
      }
    } else if section.kind == .smartLists {
      smartListsSection
    } else {
      shelfView(section)
    }
  }

  /// The Podcasts tab's section, on Home so a list is a starting point without changing tab.
  @ViewBuilder
  private var smartListsSection: some View {
    if let smartLists {
      SmartListsSectionView(
        model: smartLists.model,
        coverClient: coverClient,
        playback: playback,
        horizontalInset: pageInset,
        onOpenList: { onOpenSection(HomeViewPresentation.route(forSmartListID: $0)) },
        onPlayList: { listID in Task { _ = await smartLists.play(listID: listID) } },
        onEditList: { listID in
          smartListEditorRequest = SmartListEditorRequest(
            mode: .edit(listID: listID), template: .blank)
        },
        onManage: {
          onOpenSection(
            HomeViewPresentation.detailRoute(for: .smartLists, selectedFilter: model.filter))
        },
        onCreate: {
          smartListEditorRequest = SmartListEditorRequest(mode: .create, template: .blank)
        }
      )
      .smartListEditorSheet(request: $smartListEditorRequest)
    }
  }

  private var smartListCount: Int {
    guard let model = smartLists?.model, model.isAvailable else { return 0 }
    return model.lists.count
  }

  /// The card is account-wide, so it shows only under All and only when not hidden;
  /// otherwise Home never asks the server for figures it would not draw.
  private var showsListeningStats: Bool {
    listeningStatsModel != nil && model.filter == .all
      && HomeSectionVisibility.isVisible(.listeningStats, in: sectionPreferences.hiddenSections)
  }

  private func refreshListeningStatsExplicitly() async {
    guard showsListeningStats, let listeningStatsModel else { return }
    await listeningStatsModel.refresh(trigger: .explicit)
  }

  private func shelfView(_ section: HomeViewPresentation.Section) -> some View {
    HomeShelfView(
      section: section,
      selectedFilter: model.filter,
      context: HomeShelfCardContext(
        coverClient: coverClient,
        playback: playback,
        actions: actions,
        washProvider: homeWashProvider,
        opensContinueCardImmediately: sectionPreferences.opensContinueCardImmediately,
        itemCardPlacement: .homeItemCard,
        callbacks: HomeShelfCardActions(
          onSelectItem: onSelectItem,
          onPresentReader: onPresentReader,
          onResumeListening: onResumeListening,
          onSelectDownloadedPodcast: onSelectDownloadedPodcast,
          onSelectEpisode: onSelectEpisode,
          onSearch: onSearch)),
      artworkPrefetchController: artworkPrefetchController,
      displayScale: displayScale,
      reduceMotion: reduceMotion,
      horizontalInset: pageInset,
      onOpenSection: onOpenSection)
  }

  /// One margin for the whole page, measured once at the scroll view as the Podcasts root does, so
  /// the rail both tabs share starts at the same x position in a very wide window.
  private var pageInset: CGFloat {
    HomePodcastsBrowseLayout.pageInset(
      availableWidth: availableWidth, horizontalSizeClass: horizontalSizeClass)
  }

  @ViewBuilder
  private func placeholderView(_ placeholder: HomeViewPresentation.Placeholder) -> some View {
    switch placeholder {
    case .loading:
      LoadingStateView(message: "Loading…")
    case .empty:
      EmptyStateView(
        title: "Nothing Yet",
        message: HomeViewPresentation.emptyStateMessage(),
        systemImage: "house")
    }
  }

  private var contentElements: [HomeViewPresentation.ContentElement] {
    HomeViewPresentation.contentElements(
      state: pageState,
      continueListening: model.continueListening,
      continueReading: model.continueReading,
      continueSeries: model.continueSeries,
      recentlyAdded: model.recentlyAdded,
      newPodcastEpisodes: latestEpisodesModel.podcastEpisodes,
      downloaded: model.downloaded,
      savedForLater: model.savedForLater,
      listeningStats: listeningStatsModel?.summary,
      smartListCount: smartListCount,
      filter: model.filter,
      hiddenSections: HomeSectionVisibility.hidden(in: sectionPreferences.hiddenSections),
      sectionOrder: sectionPreferences.sectionOrder)
  }

  private var pageState: HomeModel.State {
    HomeViewPresentation.pageState(
      home: model.state,
      latestEpisodes: latestEpisodesModel.state,
      filter: model.filter)
  }

  /// Kept outside the state switch so filter re-subscription cannot tear down its selection motion.
  private var filterPicker: some View {
    MediaFilterPicker(
      title: MediaFilterCopy.title,
      labels: MediaFilter.allCases.map(MediaFilterCopy.label(for:)),
      selectedIndex: MediaFilter.allCases.firstIndex(of: model.filter) ?? 0,
      style: .chips,
      onSelect: { index in
        guard MediaFilter.allCases.indices.contains(index) else { return }
        model.filter = MediaFilter.allCases[index]
      }
    )
    // The chips already carry `WhirrSpacing.medium` internally; only the page inset's excess
    // belongs out here, as on the Podcasts root.
    .padding(.horizontal, pageInset - WhirrSpacing.medium)
    .padding(.bottom, HomePodcastsBrowseLayout.filterBottomSpacing)
    .accessibilityIdentifier(HomeAccessibilityID.filterPicker)
  }

  /// The shelf-retirement motion, or none while the scroll investigation is ablating it.
  private var elementMotion: Animation? {
    #if DEBUG || PERF_INVESTIGATION
      if HarnessAblation.noHomeAnimation { return nil }
    #endif
    if isRefreshing { return nil }
    return dismissalMotion.animation
  }

  private var dismissalMotion: HomeViewPresentation.ContinueListeningDismissalMotion {
    HomeViewPresentation.continueListeningDismissalMotion(reduceMotion: reduceMotion)
  }
}
